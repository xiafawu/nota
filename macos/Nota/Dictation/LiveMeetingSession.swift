import AVFoundation
import Foundation
import os

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
    /// Temp 16 kHz mono CAF if the recording worked, else nil.
    let audioURL: URL?
  }

  // MARK: - Published state

  @Published private(set) var state: SessionState = .idle
  @Published private(set) var segments: [LiveSegment] = []
  @Published private(set) var partialText: String? = nil
  @Published private(set) var elapsed: TimeInterval = 0

  // MARK: - Lifecycle

  /// Start a live meeting: mic permission, capture engine, and the AssemblyAI
  /// realtime session. Returns once the server has sent `Begin`.
  ///
  /// On any setup failure the session transitions to `.failed(message)` first
  /// (so the UI's error banner renders off the published state) and then
  /// throws `MicCaptureError`/`AssemblyAIError`.
  func start() async throws {
    cancel()

    // 1. API key — fail fast, before permission prompts or any engine work.
    guard let apiKey = ApiKeyStore.value(for: "ASSEMBLYAI_API_KEY"), !apiKey.isEmpty else {
      failStart(AssemblyAIError.missingAPIKey)
      throw AssemblyAIError.missingAPIKey
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

    // 3. WebSocket (v3 realtime; no speech_model → Universal-3.5 Pro Streaming).
    guard let url = URL(string: "wss://streaming.assemblyai.com/v3/ws?sample_rate=16000") else {
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
    startedAt = Date()
    startElapsedTicker()
    prepareAudioFile()
    capture.onPCMBuffer = { [weak self] buffer in
      // MicCapture delivers converted 16 kHz mono Float32 buffers on main.
      Task { @MainActor in
        self?.handlePCMBuffer(buffer)
      }
    }
    do {
      try capture.start()
    } catch {
      logger.error("live meeting capture failed to start: \(error.localizedDescription, privacy: .public)")
      receiveTask?.cancel()
      receiveTask = nil
      webSocketTask?.cancel(with: .normalClosure, reason: nil)
      teardownWS()
      deleteAudioFile()
      failStart(error)
      throw error
    }
    logger.info("live meeting session started")
  }

  /// Stop the live meeting: send `Terminate`, wait for `Termination` (or the
  /// 5 s watchdog), stop capture, close the socket, finalize the audio file,
  /// and settle `state` to `.idle` before returning the accumulated result.
  func stop() async throws -> LiveMeetingResult {
    if let result = lastResult { return result }
    let isFailed: Bool = if case .failed(_) = state { true } else { false }
    guard state == .recording || isFailed else {
      throw LiveMeetingSessionError.notRecording
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
    capture.onPCMBuffer = nil
    capture.stop()
    receiveTask?.cancel()
    receiveTask = nil
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    teardownWS()

    let result = LiveMeetingResult(
      segments: segments,
      transcriptText: transcriptText,
      duration: duration ?? elapsed,
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
    receiveTask?.cancel()
    receiveTask = nil
    capture.onPCMBuffer = nil
    capture.stop()
    didSendTerminate = false
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    teardownWS()
    deleteAudioFile()

    // Reset state.
    segments = []
    partialText = nil
    elapsed = 0
    startedAt = nil
    didReceiveTermination = false
    finalDuration = nil
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
      state = .recording
      let begin = beginContinuation
      beginContinuation = nil
      begin?.resume(returning: ())
      logger.info("AssemblyAI live session began")

    case .speechStarted(let timestamp, let confidence):
      logger.info("SpeechStarted at \(timestamp)ms confidence=\(confidence)")

    case .turn(let transcript, let endOfTurn):
      if endOfTurn {
        segments.append(LiveSegment(id: UUID(), text: transcript, endTime: elapsed))
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
      if state == .recording {
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

  private static let openTimeoutNanoseconds: UInt64 = 10_000_000_000

  private var urlSession: URLSession?
  private var webSocketTask: URLSessionWebSocketTask?
  private var wsDelegate: LiveMeetingSessionWSDelegate?
  private var receiveTask: Task<Void, Never>?
  private var openWatchdog: Task<Void, Never>?
  private var finishWatchdog: Task<Void, Never>?
  private var elapsedTask: Task<Void, Never>?

  private var openContinuation: CheckedContinuation<Void, any Error>?
  private var beginContinuation: CheckedContinuation<Void, any Error>?
  private var finishContinuation: CheckedContinuation<TimeInterval?, Never>?

  private var didSendTerminate = false
  private var didReceiveTermination = false
  private var finalDuration: TimeInterval?
  private var startedAt: Date?

  private var audioFile: AVAudioFile?
  private var audioURL: URL?

  private var transcriptText: String {
    segments.map(\.text).joined(separator: "\n")
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
    } else if state == .recording {
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
    capture.onPCMBuffer = nil
    capture.stop()
    receiveTask?.cancel()
    receiveTask = nil
    teardownWS()
  }

  /// End the session and stash the result (server-initiated end / clean close).
  private func finalizeSession() {
    guard state != .idle else { return }
    elapsedTask?.cancel()
    elapsedTask = nil
    capture.onPCMBuffer = nil
    capture.stop()
    receiveTask?.cancel()
    receiveTask = nil
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    teardownWS()
    lastResult = LiveMeetingResult(
      segments: segments,
      transcriptText: transcriptText,
      duration: finalDuration ?? elapsed,
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

  private func handlePCMBuffer(_ buffer: AVAudioPCMBuffer) {
    guard state == .recording else { return }

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
        guard let self, !Task.isCancelled, let startedAt = self.startedAt else { return }
        self.elapsed = Date().timeIntervalSince(startedAt)
      }
    }
  }

  /// Create the temp 16 kHz mono CAF the result will carry. Failure is
  /// non-fatal: the transcript still works, `audioURL` just stays nil.
  private func prepareAudioFile() {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("NotaLiveMeeting-\(UUID().uuidString)")
      .appendingPathExtension("caf")
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

  /// Close the audio file and hand its URL to the result. The file is kept on
  /// disk — the persistence slice moves it into the output directory.
  private func finalizeAudioFile() -> URL? {
    audioFile = nil
    let url = audioURL
    audioURL = nil
    return url
  }

  private func deleteAudioFile() {
    audioFile = nil
    if let audioURL {
      try? FileManager.default.removeItem(at: audioURL)
    }
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
}
#endif
