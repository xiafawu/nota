import AVFoundation
import Foundation
import os
import Speech

// MARK: - LiveMeetingSessionError

/// Errors `LiveMeetingSession.stop()` throws when there is nothing to stop.
enum LiveMeetingSessionError: LocalizedError, Equatable {
  case notRecording

  var errorDescription: String? {
    switch self {
    case .notRecording:
      return "Live meeting: no recording in progress"
    }
  }
}

/// Which transcription backend a live session uses. `assemblyAI` is the
/// default; `.apple` (on-device SFSpeechRecognizer via AppleSpeechStream) is
/// the memo fallback when no AssemblyAI key exists — the memo card stays
/// alive with only the Apple engine (XIA-400 gating, XIA-403 wiring).
enum LiveEngine: Equatable {
  case assemblyAI
  case apple
}

/// Backend-specific setup failures for `LiveMeetingSession.start`.
enum LiveEngineError: LocalizedError, Equatable {
  case speechPermissionDenied

  var errorDescription: String? {
    switch self {
    case .speechPermissionDenied:
      return "Speech recognition permission is required for on-device memos"
    }
  }
}

// MARK: - LiveMeetingSession

/// Live dictation/transcription session rendered in the main Nota window.
///
/// Wires the same building blocks as `DictationController` — `MicCapture`
/// (16 kHz mono Float32 PCM) and an AssemblyAI realtime v3 WebSocket — but
/// renders the transcript incrementally instead of typing it into a focused
/// field. On stop, the accumulated segments plus the raw audio (a temp
/// 16 kHz mono CAF) are handed to the caller as `LiveMeetingResult` so it can
/// flow into the same history pipeline as regular meetings.
///
/// The realtime endpoint is
/// `wss://streaming.assemblyai.com/v3/ws?sample_rate=16000`, authenticated
/// with the `Authorization` header. `speech_model` is deliberately omitted —
/// AssemblyAI's default (Universal-3.5 Pro Streaming) is what we want.
///
/// Everything is driven on the main actor: the WebSocket receive loop hops
/// back to the main actor and `MicCapture` delivers converted buffers on the
/// main queue, so no cross-actor locking is needed. The pure message/state
/// logic lives in `handleMessageJSON` / `handleClose`, which tests drive
/// without a microphone or a socket.
@MainActor
final class LiveMeetingSession: ObservableObject {
  // MARK: - Public types

  enum SessionState: Equatable {
    case idle
    case recording
    /// The owner pressed Pause (XIA-447). The session is **not over**: the tap
    /// is still installed, the socket is still open, the record is still owned,
    /// and Resume continues into the same `recording.caf`. What stops is
    /// everything that would be a claim about a live microphone — buffers reach
    /// neither the socket nor the file, the meter falls to its floor, the ember
    /// goes out on all three surfaces, and the clock stops.
    ///
    /// **A pause lasts forever** (owner, 2026-08-12). There is no timeout, no
    /// auto-stop and no "still there?" — Nota never ends a session on its own.
    case paused
    case stopping
    case failed(String)
  }

  struct LiveSegment: Equatable, Identifiable {
    let id: UUID
    let text: String
    let endTime: TimeInterval
  }

  struct LiveMeetingResult: Equatable {
    let segments: [LiveSegment]
    let transcriptText: String
    let duration: TimeInterval
    /// The 16 kHz mono CAF inside the record's assets folder, if the recording
    /// worked. Nil when no destination was given or the file could not be opened.
    let audioURL: URL?
  }

  // MARK: - Published state

  @Published private(set) var state: SessionState = .idle
  @Published private(set) var segments: [LiveSegment] = []
  @Published private(set) var partialText: String? = nil
  @Published private(set) var elapsed: TimeInterval = 0

  /// The microphone's 0…1 meter level, republished from `MicCapture` so a
  /// recording surface can draw the one thing that proves the microphone is
  /// open. Republished rather than exposing `capture` itself: a view that holds
  /// the capture engine holds its `start()` and `stop()` too, and this session
  /// is the only thing entitled to call those.
  ///
  /// A plain `let` holding its **own** observable object, deliberately, and not
  /// a `@Published Float` on this one. The tap delivers ~45 buffers a second
  /// and this session is observed by `ContentView` and `LiveMeetingView`, so a
  /// level on it invalidated the whole window body — toolbar, drawer overlay
  /// and the entire transcript — 45 times a second. `MeterPublishGate` throttles
  /// the writes on top of that; see it for the arithmetic.
  ///
  /// It goes to **zero** when capture ends (`stopCapture`) and while a session
  /// is finalizing, because a meter that answers a voice whose audio is being
  /// discarded is a meter claiming that voice was captured.
  let level = MicLevelFeed()

  // MARK: - Lifecycle

