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

  /// The one bounded line the bar shows.
  ///
  /// The bar is a single static line by design; the pill outgrew this when
  /// the growing draft landed (finalized lines, then the volatile tail), so
  /// the bounded tail is now the bar's feed alone.
  var boundedTail: String? { StreamingDelivery.roughDraftTail(volatileTail) }

  /// The whole session as the prompter renders it: finalized, then the tail.
  var fullText: String { StreamingDelivery.joined(finalized, volatileTail) }

  /// The whole session as the growing pill renders it: every finalized line,
  /// then the in-flight tail on its own line. The pill widens once and then
  /// only ever grows taller, so nothing the user has said ever leaves the
  /// block while they keep talking.
  var growingText: String {
    guard !finalized.isEmpty else { return volatileTail }
    return volatileTail.isEmpty ? finalized : finalized + "\n" + volatileTail
  }

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
  /// That includes a continuation recording into the card (changed 2026-08-03
  /// on owner feedback — the earlier rule re-admitted the live states, and the
  /// owner saw it as two HUDs narrating one session). The card's header
  /// already carries the mic dot and "Listening…" while a continuation
  /// records (`DictationReviewModel.isListening`), so the open microphone is
  /// still announced — by the one surface the session owns. A `.failed`
  /// always shows: a review card has nowhere to put an error, and swallowing
  /// one is how a session goes missing.
  static func compute(
    controllerState: DictationState,
    isPolishInProgress: Bool,
    lastPolishWarning: String?,
    lastSecureFieldNotice: String?,
    lastProcessedText: String?,
    rmsLevel: Float,
    isReviewing: Bool = false
  ) -> HUDState {
    if isReviewing {
      switch controllerState {
      case .failed(let message):
        return .error(message: message)
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
