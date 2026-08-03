import Foundation

/// When a batch (non-streaming) analyzer session may say what it heard.
///
/// The batch path infers finality from a teardown flag (`didFinalize`) rather
/// than from a result's own `isFinal`, because that configuration of
/// `DictationTranscriber` reports the session transcript rather than deltas.
/// The flag is set the instant the owner releases the trigger, so the *next*
/// result to arrive is labelled final whatever it actually contains — and the
/// one in flight at that moment is a preview of audio the analyzer has not
/// finished resolving. Sealing the session on it drops the words spoken in the
/// last moment before the release: "it ate the last couple of words", and only
/// when the release lands close behind the last word.
///
/// So a result never resolves `finish()`. Only two things do, and this type is
/// the whole of that decision:
///
/// - **end of results** — `finalizeAndFinishThroughEndOfInput()` has flushed
///   everything the analyzer had, and the last result is the complete one;
/// - **the watchdog** — the analyzer stalled, and the best text seen so far is
///   returned rather than nothing. Text delayed beats text lost, but a stuck
///   recognizer must still time out.
///
/// The interpretation of a result is deliberately unchanged from before this
/// type existed: the latest non-empty result *is* the transcript. Only the
/// moment of resolution moved.
struct BatchTranscript: Equatable {
  /// What happened, from `finish()`'s point of view.
  enum Event: Equatable {
    /// One more result arrived from the analyzer.
    case result
    /// The analyzer's results stream ended — finalization is complete.
    case resultsEnded
    /// The bounded wait expired with the analyzer still not done.
    case watchdog
  }

  /// The latest non-empty result text seen. Empty when the session produced
  /// nothing (a short or silent hold).
  private(set) var latest = ""

  init() {}

  /// Fold one result in. An empty result never erases text already heard: a
  /// trailing blank is the analyzer saying nothing new, not the session being
  /// retracted.
  mutating func record(_ text: String) {
    guard !text.isEmpty else { return }
    latest = text
  }

  /// The transcript to resolve `finish()` with, or nil to keep waiting.
  func resolution(after event: Event) -> String? {
    switch event {
    case .result:
      // The load-bearing line: a result — even the first one after the owner
      // let go — is never the end of the session.
      return nil
    case .resultsEnded, .watchdog:
      return latest
    }
  }
}
