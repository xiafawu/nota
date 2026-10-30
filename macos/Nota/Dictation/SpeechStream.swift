import AVFoundation
import Foundation

// MARK: - Hypothesis

struct Hypothesis: Equatable, Sendable {
  let text: String
  let isFinal: Bool
  /// True when `text` is a newly finalized *delta* — one more piece of the
  /// session, to be appended — rather than the session's transcript so far.
  ///
  /// Set by streaming-mode Apple recognition (a finalized delta) and by
  /// AssemblyAI realtime asked to deliver while speaking (one finished turn).
  /// Every other producer keeps the original contract (`text` is the whole
  /// hypothesis), so the default keeps existing call sites and their meaning
  /// unchanged.
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
  /// True when this stream can render a live rough draft mid-session — it
  /// yields hypotheses as speech is recognized, even if those hypotheses are
  /// whole-formatted turns rather than deltas.
  ///
  /// Distinct from `deliversSegments`: an engine may preview what is being
  /// said (HUD rough draft) without being able to deliver sentence deltas into
  /// the target document. The draft gate uses this; delivery uses
  /// `deliversSegments`.
  var supportsLiveDraft: Bool { get }
  /// True when every segment this stream emits is a whole utterance — a turn
  /// the engine itself closed on a pause — rather than an arbitrary run of
  /// finalized text.
  ///
  /// It decides how a segment is cut for delivery. Apple's deltas are cut at
  /// sentence terminators by `SentenceSegmenter`. AssemblyAI's turns arrive
  /// unpunctuated (the socket does not ask for `format_turns`), so a
  /// terminator-cutter would hold every one of them until the 240-character
  /// valve or the end of the session — exactly the "nothing until I stop"
  /// behavior streaming exists to replace. A turn is delivered as one unit.
  var segmentsAreUtterances: Bool { get }
  func start() async throws
  func feed(_ pcm: AVAudioPCMBuffer) throws
  func finish() async throws -> String
  func cancel()
}

extension SpeechStream {
  var deliversSegments: Bool { false }
  /// A stream that delivers segments necessarily previews as it goes.
  var supportsLiveDraft: Bool { deliversSegments }
  var segmentsAreUtterances: Bool { false }
}
