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
  private let stateLock = NSLock()

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
      // SpeechAnalyzer path
      continuation.yield(AnalyzerInput(buffer: pcm))
    } else {
      // SFSpeechRecognizer fallback
      recognitionRequest?.append(pcm)
    }
  }

  func finish() async throws -> String {
    stateLock.lock()
    if let error = streamError {
      stateLock.unlock()
      throw error
    }
    if let text = finalText {
      stateLock.unlock()
      return text
    }
    stateLock.unlock()

    if let analyzer {
      // SpeechAnalyzer path: end input, finalize, wait for final result
      inputContinuation?.finish()
      stateLock.lock()
      didFinalize = true
      stateLock.unlock()
      do {
        try await analyzer.finalize(through: nil)
      } catch {
        throw error
      }
    } else if recognitionRequest != nil {
      // SFSpeechRecognizer fallback
      recognitionRequest?.endAudio()
    }

    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
      stateLock.lock()
      if let error = streamError {
        stateLock.unlock()
        continuation.resume(throwing: error)
        return
      }
      if let text = finalText {
        stateLock.unlock()
        continuation.resume(returning: text)
        return
      }
      finishContinuation = continuation
      stateLock.unlock()
    }
  }

  func cancel() {
    stateLock.lock()
    finishContinuation?.resume(throwing: CancellationError())
    finishContinuation = nil
    stateLock.unlock()

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
  }

  // MARK: - SpeechAnalyzer path

  @available(macOS 26, *)
  private func startWithSpeechAnalyzer() async throws {
    let t = DictationTranscriber(
      locale: Locale(identifier: "en-US"),
      preset: .progressiveLongDictation
    )
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
            self.stateLock.lock()
            self.finalText = text
            let fc = self.finishContinuation
            self.finishContinuation = nil
            self.stateLock.unlock()
            fc?.resume(returning: text)
          }
        }
      } catch {
        self.stateLock.lock()
        self.streamError = error
        let fc = self.finishContinuation
        self.finishContinuation = nil
        self.stateLock.unlock()
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
        self.stateLock.lock()
        self.streamError = error
        let fc = self.finishContinuation
        self.finishContinuation = nil
        self.stateLock.unlock()
        fc?.resume(throwing: error)
        return
      }

      if let result = result {
        let text = result.bestTranscription.formattedString
        let isFinal = result.isFinal
        self.hypothesisContinuation.yield(Hypothesis(text: text, isFinal: isFinal))

        if isFinal {
          self.stateLock.lock()
          self.finalText = text
          let fc = self.finishContinuation
          self.finishContinuation = nil
          self.stateLock.unlock()
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
