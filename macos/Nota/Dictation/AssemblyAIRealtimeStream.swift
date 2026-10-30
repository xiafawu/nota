import AVFoundation
import Foundation
import os

// MARK: - AssemblyAI Errors

enum AssemblyAIError: LocalizedError, Equatable {
  case missingAPIKey
  case connectionTimeout
  case webSocketError(String)
  case serverError(String)
  case malformedMessage(String)

  var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      return "AssemblyAI: missing API key"
    case .connectionTimeout:
      return "AssemblyAI: connection timed out"
    case .webSocketError(let detail):
      return "AssemblyAI: \(detail)"
    case .serverError(let detail):
      return "AssemblyAI: \(detail)"
    case .malformedMessage(let detail):
      return "AssemblyAI: malformed response — \(detail)"
    }
  }
}

// MARK: - Engine factory

/// Select the concrete `SpeechStream` for the chosen engine.
/// Tests verify the type mapping through this function.
///
/// `contextualHints` biases the Apple on-device recognizer (see `ContextHints`).
/// The AssemblyAI realtime engine has no equivalent per-session hint channel, so
/// it ignores them.
///
/// `streaming` asks the Apple analyzer for its streaming mode — a volatile tail
/// for the live draft plus finalized deltas. AssemblyAI realtime yields partial
/// turns in every mode, so it needs no such request for the draft.
///
/// `deliversWhileSpeaking` asks for segments to *deliver* mid-session. Apple
/// gets them from streaming mode already; AssemblyAI emits each finished turn
/// as a segment only when this is set, because a segment is text bound for the
/// owner's live document and only `.streaming` delivery may put it there. Kept
/// apart from `streaming` on purpose: AssemblyAI runs with a live draft in
/// every mode (`DictationSessionPlan.wantsLiveDraft`), and tying turns-as-
/// segments to that flag would turn on mid-session delivery for Insert on
/// Release and Review too.
func makeDictationStream(
  for engine: EngineChoice,
  contextualHints: [String] = [],
  streaming: Bool = false,
  deliversWhileSpeaking: Bool = false
) -> any SpeechStream {
  switch engine {
  case .apple:
    return AppleSpeechStream(contextualHints: contextualHints, streaming: streaming)
  case .assemblyAIRealtime:
    return AssemblyAIRealtimeStream(deliversTurns: deliversWhileSpeaking)
  }
}

// MARK: - AssemblyAITurnRouter

/// What one AssemblyAI `Turn` message becomes, as a pure decision.
///
/// A partial (`end_of_turn: false`) is the live draft's volatile tail. A
/// finished turn is text the session has finalized: always accumulated into
/// the transcript `finish()` returns, and — when the stream was asked to
/// deliver while speaking — also yielded as a *segment*, which the controller
/// sends down the same append-only, in-order, fixed-target delivery queue
/// Apple's deltas use. Nothing about those guarantees is AssemblyAI-specific;
/// they belong to the queue.
///
/// **One segment per turn, ever.** With `format_turns=true` the v3 server sends
/// two `end_of_turn: true` messages for the same `turn_order` — the raw text,
/// then the same turn again with `turn_is_formatted: true`. The socket here
/// does not ask for formatting, so today there is one; but delivery is
/// append-only and a second final for the same turn would type the sentence
/// into the owner's document twice. The first final for a turn wins and any
/// later one is dropped, for the transcript as well as for delivery. Pinned by
/// test against the documented shape, not against the live server.
struct AssemblyAITurnRouter {
  /// Whether finished turns are yielded as deliverable segments.
  let deliversTurns: Bool
  /// `turn_order` of the last turn that was finalized, to drop a repeat.
  private var lastFinalTurnOrder: Int?

  init(deliversTurns: Bool) {
    self.deliversTurns = deliversTurns
  }

  struct Routed: Equatable {
    /// Hypotheses to yield, in order.
    var hypotheses: [Hypothesis] = []
    /// A finished turn to fold into the session transcript, or nil.
    var finalized: String?
  }

