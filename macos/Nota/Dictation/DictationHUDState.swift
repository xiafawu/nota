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
  // There is deliberately no `success` state (owner, 2026-10-30). The
  // "Inserted" card it drew did not match the glass the rest of the HUD is
  // made of, and it repeated what the text — already in the app — shows by
  // itself. A successful insert now simply fades the HUD out; warnings and
  // errors are unchanged.
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
  /// Fatal errors outlast warnings so the user can act on them.
  var autoHideDelay: TimeInterval? {
    switch self {
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
  ///
  /// A session that ended cleanly is `.hidden`: the text is in the app, and
  /// the HUD fading out is the whole report (no success card, owner
  /// 2026-10-30). `lastProcessedText` is deliberately not an input any more —
  /// a parameter nothing reads is the one the next reader would "fix".
  ///
  /// The controller fields stay set while idle; `DictationHUDController`
  /// marks the shown state consumed when its auto-hide fires so a later
  /// unrelated update cannot resurrect a stale notice.
  ///
  /// `isReviewing` outranks everything, and now without exception: while the
  /// review card is on screen it is the session's ONE surface, from the moment
  /// the hotkey goes down to the moment the owner applies or discards
  /// (owner call 2026-08-03 — "one pill only"). The card opens in a recording
  /// state at session start, so there is no longer a stretch of a review
  /// session during which the pill is the only thing showing the draft.
  ///
  /// `.failed` used to be the one exception, on the grounds that "a review card
  /// has nowhere to put an error". It has one now — `DictationReviewModel.errorMessage`,
  /// drawn in the card's status line — and the controller mirrors `state` into
  /// it. The two rules stay consistent because `isReviewing` is exactly "a card
  /// exists": when presenting a card fails, the controller clears
  /// `pendingReview`, `isReviewing` goes false, and the failure comes back out
  /// on the pill. The error always has somewhere to go, and never two.
  static func compute(
    controllerState: DictationState,
    isPolishInProgress: Bool,
    lastPolishWarning: String?,
    lastSecureFieldNotice: String?,
    rmsLevel: Float,
    isReviewing: Bool = false
  ) -> HUDState {
    if isReviewing { return .hidden }

    switch controllerState {
    case .disabled:
      return .hidden

    case .idle:
      // Warning precedence: polish warning > secure-field notice. A clean
      // finish shows nothing — the HUD just fades.
      if let warning = lastPolishWarning, !warning.isEmpty {
        return .warning(message: warning)
      }
      if let notice = lastSecureFieldNotice, !notice.isEmpty {
        return .warning(message: notice)
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

// MARK: - HUDAnnouncement

/// What VoiceOver is told as the HUD changes state.
///
/// The HUD's announcements are the only feedback a VoiceOver user gets that
/// dictation started, finished, or failed. "Dictation inserted" used to ride
/// on the `.success` card; the card is gone (owner, 2026-10-30), but the
/// announcement is not, because a sighted owner learns the insert happened by
/// seeing the text and a VoiceOver user does not. It now rides on the moment
/// the card used to appear: processing ending in a clean `.hidden` with text
/// delivered.
///
/// Pure, so every style — the pill, the bar, the prompter and the cursor mark —
/// announces the same three things from one table.
struct HUDAnnouncement: Equatable {
  let message: String
  /// High priority interrupts whatever VoiceOver is saying; a failure earns it.
  let isUrgent: Bool

  static func between(
    _ old: HUDState,
    _ new: HUDState,
    insertedText: String?
  ) -> HUDAnnouncement? {
    switch (old, new) {
    case (.listening, .listening), (.error, .error):
      return nil
    case (_, .listening):
      return HUDAnnouncement(message: "Dictation listening", isUrgent: false)
    case (.processing, .hidden):
      guard let insertedText, !insertedText.isEmpty else { return nil }
      return HUDAnnouncement(message: "Dictation inserted", isUrgent: false)
    case (_, .error(let message)):
      return HUDAnnouncement(message: "Dictation failed. \(message)", isUrgent: true)
    default:
      return nil
    }
  }
}
