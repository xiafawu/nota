import Foundation

// MARK: - HUDState

/// Pure view-model mapping `DictationController` state to HUD display state.
/// Unit-testable without AppKit.
enum HUDState: Equatable {
  case hidden
  /// Microphone active with live RMS level (0…1 normalized).
  case listening(level: Float)
  /// Post-capture processing step.
  case processing(step: String)
  /// Injection succeeded; show the injected snippet briefly.
  case success(snippet: String)
  /// Non-fatal warning (polish failure, secure-field refusal).
  case warning(message: String)
  /// Fatal error message.
  case error(message: String)
}

// MARK: - HUDDraft

/// What the HUD is told about the recognition still in flight.
///
/// Two full-length strings, not one merged line. The pill and the bar each show
/// a single bounded line and never needed more; the prompter shows the whole
/// session with the un-finalized tail dimmed, and a 120-character merge cannot
/// be un-merged. So the split lives here, at the source, rather than in
/// whichever view happens to need it.
///
/// Deliberately NOT folded into `HUDState`: `DictationHUDController` compares
/// states for equality to decide whether an auto-hidden notice has been
/// consumed, and a field that changes on every syllable would make every one of
/// those comparisons miss.
struct HUDDraft: Equatable, Sendable {
  /// Everything the recognizer has finalized this session, at full length.
  var finalized: String = ""
  /// The recognizer's current un-finalized tail, at full length.
  var volatileTail: String = ""

  static let empty = HUDDraft()

  var isEmpty: Bool { finalized.isEmpty && volatileTail.isEmpty }

  /// The one bounded line the pill and the bar show.
  ///
  /// Exactly what the pill was handed before the other styles existed:
  /// `StreamingDelivery.roughDraftTail` over the volatile tail *alone*. Folding
  /// the finalized text in would read better on both — the line stops blanking
  /// each time a segment finalizes — but the pill is the default style and its
  /// behavior is the baseline this change is not allowed to move. The bar takes
  /// the same string for the same reason it takes the same feed: one line, one
  /// definition of what that line is.
  var boundedTail: String? { StreamingDelivery.roughDraftTail(volatileTail) }

  /// The whole session as the prompter renders it: finalized, then the tail.
  var fullText: String { StreamingDelivery.joined(finalized, volatileTail) }

  /// Live word count over everything recognized so far, for the prompter header.
  var wordCount: Int { fullText.split(whereSeparator: \.isWhitespace).count }
}

extension HUDState {
  /// Seconds the HUD stays visible before auto-hiding, or nil to persist.
  /// Success lingers long enough to read the snippet; fatal errors outlast
  /// warnings so the user can act on them.
  var autoHideDelay: TimeInterval? {
    switch self {
    case .success: return 2.0
    case .warning: return 3.0
    case .error: return 6.0
    case .hidden, .listening, .processing: return nil
    }
  }

  /// Compute the HUD visual state from the current controller snapshot.
  ///
  /// Warning precedence:
  ///   1. `lastPolishWarning`
  ///   2. `lastSecureFieldNotice`
  ///   3. `lastProcessedText` → success snippet
  ///
  /// The controller fields stay set while idle; `DictationHUDController`
  /// marks the shown state consumed when its auto-hide fires so a later
  /// unrelated update cannot resurrect a stale notice.
  ///
  /// `isReviewing` outranks everything: while the review panel is open it is
  /// the session's feedback, and a pill hanging under it would be a second
  /// opinion about a session whose text has not been inserted at all.
  ///
  /// With one exception, and it is what `isReviewRecording` is for. A card
  /// being *extended* by a continuation (plan 14) is not a card waiting on its
  /// owner: the microphone is open again, and the live states — the level
  /// meter, and the rough draft the bar and prompter styles exist to show — are
  /// the only thing on screen that says so. The card shows a mic dot, not a
  /// transcript. The idle-derived states stay suppressed either way: a success
  /// snippet or a polish warning speaks for text that is still sitting in the
  /// card, uninserted. A `.failed` always shows — a review card has nowhere to
  /// put an error, and swallowing one is how a session goes missing.
  static func compute(
    controllerState: DictationState,
    isPolishInProgress: Bool,
    lastPolishWarning: String?,
    lastSecureFieldNotice: String?,
    lastProcessedText: String?,
    rmsLevel: Float,
    isReviewing: Bool = false,
    isReviewRecording: Bool = false
  ) -> HUDState {
    if isReviewing {
      switch controllerState {
      case .failed(let message):
        return .error(message: message)
      case .listening where isReviewRecording:
        return .listening(level: rmsLevel)
      case .finalizing where isReviewRecording:
        return .processing(step: isPolishInProgress ? "Polishing…" : "Transcribing…")
      default:
        return .hidden
      }
    }

    switch controllerState {
    case .disabled:
      return .hidden

    case .idle:
      // Warning precedence: polish warning > secure-field notice > processed text snippet
      if let warning = lastPolishWarning, !warning.isEmpty {
        return .warning(message: warning)
      }
      if let notice = lastSecureFieldNotice, !notice.isEmpty {
        return .warning(message: notice)
      }
      if let snippet = lastProcessedText, !snippet.isEmpty {
        return .success(snippet: snippet)
      }
      return .hidden

    case .listening:
      return .listening(level: rmsLevel)

    case .finalizing:
      if isPolishInProgress {
        return .processing(step: "Polishing…")
      }
      return .processing(step: "Transcribing…")

    case .injecting:
      return .processing(step: "Inserting…")

    case .failed(let message):
      return .error(message: message)
    }
  }
}