  mutating func route(
    transcript: String,
    endOfTurn: Bool,
    turnOrder: Int? = nil
  ) -> Routed {
    guard endOfTurn else {
      return Routed(hypotheses: [Hypothesis(text: transcript, isFinal: false)])
    }
    if let turnOrder, turnOrder == lastFinalTurnOrder {
      // The formatted repeat of a turn already finalized (see the type doc).
      return Routed()
    }
    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      // A pause can close a turn that heard nothing. There is no text to
      // finalize, and an empty final would add a blank line to the draft; a
      // cleared tail is all it means.
      return Routed(hypotheses: [Hypothesis(text: "", isFinal: false)])
    }
    lastFinalTurnOrder = turnOrder
    return Routed(
      hypotheses: [Hypothesis(text: trimmed, isFinal: true, isSegment: deliversTurns)],
      finalized: trimmed
    )
  }
}

// MARK: - AssemblyAIRealtimeStream

/// SpeechStream backed by AssemblyAI real-time WebSocket.
///
/// One WebSocket per dictation session. Audio is mono 16 kHz Int16 PCM sent
/// as binary frames. Begin/Turn/Termination JSON events are mapped to
/// `Hypothesis` through `AssemblyAITurnRouter`. The session transcript is
/// sealed only when `finish()` receives Termination or the watchdog fires; with
/// `deliversTurns` each finished turn is also yielded as a segment as it lands,
/// so Insert While Speaking types it in while the owner is still talking.
final class AssemblyAIRealtimeStream: NSObject, SpeechStream {
  // MARK: - Debug file log

  private let debugLog = DebugFileLog.shared()

  private func debug(_ line: String) {
    Task { await debugLog.write(line) }
    logger.info("\(line, privacy: .public)")
  }

  // MARK: - Parsed message types (internal for testability)

  enum ParsedMessage: Equatable {
    case begin(id: String)
    case speechStarted(timestamp: Int, confidence: Double)
    /// `turnOrder` and `isFormatted` default so a message that omits them (and
    /// the tests that predate them) still reads as the turn it is.
    case turn(transcript: String, endOfTurn: Bool, turnOrder: Int? = nil, isFormatted: Bool = false)
    case termination(audioDurationSeconds: Double?)

    /// Parse an AssemblyAI real-time JSON message string.
    /// Returns nil for malformed or unknown message types.
    static func fromJSON(_ text: String) -> ParsedMessage? {
      guard let data = text.data(using: .utf8),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let type = json["type"] as? String
      else { return nil }

      switch type {
      case "Begin":
        guard let id = json["id"] as? String else { return nil }
        return .begin(id: id)

      case "SpeechStarted":
        return .speechStarted(
          timestamp: json["timestamp"] as? Int ?? 0,
          confidence: json["confidence"] as? Double ?? 0
        )

      case "Turn":
        let transcript = json["transcript"] as? String ?? ""
        let endOfTurn = json["end_of_turn"] as? Bool ?? false
        return .turn(
          transcript: transcript,
          endOfTurn: endOfTurn,
          turnOrder: json["turn_order"] as? Int,
          isFormatted: json["turn_is_formatted"] as? Bool ?? false
        )

      case "Termination":
        let duration = json["audio_duration_seconds"] as? Double
        return .termination(audioDurationSeconds: duration)

      default:
        return nil
      }
    }

    /// Map a WebSocket close code raw value to a human-readable error message.
    /// Returns nil for normal/expected close codes.
    static func errorMessage(forCloseCode rawValue: Int, reason: String?) -> String? {
      switch rawValue {
      case 1000, 1001: // normalClosure, goingAway
        return nil
      case 4001:
        return "Invalid JSON sent to AssemblyAI"
      case 4002:
        return "AssemblyAI: invalid API key"
      case 4003:
        return "AssemblyAI: trial expired or quota exceeded"
      case 4004:
        return "AssemblyAI: sample rate mismatch"
      case 4005..<5000:
        return "AssemblyAI: server error (code \(rawValue))"
      default:
        if rawValue >= 4000 {
          return "AssemblyAI: error (code \(rawValue))"
        }
        if let reason, !reason.isEmpty {
          return "WebSocket closed: \(reason)"
        }
        return nil
      }
    }
  }