  /// Start a live meeting: mic permission, capture engine, and the chosen
  /// transcription backend. Returns once the backend is live.
  ///
  /// `diarize` requests AssemblyAI realtime speaker labels
  /// (`speaker_labels=true`); memo sessions turn it on only when the
  /// memo-diarization setting is enabled. Note: the stream parser currently
  /// reads turn transcripts only — labeled turns render unlabeled until a
  /// follow-up consumes the speaker events — so this is intent + record
  /// plumbing today.
  ///
  /// `engine` selects the backend: `.assemblyAI` (realtime WS, needs a key)
  /// or `.apple` (on-device recognition — the memo path without an
  /// AssemblyAI key).
  ///
  /// `audioDestination` is where the session records — since XIA-430 that is
  /// the record's own `<id>.assets/recording.caf`, created before this call.
  /// Nil records no audio at all (tests, and any caller with no record).
  ///
  /// On any setup failure the session transitions to `.failed(message)` first
  /// (so the UI's error banner renders off the published state) and then
  /// throws `MicCaptureError`/`AssemblyAIError`.
  func start(
    diarize: Bool = false,
    engine: LiveEngine = .assemblyAI,
    audioDestination: URL? = nil
  ) async throws {
    cancel()
    self.audioDestination = audioDestination

    // 1. API key — only the AssemblyAI engine needs one; fail fast, before
    //    permission prompts or any engine work.
    var apiKey = ""
    if engine == .assemblyAI {
      guard let key = ApiKeyStore.value(for: "ASSEMBLYAI_API_KEY"), !key.isEmpty else {
        failStart(AssemblyAIError.missingAPIKey)
        throw AssemblyAIError.missingAPIKey
      }
      apiKey = key
    }

    // 2. Microphone permission.
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      break
    case .notDetermined:
      let granted = await AVCaptureDevice.requestAccess(for: .audio)
      guard granted else {
        failStart(MicCaptureError.permissionDenied)
        throw MicCaptureError.permissionDenied
      }
    case .denied, .restricted:
      failStart(MicCaptureError.permissionDenied)
      throw MicCaptureError.permissionDenied
    @unknown default:
      failStart(MicCaptureError.permissionDenied)
      throw MicCaptureError.permissionDenied
    }

    if engine == .apple {
      try await startAppleEngine()
      return
    }

    // 3. WebSocket (v3 realtime; no speech_model → Universal-3.5 Pro Streaming).
    let baseURL = "wss://streaming.assemblyai.com/v3/ws?sample_rate=16000"
    let urlString = diarize ? "\(baseURL)&speaker_labels=true" : baseURL
    guard let url = URL(string: urlString) else {
      failStart(AssemblyAIError.webSocketError("invalid URL"))
      throw AssemblyAIError.webSocketError("invalid URL")
    }
    var request = URLRequest(url: url)
    request.setValue(apiKey, forHTTPHeaderField: "Authorization")

    let delegate = LiveMeetingSessionWSDelegate()
    delegate.session = self
    wsDelegate = delegate
    let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    urlSession = session
    let task = session.webSocketTask(with: request)
    webSocketTask = task
    task.resume()
    startReceiving()

    // 4. Wait for open + Begin; one watchdog covers both.
    openWatchdog = Task { [weak self] in
      try? await Task.sleep(nanoseconds: Self.openTimeoutNanoseconds)
      guard let self, !Task.isCancelled else { return }
      if self.openContinuation != nil || self.beginContinuation != nil {
        self.logger.warning("start() watchdog fired — AssemblyAI did not begin a session in time")
        self.failOpen(AssemblyAIError.connectionTimeout)
      }
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      openContinuation = continuation
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      beginContinuation = continuation
    }
    openWatchdog?.cancel()
    openWatchdog = nil

