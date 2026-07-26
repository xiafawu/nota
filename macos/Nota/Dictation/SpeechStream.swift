import AVFoundation
import Foundation

// MARK: - Hypothesis

struct Hypothesis: Equatable, Sendable {
  let text: String
  let isFinal: Bool
  /// True when `text` is a newly finalized *delta* — one more piece of the
  /// session, to be appended — rather than the session's transcript so far.
  ///
  /// Only streaming-mode Apple recognition sets this. Every other producer
  /// keeps the original contract (`text` is the whole hypothesis), so the
  /// default keeps existing call sites and their meaning unchanged.
  let isSegment: Bool

  init(text: String, isFinal: Bool, isSegment: Bool = false) {
    self.text = text
    self.isFinal = isFinal
    self.isSegment = isSegment
  }
}

// MARK: - SpeechStream protocol

protocol SpeechStream: AnyObject {
  var hypotheses: AsyncStream<Hypothesis> { get }
  /// True when this stream emits finalized segments mid-session
  /// (`Hypothesis.isSegment`) instead of only a transcript at teardown.
  ///
  /// Only meaningful once `start()` has returned: a stream asked for streaming
  /// can still land on an engine that cannot provide it, and the caller has to
  /// know that before it decides how to deliver text.
  var deliversSegments: Bool { get }
  func start() async throws
  func feed(_ pcm: AVAudioPCMBuffer) throws
  func finish() async throws -> String
  func cancel()
}

extension SpeechStream {
  var deliversSegments: Bool { false }
}