  // MARK: - SpeechStream

  private let logger = Logger(subsystem: "com.xiafawu.nota", category: "dictation.assemblyai")

  private let (stream, hypothesisContinuation) = AsyncStream<Hypothesis>.makeStream()
  var hypotheses: AsyncStream<Hypothesis> { stream }

  /// Turn events (including `end_of_turn: false` partials) stream in as speech
  /// is recognized, so the HUD rough draft can grow live in every mode.
  var supportsLiveDraft: Bool { true }

  /// Whether this session was asked to deliver each finished turn mid-session.
  private let deliversTurnsRequested: Bool
  /// True once `start()` has opened the socket for a session that asked for
  /// turns. Like Apple's, only meaningful after `start()` returns: before it,
  /// the caller must not plan on segments that may never come.
  private var turnsActive = false
  var deliversSegments: Bool { turnsActive }
  /// A turn is an utterance the server closed on a pause — delivered whole.
  var segmentsAreUtterances: Bool { true }

  /// Guarded by `stateLock`: messages are routed on the receive task.
  private var router: AssemblyAITurnRouter

  init(deliversTurns: Bool = false) {
    self.deliversTurnsRequested = deliversTurns
    self.router = AssemblyAITurnRouter(deliversTurns: deliversTurns)
    super.init()
  }

  // WebSocket
  private var urlSession: URLSession?
  private var webSocketTask: URLSessionWebSocketTask?

  // State
  private var finalText: String?
  private var finalTurnCount = 0
  private var finishContinuation: CheckedContinuation<String, any Error>?
  private var openContinuation: CheckedContinuation<Void, any Error>?
  private var streamError: (any Error)?
  private let stateLock = OSAllocatedUnfairLock(initialState: ())
  private var receiveTask: Task<Void, Never>?
  private var didSendTerminate = false

  // PCM converter (Float32 → Int16) — reused across feed() calls
  private var pcmConverter: AVAudioConverter?
  private var int16Format: AVAudioFormat?

  // MARK: - SpeechStream conformance

  func start() async throws {
    cancel()

    // 1. Check API key
    guard let apiKey = ApiKeyStore.value(for: "ASSEMBLYAI_API_KEY"), !apiKey.isEmpty else {
      throw AssemblyAIError.missingAPIKey
    }

    // 2. Build request
    guard let url = URL(string: "wss://streaming.assemblyai.com/v3/ws?sample_rate=16000") else {
      throw AssemblyAIError.webSocketError("invalid URL")
    }
    var request = URLRequest(url: url)
    request.setValue(apiKey, forHTTPHeaderField: "Authorization")

    // 3. Create WebSocket
    let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    urlSession = session
    let task = session.webSocketTask(with: request)
    webSocketTask = task
    task.resume()

    // 4. Wait for open (with timeout)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      let handled = stateLock.withLock { _ -> Bool in
        if let error = streamError {
          continuation.resume(throwing: error)
          return true
        }
        openContinuation = continuation
        return false
      }
      if handled { return }

