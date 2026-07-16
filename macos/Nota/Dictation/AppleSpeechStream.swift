import AVFoundation
import CoreMedia
import Foundation
import os
import Speech

// MARK: - AppleSpeechStream

/// On-device Apple speech recognition.
///
/// Primary path: `SpeechAnalyzer` + `DictationTranscriber` (`.progressiveLongDictation`
/// preset), available on macOS 26+. Falls back to `SFSpeechRecognizer` with
/// `requiresOnDeviceRecognition` if the new API is unavailable.
///
/// Emits partial and final hypotheses through an `AsyncStream<Hypothesis>`.
final class AppleSpeechStream: SpeechStream {
  // MARK: - SpeechAnalyzer path (macOS 26+)

  private var transcriber: DictationTranscriber?
  private var analyzer: SpeechAnalyzer?
  private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
  private var analyzerTask: Task<Void, any Error>?
  private var didFinalize = false

  /// Format negotiated via `SpeechAnalyzer.bestAvailableAudioFormat`. Feeding
  /// `AnalyzerInput` any other format traps inside the Speech framework
  /// (EXC_BREAKPOINT in `AnalyzerInput.data(from:)`), so every buffer is
  /// converted to this format first.
  private var analyzerFormat: AVAudioFormat?
  private var converter: AVAudioConverter?

  // MARK: - SFSpeechRecognizer fallback

  private var recognizer: SFSpeechRecognizer?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?

  // MARK: - Shared state

  private let logger = Logger(subsystem: "com.xiafawu.nota", category: "dictation.speech")

  private let (stream, hypothesisContinuation) = AsyncStream<Hypothesis>.makeStream()
  var hypotheses: AsyncStream<Hypothesis> { stream }

  private var finalText: String?
  private var finishContinuation: CheckedContinuation<String, any Error>?
  private var streamError: (any Error)?
  private let stateLock = OSAllocatedUnfairLock(initialState: ())

  // MARK: - SpeechStream

  func start() async throws {
    cancel()

    // Try SpeechAnalyzer first (macOS 26+)
    if #available(macOS 26, *) {
      do {
        try await startWithSpeechAnalyzer()
        return
      } catch {
        logger.warning("SpeechAnalyzer path failed: \(error.localizedDescription, privacy: .public); falling back to SFSpeechRecognizer")
      }
    }