    // 5. Begin received — session is live. Start the clock, audio file, capture.
    // The clock is normally already installed: `Begin` is what flips `state` to
    // `.recording`, and the surface's Pause capsule is live from that instant,
    // so the clock has to exist by then too (see `handleMessageJSON`). This is
    // the fallback for a path that reached here without one.
    if clock == nil { clock = SessionClock(startedAt: Date()) }
    startElapsedTicker()
    prepareAudioFile()
    installCaptureHandler()
    do {
      try capture.start()
    } catch {
      logger.error("live meeting capture failed to start: \(error.localizedDescription, privacy: .public)")
      receiveTask?.cancel()
      receiveTask = nil
      webSocketTask?.cancel(with: .normalClosure, reason: nil)
      teardownWS()
      closeAudioFile()
      failStart(error)
      throw error
    }
    logger.info("live meeting session started")
  }

  // MARK: - Pause / resume (XIA-447)

  /// Stop capturing without ending the session.
  ///
  /// Three things it owes, and each is a hazard rather than a nicety:
  ///
  /// - **The pre-press tail is not lost.** `capture.flushPending()` runs
  ///   *before* the state flips, because `handlePCMBuffer`'s guard is evaluated
  ///   on the main actor at drain time: whatever is queued at the press is audio
  ///   that was captured while the microphone was live, and judging it against
  ///   `.paused` is the same defect `PendingPCMBuffers` was written to fix,
  ///   arriving at a boundary that happens many times a session. The drain is
  ///   worth nothing unless the buffer callback is **synchronous** — the first
  ///   cut of this ticket wrapped it in `Task { @MainActor }`, which deferred
  ///   every drained buffer past the flip and dropped exactly the audio the
  ///   flush exists to keep.
  /// - **The clock stops, and it stops as audio time.** `SessionClock` accrues
  ///   the pause, and the ticker is left running deliberately: it publishes
  ///   `clock.elapsed(now:)`, which is pinned to the instant of the press while
  ///   `pausedAt` is set, so it costs one assignment a quarter-second and there
  ///   is no second lifecycle to keep in step at resume.
  /// - **The socket is kept.** See `startPauseKeepAlive`.
  ///
  /// The capture engine is deliberately **not** stopped. `stopCapture()` nils
  /// `onPCMBuffer` and nothing but `start()` reinstalls it, and
  /// `MicCapture.start()` re-negotiates the device format and can throw — a
  /// resume that can fail with a `MicCaptureError` is a new failure class on a
  /// session that is already recording. The shape "tap installed, buffers
  /// dropped by the state guard" is exactly what `.stopping` already is; pause
  /// is that discipline without the teardown.
  ///
  /// The cost of that is worth naming rather than glossing: **macOS keeps its
  /// own microphone indicator lit for the whole pause**, because the tap really
  /// is installed. Nothing Nota keeps, sends or writes comes from it — that is
  /// `capturesAudio`, and the file proves it — but nowhere may claim the
  /// *device* is closed. Everything that used to say so has been reworded.
  ///
  /// **A clock is required, not optional.** On the WS path `Begin` is what
  /// flips `state` to `.recording`, and the rest of `start()` runs as a
  /// separate main-actor job after the continuation resumes — so there is a
  /// window in which a Pause press would find a live state and no clock.
  /// `handleMessageJSON` installs the clock at `Begin` to close it, and this
  /// guard is the backstop: pausing a clockless session would show "Paused"
  /// over a *ticking* clock and bank the whole pause into `elapsed` as audio
  /// time, which is the one substitution the ticket forbids.
  func pause(now: Date = Date()) {
    guard state == .recording, clock != nil else { return }
    capture.flushPending()
    clock?.pause(now: now)
    state = .paused
    publishElapsed(now: now)
    level.silence()
    startPauseKeepAlive()
    logger.info("live meeting session paused")
  }

  /// Continue into the same recording. Same file, same socket, same record.
  ///
  /// `capture.discardPending()` runs *before* the state flips, and it is the
  /// mirror of the flush at the far end: a buffer converted during the pause is
  /// drained by a later main-thread hop, so without this it would be judged
  /// against `.recording` and written into the file the owner was told does not
  /// hold it.
  func resume(now: Date = Date()) {
    guard state == .paused else { return }
    stopPauseKeepAlive()
    capture.discardPending()
    clock?.resume(now: now)
    state = .recording
    publishElapsed(now: now)
    logger.info("live meeting session resumed")
  }

  /// Stop the live meeting: send `Terminate`, wait for `Termination` (or the
  /// 5 s watchdog), stop capture, close the socket, finalize the audio file,
  /// and settle `state` to `.idle` before returning the accumulated result.
  ///
  /// **Stop is terminal, from `.paused` too.** There is no resume after Stop,
  /// ever; a paused session is stoppable precisely so the owner never has to
  /// resume in order to end.
  func stop() async throws -> LiveMeetingResult {
    if let result = lastResult { return result }
    let isFailed: Bool = if case .failed(_) = state { true } else { false }
    guard state == .recording || state == .paused || isFailed else {
      throw LiveMeetingSessionError.notRecording
    }
    stopPauseKeepAlive()

    // Apple engine: no WS termination dance — stop capture, finalize the
    // recognizer, and build the result from what streamed in.
    if appleSpeech != nil {
      state = .stopping
      elapsedTask?.cancel()
      elapsedTask = nil
      stopCapture()
      if let speech = appleSpeech {
        let finalText = try? await speech.finish()
        // A session that never produced a final delta still delivers its text
        // through finish(); surface it as the single segment.
        if let finalText, !finalText.isEmpty, segments.isEmpty {
          segments.append(LiveSegment(id: UUID(), text: finalText, endTime: elapsed))
        }
      }
      appleSpeech = nil
      appleHypothesesTask?.cancel()
      appleHypothesesTask = nil
      let result = LiveMeetingResult(
        segments: segments,
        transcriptText: transcriptText,
        duration: elapsed,
        audioURL: finalizeAudioFile()
      )
      lastResult = result
      state = .idle
      return result
    }

    // If the connection already failed there is nothing left to receive —
    // finalize immediately with what we have.
    let skipFinalWait: Bool
    if case .failed(_) = state {
      skipFinalWait = true
    } else {
      skipFinalWait = false
    }

    state = .stopping
    sendTerminate()

    let duration = skipFinalWait ? finalDuration : await waitForFinalTranscript()

    // Stop capture and close the connection.
    elapsedTask?.cancel()
    elapsedTask = nil
    stopCapture()
    receiveTask?.cancel()
    receiveTask = nil
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    teardownWS()

    let result = LiveMeetingResult(
      segments: segments,
      transcriptText: transcriptText,
      // The server's `audio_duration_seconds` counts every frame we sent, and a
      // paused session's keep-alive frames are silence — so it is wall clock
      // for exactly the sessions where wall clock is wrong. `SessionDurationChoice`.
      duration: SessionDurationChoice.duration(
        serverReported: duration,
        elapsed: elapsed,
        everPaused: clock?.everPaused ?? false
      ),
      audioURL: finalizeAudioFile()
    )
    lastResult = result
    state = .idle
    return result
  }

  /// Abort the session: close everything, discard the result, return to `.idle`.
  func cancel() {
    // Unstick any waits.
    let open = openContinuation
    openContinuation = nil
    open?.resume(throwing: CancellationError())
    let begin = beginContinuation
    beginContinuation = nil
    begin?.resume(throwing: CancellationError())
    let finish = finishContinuation
    finishContinuation = nil
    finish?.resume(returning: finalDuration)
    openWatchdog?.cancel()
    openWatchdog = nil
    finishWatchdog?.cancel()
    finishWatchdog = nil

    // Stop I/O.
    elapsedTask?.cancel()
    elapsedTask = nil
    stopPauseKeepAlive()
    receiveTask?.cancel()
    receiveTask = nil
    stopCapture()
    didSendTerminate = false
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    teardownWS()
    appleSpeech = nil
    appleHypothesesTask?.cancel()
    appleHypothesesTask = nil
    closeAudioFile()

    // Reset state.
    segments = []
    partialText = nil
    elapsed = 0
    clock = nil
    didReceiveTermination = false
    finalDuration = nil
    audioDestination = nil
    lastResult = nil
    state = .idle
  }

  // MARK: - Message handling (internal so tests can drive them without I/O)

  /// Handle one server JSON message. `Begin` → recording; a partial `Turn`
  /// updates `partialText`; a final `Turn` appends a `LiveSegment` and clears
  /// `partialText`; `Termination` captures the audio duration and finalizes.
  func handleMessageJSON(_ text: String) {
    guard let parsed = AssemblyAIRealtimeStream.ParsedMessage.fromJSON(text) else {
      logger.warning("Malformed message: \(text.prefix(100), privacy: .public)")
      return
    }

    switch parsed {
    case .begin:
      // The clock is installed **here**, with the state, and not only in the
      // remainder of `start()` (XIA-447). Resuming the continuation below does
      // not run that remainder inline — it enqueues it — so a Pause press in
      // between would otherwise find `.recording` with no clock. `pause()`
      // refuses that case as a backstop; this is what makes it unreachable.
      if clock == nil { clock = SessionClock(startedAt: Date()) }
      state = .recording
      let begin = beginContinuation
      beginContinuation = nil
      begin?.resume(returning: ())
      logger.info("AssemblyAI live session began")

    case .speechStarted(let timestamp, let confidence):
      logger.info("SpeechStarted at \(timestamp)ms confidence=\(confidence)")

    case .turn(let transcript, let endOfTurn):
      if endOfTurn {
        // An **empty** end-of-turn is dropped rather than appended (XIA-447).
        // A pause streams zeroed frames for as long as it lasts, and silence is
        // exactly the input that ends a turn — so without this a five-minute
        // break adds a blank segment to the live transcript and a blank line to
        // the sealed `.md`, stamped at the frozen `elapsed`. There is nothing
        // to lose: a turn with no words is not a turn.
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !spoken.isEmpty {
          segments.append(LiveSegment(id: UUID(), text: transcript, endTime: elapsed))
        }
        partialText = nil
        logger.debug("Final turn: \"\(transcript.prefix(60), privacy: .public)\"")
      } else {
        partialText = transcript
        logger.debug("Partial turn: \"\(transcript.prefix(60), privacy: .public)\"")
      }

    case .termination(let duration):
      didReceiveTermination = true
      if let duration { finalDuration = duration }
      resolveFinish(duration: finalDuration)
      // Server-initiated end while still recording: finalize the whole session.
      // `.paused` counts — the session is not over, so a server that ends it
      // ends it, and the record must not be left claiming a live stage because
      // the owner happened to be away from the desk.
      if state == .recording || state == .paused {
        finalizeSession()
      }
    }
  }

  /// The WebSocket opened — unstick `start()`'s open wait.
  func handleOpen() {
    let open = openContinuation
    openContinuation = nil
    open?.resume(returning: ())
    logger.info("WebSocket connected")
  }

  /// A WebSocket close. Error codes (4001-4004/4xxx/5xxx, or a non-4xxx close
  /// carrying a reason) map exactly like `AssemblyAIRealtimeStream`; a failed
  /// session keeps its accumulated segments.
  func handleClose(rawValue: Int, reason: String?) {
    if let errorMessage = AssemblyAIRealtimeStream.ParsedMessage.errorMessage(forCloseCode: rawValue, reason: reason) {
      logger.error("WS closed: \(errorMessage, privacy: .public)")
      if state == .stopping || didSendTerminate {
        // The stop wait is running — resolve it with what we have.
        resolveFinish(duration: nil)
      } else if openContinuation != nil || beginContinuation != nil {
        failOpen(AssemblyAIError.serverError(errorMessage))
      } else {
        failSession(errorMessage)
      }
    } else if state == .stopping || didSendTerminate {
      resolveFinish(duration: nil)
    } else if openContinuation != nil || beginContinuation != nil {
      failOpen(AssemblyAIError.webSocketError("connection closed before session began"))
    } else {
      // Clean close mid-session: end with what we have.
      finalizeSession()
    }
    teardownWS()
  }

  // MARK: - Test-facing knobs

  /// How long `stop()` waits for the `Termination` message before returning
  /// the accumulated transcript (nanoseconds). Tests shorten this.
  var finishWatchdogNanoseconds: UInt64 = 5_000_000_000

  /// The finalized result of the last completed session, if any.
  private(set) var lastResult: LiveMeetingResult?

  // MARK: - Private state

  private let logger = Logger(subsystem: "com.xiafawu.nota", category: "dictation.livemeeting")
  private let capture = MicCapture()
  #if DEBUG
  private var keptBufferCount = 0
  #endif

  private static let openTimeoutNanoseconds: UInt64 = 10_000_000_000

  private var urlSession: URLSession?
  private var webSocketTask: URLSessionWebSocketTask?
  private var wsDelegate: LiveMeetingSessionWSDelegate?
  private var receiveTask: Task<Void, Never>?
  private var openWatchdog: Task<Void, Never>?
  private var finishWatchdog: Task<Void, Never>?
  private var elapsedTask: Task<Void, Never>?
  private var pauseKeepAliveTask: Task<Void, Never>?

  private var openContinuation: CheckedContinuation<Void, any Error>?
  private var beginContinuation: CheckedContinuation<Void, any Error>?
  private var finishContinuation: CheckedContinuation<TimeInterval?, Never>?

  private var didSendTerminate = false
  private var didReceiveTermination = false
  private var finalDuration: TimeInterval?
  /// The session's clock. It replaced a bare `startedAt` when pause arrived
  /// (XIA-447): elapsed is audio time, so "when did this start" is no longer
  /// enough to compute it. See `SessionClock`.
  private var clock: SessionClock?

  private var audioFile: AVAudioFile?
  private var audioURL: URL?
  /// Where this session records, handed in by `start(audioDestination:)`.
  /// It is a start parameter rather than settable state so `cancel()` — which
  /// `start()` calls on itself first — can never clear it out from under the
  /// session it is about to begin.
  private var audioDestination: URL?

  /// Apple-engine state (nil when the session runs on AssemblyAI).
  private var appleSpeech: AppleSpeechStream?
  private var appleHypothesesTask: Task<Void, Never>?

  private var transcriptText: String {
    segments.map(\.text).joined(separator: "\n")
  }

  // MARK: - Apple engine

  /// On-device backend for memo sessions without an AssemblyAI key:
  /// SFSpeechRecognizer permission, AppleSpeechStream in streaming mode
  /// (finalized deltas arrive mid-session), MicCapture feeding it, and the
  /// same audio-file + elapsed-ticker plumbing as the WS path.
  private func startAppleEngine() async throws {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized:
      break
    case .notDetermined:
      let granted: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { status in
          continuation.resume(returning: status)
        }
      }
      guard granted == .authorized else {
        failStart(LiveEngineError.speechPermissionDenied)
        throw LiveEngineError.speechPermissionDenied
      }
    case .denied, .restricted:
      failStart(LiveEngineError.speechPermissionDenied)
      throw LiveEngineError.speechPermissionDenied
    @unknown default:
      failStart(LiveEngineError.speechPermissionDenied)
      throw LiveEngineError.speechPermissionDenied
    }

    let speech = AppleSpeechStream(streaming: true)
    appleSpeech = speech
    appleHypothesesTask = Task { @MainActor [weak self] in
      for await hypothesis in speech.hypotheses {
        guard let self else { break }
        self.handleAppleHypothesis(hypothesis)
      }
    }

    do {
      try await speech.start()
    } catch {
      appleSpeech = nil
      appleHypothesesTask?.cancel()
      appleHypothesesTask = nil
      failStart(error)
      throw error
    }

    // Session is live — same clock/audio/capture plumbing as the WS path.
    clock = SessionClock(startedAt: Date())
    startElapsedTicker()
    prepareAudioFile()
    capture.onPCMBuffer = { [weak self] buffer in
      // Synchronous, for the reason the WS path's is. See `MicCapture
      // .flushPending`.
      MainActor.assumeIsolated {
        guard let self else { return }
        self.publishLevel()
        // The same gate the WS path applies to its socket send and its file
        // write (XIA-447): a paused session feeds the analyzer nothing, so the
        // words spoken while it was paused are not in the transcript either.
        guard Self.capturesAudio(self.state) else { return }
        try? self.appleSpeech?.feed(buffer)
      }
    }
    do {
      try capture.start()
    } catch {
      logger.error("live meeting apple capture failed to start: \(error.localizedDescription, privacy: .public)")
      appleHypothesesTask?.cancel()
      appleHypothesesTask = nil
      appleSpeech = nil
      closeAudioFile()
      failStart(error)
      throw error
    }
    state = .recording
    logger.info("live meeting session started (apple engine)")
  }

  /// Route AppleSpeechStream hypotheses into the shared segment/partial state.
  private func handleAppleHypothesis(_ hypothesis: Hypothesis) {
    /// **`.paused` counts, and that is XIA-447's correction here.** The
    /// analyzer finalizes asynchronously: audio fed at t−0.5s routinely
    /// resolves at t+0.3s, so the sentence spoken *just before* the press lands
    /// after it. Gated on `.recording` alone that result was dropped and never
    /// re-emitted — Apple's finalized results are deltas — so a mid-meeting
    /// pause silently lost the last turn before it from the sealed transcript
    /// and the summary. The WS path's `.turn` handler has never had a state
    /// guard at all, which is why the two engines disagreed about one boundary.
    /// It is stamped with `elapsed`, which is pinned at the press, so it names
    /// the right second of the audio.
    guard state == .recording || state == .paused else { return }
    if hypothesis.isFinal {
      segments.append(LiveSegment(id: UUID(), text: hypothesis.text, endTime: elapsed))
      partialText = nil
    } else {
      partialText = hypothesis.text
    }
  }

  // MARK: - WebSocket plumbing

  private func startReceiving() {
    receiveTask = Task { @MainActor [weak self] in
      guard let self else { return }
      while !Task.isCancelled, let task = self.webSocketTask {
        do {
          let message = try await task.receive()
          self.handleRawMessage(message)
        } catch {
          self.handleReceiveError(error)
          break
        }
      }
    }
  }

  private func handleRawMessage(_ message: URLSessionWebSocketTask.Message) {
    guard case .string(let text) = message else { return }
    handleMessageJSON(text)
  }

  private func handleReceiveError(_ error: any Error) {
    logger.error("WS receive error: \(error.localizedDescription, privacy: .public)")
    if state == .stopping || didSendTerminate {
      resolveFinish(duration: nil)
    } else if openContinuation != nil || beginContinuation != nil {
      failOpen(error)
    } else if state == .recording || state == .paused {
      failSession(error.localizedDescription)
    }
    // state == .idle/.failed → teardown in progress or already failed; ignore.
  }

  private func sendTerminate() {
    guard !didSendTerminate, let task = webSocketTask else { return }
    didSendTerminate = true
    let payload = "{\"type\":\"Terminate\"}"
    task.send(.string(payload)) { [weak self] error in
      if let error {
        self?.logger.warning("Terminate send failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  private func waitForFinalTranscript() async -> TimeInterval? {
    if didReceiveTermination { return finalDuration }
    return await withCheckedContinuation { (continuation: CheckedContinuation<TimeInterval?, Never>) in
      finishContinuation = continuation
      finishWatchdog = Task { [weak self] in
        let timeout = self?.finishWatchdogNanoseconds ?? 5_000_000_000
        try? await Task.sleep(nanoseconds: timeout)
        guard let self, !Task.isCancelled else { return }
        let finish = self.finishContinuation
        self.finishContinuation = nil
        self.finishWatchdog = nil
        if finish != nil {
          self.logger.warning("stop() watchdog fired — Termination not received; returning accumulated transcript")
        }
        finish?.resume(returning: self.finalDuration)
      }
    }
  }

  private func resolveFinish(duration: TimeInterval?) {
    let finish = finishContinuation
    finishContinuation = nil
    finishWatchdog?.cancel()
    finishWatchdog = nil
    finish?.resume(returning: duration ?? finalDuration)
  }

  private func failOpen(_ error: any Error) {
    openWatchdog?.cancel()
    openWatchdog = nil
    let open = openContinuation
    openContinuation = nil
    open?.resume(throwing: error)
    let begin = beginContinuation
    beginContinuation = nil
    begin?.resume(throwing: error)
    state = .failed(Self.message(for: error))
  }

  /// Mid-session failure: surface it, stop I/O, keep accumulated segments.
  private func failSession(_ message: String) {
    if case .failed(_) = state { return }
    guard state != .idle else { return }
    state = .failed(message)
    elapsedTask?.cancel()
    elapsedTask = nil
    // Both terminal paths reachable from `.paused` cancel it (XIA-447): the
    // keep-alive is a task that sends on a socket `teardownWS()` is about to
    // cancel, and it must not outlive the session that owns it.
    stopPauseKeepAlive()
    stopCapture()
    receiveTask?.cancel()
    receiveTask = nil
    teardownWS()
  }

  /// End the session and stash the result (server-initiated end / clean close).
  private func finalizeSession() {
    guard state != .idle else { return }
    elapsedTask?.cancel()
    elapsedTask = nil
    stopPauseKeepAlive()
    stopCapture()
    receiveTask?.cancel()
    receiveTask = nil
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    teardownWS()
    lastResult = LiveMeetingResult(
      segments: segments,
      transcriptText: transcriptText,
      duration: SessionDurationChoice.duration(
        serverReported: finalDuration,
        elapsed: elapsed,
        everPaused: clock?.everPaused ?? false
      ),
      audioURL: finalizeAudioFile()
    )
    state = .idle
  }

  /// Set `.failed` for a `start()` setup failure before it throws.
  private func failStart(_ error: any Error) {
    state = .failed(Self.message(for: error))
  }

  private static func message(for error: any Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? String(describing: error)
  }

  // MARK: - Audio

  /// Detach the tap, stop the engine, and drop the meter to silence.
  ///
  /// One call rather than three lines at each of the five exits, because the
  /// third was the one that kept getting forgotten: the level is published
  /// state and nothing else clears it, so a session that ended with the room
  /// loud left a full meter on screen for the next surface to draw.
  private func stopCapture() {
    capture.onPCMBuffer = nil
    capture.stop()
    level.silence()
  }

  /// Whether the meter may answer the microphone right now.
  ///
  /// **Only while the audio is being kept.** On the AssemblyAI path `stop()`
  /// sets `.stopping`, sends Terminate and then awaits the final transcript —
  /// up to the 5 s watchdog — with the tap still installed, while
  /// `handlePCMBuffer` drops every buffer at its own `state == .recording`
  /// guard. So the owner pressed Stop, kept talking, watched the ember meter
  /// answer their voice, and reasonably concluded those words were captured.
  /// They reached neither `recording.caf` nor the socket. A meter that moves is
  /// a claim that something is being recorded, and it may only be made when
  /// something is.
  ///
  /// `nonisolated` because it is arithmetic on a value and nothing else, and
  /// because it is now the *shared* predicate for the ember (XIA-434): the
  /// window's meter, the island's dot and the menu bar's dot all ask it, and the
  /// last two are decided by pure types that have no business being main-actor
  /// isolated.
  nonisolated static func meterFollowsMicrophone(_ state: SessionState) -> Bool {
    state == .recording
  }

  /// Whether a delivered buffer is kept — i.e. whether it reaches the socket
  /// **and** `recording.caf`.
  ///
  /// The same predicate for both destinations, deliberately, and it is what
  /// makes audio continuity a fact about the file rather than a hope: the CAF
  /// is a concatenation of exactly the buffers that got past this, so a paused
  /// span is *absent* from it — not a gap of silence, not a second file — and
  /// what the socket received matches what was written, frame for frame, apart
  /// from the keep-alive silence (`startPauseKeepAlive`, which is the one thing
  /// sent that is not from the microphone and is why the server's own duration
  /// is no longer trusted for a paused session).
  ///
  /// It is `nonisolated static` and separate from `meterFollowsMicrophone`
  /// because they answer different questions and only happen to agree today:
  /// this one is about the *bytes*, that one is about what may be *claimed* on
  /// screen.
  nonisolated static func capturesAudio(_ state: SessionState) -> Bool {
    state == .recording
  }

  // MARK: - Keeping the socket across a pause

  /// How often a paused session sends a frame, and how much audio each carries.
  ///
  /// **The socket decision: one socket for the whole session, kept alive with
  /// zeroed frames.** The alternative — close at pause, reopen at resume — was
  /// rejected on the code as it stands, and each reason is independent:
  ///
  /// - There is no reopen path. `webSocketTask` is assigned in `start()` alone,
  ///   and `start()` begins by calling `cancel()`, which wipes `segments`,
  ///   `partialText`, `elapsed` and the audio file. Reopening mid-session
  ///   destroys the meeting.
  /// - A new socket is a new AssemblyAI session, so its `Termination` covers
  ///   only the last leg — and that value is what a record is sealed with.
  /// - Doing nothing at all is not available either: an idle realtime stream is
  ///   disconnected by the server, and this file's close-code table has no idle
  ///   case, so it would land in `failSession` — a pause that silently kills a
  ///   meeting. Capping the pause would answer that, and the owner's second
  ///   decision forbids it: **a pause lasts forever.**
  ///
  /// What it costs is honest and worth naming: AssemblyAI is streamed (and
  /// billed for) silence for as long as the pause lasts, and its reported
  /// `audio_duration_seconds` becomes wall clock rather than audio time — which
  /// is exactly why `SessionDurationChoice` stops trusting it once a session has
  /// been paused. Nothing about the keep-alive reaches `recording.caf`: this
  /// writes to the socket only.
  static let pauseKeepAliveInterval: TimeInterval = 1

  /// One second of 16 kHz mono Int16 silence — the frame shape
  /// `handlePCMBuffer` sends, with every sample zero. Pure, so its size is
  /// asserted without a socket.
  nonisolated static func silentFrame(seconds: TimeInterval = pauseKeepAliveInterval) -> Data {
    let samples = max(0, Int((16_000 * seconds).rounded()))
    return Data(count: samples * MemoryLayout<Int16>.stride)
  }

  /// Where a keep-alive frame goes, and how often. Nil is production: the
  /// socket, at `pauseKeepAliveInterval`.
  ///
  /// The seam exists because this is the one part of pause that spends the
  /// owner's money, and `URLSessionWebSocketTask.send` is not something a test
  /// can observe — so without it the loop's guard, and every exit's
  /// `stopPauseKeepAlive()`, were unasserted by construction. What the tests
  /// actually need to hold is not "it sends" but "every way out of a pause
  /// stops it": resume, stop, cancel, a mid-pause failure and a
  /// server-initiated end.
  var pauseKeepAliveSink: ((Data) -> Void)?
  var pauseKeepAliveIntervalOverride: TimeInterval?

  /// Whether a paused session is currently holding the stream open.
  var isPauseKeepAliveRunning: Bool { pauseKeepAliveTask != nil }

  private func startPauseKeepAlive() {
    guard webSocketTask != nil || pauseKeepAliveSink != nil else { return }
    stopPauseKeepAlive()
    let interval = pauseKeepAliveIntervalOverride ?? Self.pauseKeepAliveInterval
    pauseKeepAliveTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        guard let self, !Task.isCancelled, self.state == .paused else { return }
        self.sendPauseKeepAlive()
      }
    }
  }

  private func sendPauseKeepAlive() {
    let frame = Self.silentFrame()
    if let pauseKeepAliveSink {
      pauseKeepAliveSink(frame)
      return
    }
    webSocketTask?.send(.data(frame)) { [weak self] error in
      if let error {
        self?.logger.warning(
          "pause keep-alive send failed: \(error.localizedDescription, privacy: .public)"
        )
      }
    }
  }

  private func stopPauseKeepAlive() {
    pauseKeepAliveTask?.cancel()
    pauseKeepAliveTask = nil
  }

  private func publishLevel() {
    if LiveMeetingSession.meterFollowsMicrophone(state) {
      level.publish(capture.rmsLevel)
    } else {
      level.silence()
    }
  }

  /// Wire the tap's delivery for the AssemblyAI path.
  ///
  /// **Synchronous, and that is load-bearing rather than a style choice.**
  /// `MicCapture` delivers converted 16 kHz mono Float32 buffers on the main
  /// thread, and `pause()` drains before it flips the state precisely so the
  /// pre-press tail is judged as live audio. A `Task { @MainActor in … }` here
  /// would defer every drained buffer past the flip and drop exactly the audio
  /// the flush exists to keep — which is what the first cut of XIA-447 did.
  /// See `MicCapture.flushPending`.
  ///
  /// One method rather than a closure literal at the call site so a test can
  /// install the **production** handler and put a buffer in flight across a
  /// real pause; a test that rebuilt this closure would be asserting its own
  /// copy of the rule.
  private func installCaptureHandler() {
    capture.onPCMBuffer = { [weak self] buffer in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.publishLevel()
        self.handlePCMBuffer(buffer)
      }
    }
  }

  private func handlePCMBuffer(_ buffer: AVAudioPCMBuffer) {
    guard Self.capturesAudio(state) else { return }
    #if DEBUG
    // How many buffers got past the gate. The only observable a test has for
    // "the pre-press tail was kept and the paused span was not": both
    // destinations below need a socket or an open file, and a unit test has
    // neither. See `keptBufferCountForTesting`.
    keptBufferCount += 1
    #endif

    guard let int16Buffer = convertToInt16(buffer) else { return }
    let count = Int(int16Buffer.frameLength)
    guard count > 0, let pointer = int16Buffer.int16ChannelData?[0] else { return }

    // 16 kHz mono Int16 binary frame.
    let data = Data(bytes: pointer, count: count * MemoryLayout<Int16>.stride)
    webSocketTask?.send(.data(data)) { [weak self] error in
      if let error {
        self?.logger.error("WS send failed: \(error.localizedDescription, privacy: .public)")
      }
    }

    // Persist the raw audio alongside the stream.
    if let audioFile {
      do {
        try audioFile.write(from: int16Buffer)
      } catch {
        logger.error("live meeting audio write failed: \(error.localizedDescription, privacy: .public)")
        self.audioFile = nil
      }
    }
  }

  /// Float32 16 kHz mono → Int16 16 kHz mono (mirrors
  /// `AssemblyAIRealtimeStream.convertToInt16`).
  private func convertToInt16(_ pcm: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    if pcm.format.commonFormat == .pcmFormatInt16,
       pcm.format.sampleRate == 16000,
       pcm.format.channelCount == 1 {
      return pcm
    }

    guard pcm.format.commonFormat == .pcmFormatFloat32,
          pcm.format.sampleRate == 16000,
          pcm.format.channelCount == 1,
          let floatData = pcm.floatChannelData,
          pcm.frameLength > 0
    else {
      logger.warning("Unexpected PCM format: \(pcm.format, privacy: .public)")
      return nil
    }

    guard let int16Format = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: 16000,
      channels: 1,
      interleaved: false
    ) else { return nil }

    let capacity = pcm.frameLength
    guard let output = AVAudioPCMBuffer(pcmFormat: int16Format, frameCapacity: capacity) else {
      return nil
    }
    output.frameLength = capacity

    guard let destination = output.int16ChannelData?[0] else { return nil }
    let source = UnsafeBufferPointer(start: floatData[0], count: Int(capacity))
    for i in 0..<Int(capacity) {
      let clamped = max(-1.0, min(1.0, source[i]))
      destination[i] = Int16(clamped * Float(Int16.max))
    }
    return output
  }

  private func startElapsedTicker() {
    elapsed = 0
    elapsedTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard let self, !Task.isCancelled, self.clock != nil else { return }
        self.publishElapsed(now: Date())
      }
    }
  }

  /// The one place `elapsed` is written from the clock. It is **audio time**:
  /// while paused, `SessionClock.elapsed` is pinned to the instant of the
  /// press, so the ticker keeps running and keeps publishing the same number
  /// rather than there being a second lifecycle to cancel and restart.
  private func publishElapsed(now: Date) {
    guard let clock else { return }
    let value = clock.elapsed(now: now)
    if elapsed != value { elapsed = value }
  }

  /// Open the 16 kHz mono CAF this session records into. Since XIA-430 the
  /// destination is the record's OWN assets folder, handed in by the caller
  /// before the microphone opens — the audio is written where it belongs from
  /// the first sample, so there is nothing to move afterwards and nothing to
  /// lose if the process never reaches the end. A session started without a
  /// destination (tests, and any caller that has no record) records nothing;
  /// failure stays non-fatal either way, and `audioURL` simply stays nil.
  private func prepareAudioFile() {
    guard let url = audioDestination else {
      audioFile = nil
      audioURL = nil
      return
    }
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 16_000.0,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
    ]
    do {
      audioFile = try AVAudioFile(
        forWriting: url,
        settings: settings,
        commonFormat: .pcmFormatInt16,
        interleaved: false
      )
      audioURL = url
      logger.info("live meeting audio file: \(url.path, privacy: .public)")
    } catch {
      logger.error("could not create live meeting audio file: \(error.localizedDescription, privacy: .public)")
      audioFile = nil
      audioURL = nil
    }
  }

  /// Close the audio file and hand its URL to the result. The file stays
  /// exactly where it was written — inside the record's assets folder.
  private func finalizeAudioFile() -> URL? {
    audioFile = nil
    let url = audioURL
    audioURL = nil
    return url
  }

  /// Close the file handle without touching the file. This is what every
  /// abort path calls, and the *only* thing it may do: audio is never
  /// auto-deleted (XIA-430 — deleting it is an explicit user verb, and a
  /// failed session is precisely when the recording is wanted most). There is
  /// deliberately no delete counterpart anywhere in this type.
  private func closeAudioFile() {
    audioFile = nil
    audioURL = nil
  }

  private func teardownWS() {
    webSocketTask = nil
    urlSession?.invalidateAndCancel()
    urlSession = nil
    wsDelegate = nil
  }
}