      // Timeout watchdog
      Task { [weak self] in
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        guard let self else { return }
        let oc = self.stateLock.withLock { _ -> CheckedContinuation<Void, any Error>? in
          let oc = self.openContinuation
          self.openContinuation = nil
          return oc
        }
        oc?.resume(throwing: AssemblyAIError.connectionTimeout)
      }
    }

    // 5. Start listening for messages
    stateLock.withLock { _ in
      router = AssemblyAITurnRouter(deliversTurns: deliversTurnsRequested)
    }
    turnsActive = deliversTurnsRequested
    listenForMessages()
  }

  func feed(_ pcm: AVAudioPCMBuffer) throws {
    guard let task = webSocketTask else { return }

    // Convert Float32 16kHz mono → Int16 16kHz mono
    guard let int16Buf = convertToInt16(pcm) else { return }

    let count = Int(int16Buf.frameLength)
    guard count > 0, let ptr = int16Buf.int16ChannelData?[0] else { return }

    let data = Data(bytes: ptr, count: count * MemoryLayout<Int16>.stride)
    task.send(.data(data)) { [weak self] error in
      if let error {
        self?.logger.error("WS send failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  func finish() async throws -> String {
    // Cancel any pending open
    stateLock.withLock { _ in
      openContinuation?.resume(throwing: CancellationError())
      openContinuation = nil
    }

    // Deliberately NO early return on accumulated text: a final turn can still
    // be in flight when the owner releases, and returning now would eat the
    // last utterance (observed: n-1 of n sentences delivered). The server
    // flushes in-flight turns before Termination, so the only complete answer
    // is the one Termination — or the watchdog — seals.

    // Send Terminate to signal end-of-stream
    sendTerminate()

    // Watchdog: if the provider doesn't respond, return what we have
    let watchdog = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 5_000_000_000)
      guard let self, !Task.isCancelled else { return }
      let (fc, text) = self.stateLock.withLock { _ -> (CheckedContinuation<String, any Error>?, String) in
        let fc = self.finishContinuation
        self.finishContinuation = nil
        return (fc, self.finalText ?? "")
      }
      if fc != nil {
        self.logger.error("finish() watchdog fired — AssemblyAI finalize stalled; returning accumulated text")
        Task { await self.debugLog.write("finish() watchdog fired chars=\(text.count)") }
      }
      fc?.resume(returning: text)
    }
    defer { watchdog.cancel() }

    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
      let handled = stateLock.withLock { _ in
        if let error = streamError {
          continuation.resume(throwing: error)
          return true
        }
        if let text = finalText {
          continuation.resume(returning: text)
          return true
        }
        finishContinuation = continuation
        return false
      }
      _ = handled
    }
  }

  func cancel() {
    stateLock.withLock { _ in
      finishContinuation?.resume(throwing: CancellationError())
      finishContinuation = nil
      openContinuation?.resume(throwing: CancellationError())
      openContinuation = nil
    }
    // Deliberately NOT hypothesisContinuation.finish(): `start()` begins with
    // `cancel()` as a defensive reset, and finishing the stream here would
    // permanently end the controller's for-await loop before the new session
    // yields anything — every Turn hypothesis then lands in a finished stream
    // and the HUD draft never receives it (observed: pill empty with
    // liveDraft=true). The loop's lifetime belongs to the controller's
    // per-session hypothesisTask, which it cancels itself.
    receiveTask?.cancel()
    receiveTask = nil
    sendTerminate()
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    teardown()
  }

  // MARK: - Private

  private func sendTerminate() {
    guard !didSendTerminate else { return }
    didSendTerminate = true
    let payload = "{\"type\":\"Terminate\"}"
    webSocketTask?.send(.string(payload)) { [weak self] error in
      if let error {
        self?.logger.warning("Terminate send failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  private func listenForMessages() {
    receiveTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled, let task = self.webSocketTask {
        do {
          let message = try await task.receive()
          self.processMessage(message)
        } catch {
          // If we sent terminate and connection closed normally, that's fine
          if self.didSendTerminate {
            let fc = self.stateLock.withLock { _ -> CheckedContinuation<String, any Error>? in
              let fc = self.finishContinuation
              self.finishContinuation = nil
              return fc
            }
            fc?.resume(returning: self.finalText ?? "")
          } else {
            self.handleReceiveError(error)
          }
          break
        }
      }
    }
  }

  private func processMessage(_ message: URLSessionWebSocketTask.Message) {
    guard case .string(let text) = message else { return }
    processJSON(text)
  }

  private func processJSON(_ text: String) {
    guard let parsed = ParsedMessage.fromJSON(text) else {
      logger.warning("Malformed message: \(text.prefix(100), privacy: .public)")
      hypothesisContinuation.yield(Hypothesis(text: "", isFinal: false))
      return
    }

    switch parsed {
    case .begin(let id):
      debug("session started id=\(id)")

    case .speechStarted(let timestamp, let confidence):
      debug("SpeechStarted ts=\(timestamp) conf=\(confidence)")

    case .turn(let transcript, let endOfTurn, let turnOrder, let isFormatted):
      debug(
        "Turn final=\(endOfTurn) order=\(turnOrder.map(String.init) ?? "nil") "
          + "formatted=\(isFormatted) chars=\(transcript.count) text=\"\(transcript)\""
      )
      let routed = stateLock.withLock { _ in
        router.route(transcript: transcript, endOfTurn: endOfTurn, turnOrder: turnOrder)
      }
      for hypothesis in routed.hypotheses {
        hypothesisContinuation.yield(hypothesis)
      }

      if let finished = routed.finalized {
        stateLock.withLock { _ in
          // Turns arrive per utterance — accumulate, never overwrite. A
          // multi-sentence hold used to return only the last turn.
          if let existing = finalText, !existing.isEmpty {
            finalText = existing + "\n" + finished
          } else {
            finalText = finished
          }
          finalTurnCount += 1
          let text = self.finalText!
          debug("final turn \(self.finalTurnCount) accumulated chars=\(text.count)")
          // Do NOT resolve finish() here: more in-flight turns can follow, and
          // only Termination is the authoritative end of the session.
        }
      }

    case .termination:
      let text = stateLock.withLock { _ -> String in
        if finalText == nil { finalText = "" }
        let text = finalText!
        let fc = finishContinuation
        finishContinuation = nil
        fc?.resume(returning: text)
        return text
      }
      debug("termination returning chars=\(text.count)")
    }
  }

  private func handleReceiveError(_ error: any Error) {
    logger.error("WS receive error: \(error.localizedDescription, privacy: .public)")
    stateLock.withLock { _ in
      streamError = error
      let fc = finishContinuation
      finishContinuation = nil
      fc?.resume(throwing: error)
    }
    hypothesisContinuation.finish()
  }

  private func convertToInt16(_ pcm: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    // Short-circuit: already Int16 at 16kHz mono
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

    // Lazily create the Int16 format and converter
    if int16Format == nil {
      int16Format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)
    }
    guard let int16Format else { return nil }

    let capacity = pcm.frameLength
    guard let output = AVAudioPCMBuffer(pcmFormat: int16Format, frameCapacity: capacity) else {
      return nil
    }
    output.frameLength = capacity

    guard let dst = output.int16ChannelData?[0] else { return nil }
    let src = UnsafeBufferPointer(start: floatData[0], count: Int(capacity))

    for i in 0..<Int(capacity) {
      let clamped = max(-1.0, min(1.0, src[i]))
      dst[i] = Int16(clamped * Float(Int16.max))
    }

    return output
  }

  private func handleClose(code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    let rawValue = code.rawValue
    let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) }

    if let errorMsg = ParsedMessage.errorMessage(forCloseCode: Int(rawValue), reason: reasonStr) {
      logger.error("WS closed: \(errorMsg, privacy: .public)")
      let error = AssemblyAIError.serverError(errorMsg)
      stateLock.withLock { _ in
        streamError = error
        let fc = finishContinuation
        finishContinuation = nil
        fc?.resume(throwing: error)
        let oc = openContinuation
        openContinuation = nil
        oc?.resume(throwing: error)
      }
    } else {
      // Normal close — if finish() is waiting, unstick it
      let (fc, text) = stateLock.withLock { _ -> (CheckedContinuation<String, any Error>?, String) in
        guard finalText != nil || didSendTerminate else { return (nil, "") }
        let fc = finishContinuation
        finishContinuation = nil
        return (fc, finalText ?? "")
      }
      fc?.resume(returning: text)
    }

    hypothesisContinuation.finish()
  }

  private func teardown() {
    webSocketTask = nil
    urlSession?.invalidateAndCancel()
    urlSession = nil
    pcmConverter = nil
    int16Format = nil
    finalText = nil
    streamError = nil
    didSendTerminate = false
    turnsActive = false
  }
}

// MARK: - URLSessionWebSocketDelegate

extension AssemblyAIRealtimeStream: URLSessionWebSocketDelegate {
  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    let oc = stateLock.withLock { _ -> CheckedContinuation<Void, any Error>? in
      let oc = openContinuation
      openContinuation = nil
      return oc
    }
    oc?.resume(returning: ())
    logger.info("WebSocket connected")
  }

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
    reason: Data?
  ) {
    handleClose(code: closeCode, reason: reason)
    teardown()
  }
}