    // Fallback: SFSpeechRecognizer
    try await startWithSFSpeechRecognizer()
  }

  func feed(_ pcm: AVAudioPCMBuffer) throws {
    if let continuation = inputContinuation {
      // SpeechAnalyzer path — must match the negotiated analyzer format.
      guard let analyzerFormat, let converted = convertBuffer(pcm, to: analyzerFormat) else {
        return
      }
      continuation.yield(AnalyzerInput(buffer: converted))
    } else {
      // SFSpeechRecognizer fallback
      recognitionRequest?.append(pcm)
    }
  }

  /// Convert `pcm` to `target` format, reusing the cached converter when the
  /// source format is unchanged. Returns the input buffer untouched when it is
  /// already in the target format; returns nil (dropping the buffer) when
  /// conversion is impossible — dropped audio degrades transcription, a
  /// mismatched `AnalyzerInput` kills the process.
  func convertBuffer(_ pcm: AVAudioPCMBuffer, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
    guard pcm.frameLength > 0 else { return nil }
    if pcm.format.isEqual(target) { return pcm }

    if converter == nil
      || converter?.inputFormat.isEqual(pcm.format) != true
      || converter?.outputFormat.isEqual(target) != true {
      converter = AVAudioConverter(from: pcm.format, to: target)
    }
    guard let converter else {
      logger.error("No AVAudioConverter from \(pcm.format, privacy: .public) to analyzer format")
      return nil
    }

    let ratio = target.sampleRate / pcm.format.sampleRate
    let capacity = AVAudioFrameCount((Double(pcm.frameLength) * ratio).rounded(.up)) + 16
    guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
      return nil
    }

    var suppliedInput = false
    var conversionError: NSError?
    let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
      guard !suppliedInput else {
        inputStatus.pointee = .noDataNow
        return nil
      }
      suppliedInput = true
      inputStatus.pointee = .haveData
      return pcm
    }

    guard status == .haveData || status == .inputRanDry,
          output.frameLength > 0,
          conversionError == nil else {
      logger.error("Analyzer format conversion failed: \(conversionError?.localizedDescription ?? String(describing: status), privacy: .public)")
      return nil
    }
    return output
  }

  func finish() async throws -> String {
    // Check for already-available results under lock.
    let earlyResult: Result<String, any Error>? = stateLock.withLock { _ in
      if let error = streamError {
        return .failure(error)
      }
      if let text = finalText {
        return .success(text)
      }
      return nil
    }
    if let earlyResult {
      return try earlyResult.get()
    }

    if let analyzer {
      // SpeechAnalyzer path: end input, then finalize in a child task.
      // finalizeAndFinishThroughEndOfInput() is the documented teardown;
      // finalize(through: nil) never returns when the session produced no
      // results (short/silent hold). Not awaited inline so the watchdog
      // below can still unstick finish() if the OS call stalls.
      inputContinuation?.finish()
      stateLock.withLock { _ in
        didFinalize = true
      }
      Task { [weak self] in
        do {
          try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
          guard let self else { return }
          let fc = self.stateLock.withLock { _ in
            self.streamError = error
            let fc = self.finishContinuation
            self.finishContinuation = nil
            return fc
          }
          fc?.resume(throwing: error)
        }
      }
    } else if recognitionRequest != nil {
      // SFSpeechRecognizer fallback
      recognitionRequest?.endAudio()
    }

    // Watchdog: if neither a final result nor stream teardown resumes us,
    // return whatever text we have instead of wedging the UI in "Stopping".
    let watchdog = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 5_000_000_000)
      guard let self, !Task.isCancelled else { return }
      let (fc, text) = self.stateLock.withLock { _ -> (CheckedContinuation<String, any Error>?, String) in
        let fc = self.finishContinuation
        self.finishContinuation = nil
        return (fc, self.finalText ?? "")
      }
      if fc != nil {
        self.logger.error("finish() watchdog fired — analyzer finalize stalled; returning partial text")
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
    }

    inputContinuation?.finish()
    inputContinuation = nil
    analyzerTask?.cancel()
    analyzerTask = nil
    recognitionTask?.cancel()
    recognitionTask = nil
    recognitionRequest = nil

    transcriber = nil
    analyzer = nil
    recognizer = nil
    finalText = nil
    streamError = nil
    analyzerFormat = nil
    converter = nil
  }

  // MARK: - SpeechAnalyzer path

  @available(macOS 26, *)
  private func startWithSpeechAnalyzer() async throws {
    let t = DictationTranscriber(
      locale: Locale(identifier: "en-US"),
      preset: .progressiveLongDictation
    )

    // Negotiate the input format the analyzer actually accepts (Int16 on
    // current macOS 26 builds). nil means no compatible assets — fall back to
    // SFSpeechRecognizer instead of trapping on the first buffer.
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else {
      throw AppleSpeechError.unavailable
    }
    analyzerFormat = format
    logger.info("SpeechAnalyzer negotiated format: \(format, privacy: .public)")

    let a = SpeechAnalyzer(modules: [t])
    transcriber = t
    analyzer = a

    let (inputStream, inputCont) = AsyncStream<AnalyzerInput>.makeStream()
    inputContinuation = inputCont

    // Background task: feed input to analyzer
    analyzerTask = Task {
      try await a.start(inputSequence: inputStream)
    }

    // Background task: read results and emit hypotheses
    Task { [weak self] in
      guard let self else { return }
      do {
        for try await result in t.results {
          let text = String(result.text.characters)
          let isFinal = self.didFinalize
          self.hypothesisContinuation.yield(Hypothesis(text: text, isFinal: isFinal))

          if isFinal {
            let fc = self.stateLock.withLock { _ in
              self.finalText = text
              let fc = self.finishContinuation
              self.finishContinuation = nil
              return fc
            }
            fc?.resume(returning: text)
          }
        }
        // Results stream ended (analyzer finished). A short or silent session
        // yields zero results — resume finish() with what we have (possibly
        // "") or it waits forever.
        let (fc, text) = self.stateLock.withLock { _ -> (CheckedContinuation<String, any Error>?, String) in
          if self.finalText == nil { self.finalText = "" }
          let fc = self.finishContinuation
          self.finishContinuation = nil
          return (fc, self.finalText ?? "")
        }
        fc?.resume(returning: text)
      } catch {
        let fc = self.stateLock.withLock { _ in
          self.streamError = error
          let fc = self.finishContinuation
          self.finishContinuation = nil
          return fc
        }
        fc?.resume(throwing: error)
      }
    }

    logger.info("SpeechAnalyzer dictation started")
  }

  // MARK: - SFSpeechRecognizer fallback

  private func startWithSFSpeechRecognizer() async throws {
    guard let r = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
      throw AppleSpeechError.unavailable
    }
    recognizer = r

    guard r.isAvailable else {
      throw AppleSpeechError.unavailable
    }

    let status = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status)
      }
    }
    guard status == .authorized else {
      throw AppleSpeechError.notAuthorized
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.requiresOnDeviceRecognition = true
    recognitionRequest = request

    recognitionTask = r.recognitionTask(with: request) { [weak self] result, error in
      guard let self else { return }

      if let error = error {
        let fc = self.stateLock.withLock { _ in
          self.streamError = error
          let fc = self.finishContinuation
          self.finishContinuation = nil
          return fc
        }
        fc?.resume(throwing: error)
        return
      }

      if let result = result {
        let text = result.bestTranscription.formattedString
        let isFinal = result.isFinal
        self.hypothesisContinuation.yield(Hypothesis(text: text, isFinal: isFinal))

        if isFinal {
          let fc = self.stateLock.withLock { _ in
            self.finalText = text
            let fc = self.finishContinuation
            self.finishContinuation = nil
            return fc
          }
          fc?.resume(returning: text)
        }
      }
    }

    logger.info("SFSpeechRecognizer dictation started (fallback)")
  }
}

// MARK: - Errors

enum AppleSpeechError: LocalizedError {
  case unavailable
  case notAuthorized

  var errorDescription: String? {
    switch self {
    case .unavailable:
      return "On-device speech recognition is currently unavailable."
    case .notAuthorized:
      return "Speech recognition permission has not been granted."
    }
  }
}