// MARK: - WebSocket delegate shim

/// URLSession delivers WebSocket delegate callbacks off-main; this shim hops
/// them to the main actor where `LiveMeetingSession` lives. Kept separate so
/// `LiveMeetingSession` itself stays a plain @MainActor ObservableObject.
private final class LiveMeetingSessionWSDelegate: NSObject, URLSessionWebSocketDelegate {
  weak var session: LiveMeetingSession?

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    guard let liveSession = self.session else { return }
    Task { @MainActor in
      liveSession.handleOpen()
    }
  }

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
    reason: Data?
  ) {
    guard let liveSession = self.session else { return }
    let rawValue = Int(closeCode.rawValue)
    let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) }
    Task { @MainActor in
      liveSession.handleClose(rawValue: rawValue, reason: reasonText)
    }
  }
}

#if DEBUG
// MARK: - Test seams

extension LiveMeetingSession {
  /// Drive the elapsed clock without a real recording (tests only).
  func setElapsedForTesting(_ value: TimeInterval) {
    elapsed = value
  }

  /// Put the session into a state without a microphone or a socket, so the
  /// pause/resume transitions can be driven (tests only). It installs a clock
  /// too when one is asked for, because everything pause does is arithmetic on
  /// that clock.
  func beginForTesting(startedAt: Date) {
    clock = SessionClock(startedAt: startedAt)
    // The production handler, not a stand-in: the pause/resume ordering rules
    // are about what *that* closure does at drain time.
    installCaptureHandler()
    state = .recording
    publishElapsed(now: startedAt)
  }

  /// The session's own clock, so a test can assert audio time rather than only
  /// the number the ticker last published.
  var clockForTesting: SessionClock? { clock }

  func setStateForTesting(_ value: SessionState) {
    state = value
  }

  /// The capture engine, so a test can put a buffer in flight across a real
  /// `pause()` / `resume()` — the thing the ordering rules are actually about.
  var captureForTesting: MicCapture { capture }

  /// How many delivered buffers got past `capturesAudio`.
  var keptBufferCountForTesting: Int { keptBufferCount }

  /// The Apple engine's hypothesis route, so the pause boundary can be driven
  /// without an analyzer. The same call `appleHypothesesTask` makes.
  func handleAppleHypothesisForTesting(_ hypothesis: Hypothesis) {
    handleAppleHypothesis(hypothesis)
  }
}
#endif
