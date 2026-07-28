import CoreGraphics
import Foundation

// MARK: - ModifierClearance

/// Waits for the modifier keys the owner is physically holding to come back up
/// before Nota posts synthetic keystrokes.
///
/// The bug this exists for (2026-07-28): with the review card open, ⌘↩ took the
/// card down and inserted nothing, while clicking Apply inserted fine. The two
/// routes run identical code — the key monitor and the button both end in
/// `finish(.apply(model.text))` → `finishReview` → `injectReviewed` — so the
/// difference was never in the code. It was in the keyboard: on the shortcut
/// route the owner's ⌘ is still down when injection runs 80 ms later.
///
/// A `CGEvent` built from a `CGEventSource` inherits that source's current
/// modifier state, and `.combinedSessionState` includes the physical keyboard.
/// So `TextInjector.tryCGEventInject` — which posts one keyboard event carrying
/// the text as a Unicode payload — was posting it tagged `⌘`. An app receiving
/// a ⌘-tagged key-down routes it to key-equivalent/menu dispatch and never
/// inserts the payload: the text is dropped silently while `lastProcessedText`
/// claims a success. That path is not the exotic one — every terminal in
/// `TextInjector.defaultOverrideTable` is forced onto `.keyEvents`, and the AX
/// strategy (the one strategy modifiers cannot affect) is exactly the one those
/// apps skip.
///
/// Two defences, because either alone leaves a hole. `TextInjector` now assigns
/// `flags = []` to the events it builds, so a keystroke carrying text is never
/// a shortcut whatever the keyboard is doing. And injection waits here first,
/// because a real ⌘ that is still down also reaches the target as its own
/// `flagsChanged` — the app's own idea of the modifier state, which no flag we
/// set on our event can correct.
///
/// Bounded on purpose: a stuck or genuinely-held modifier must delay the text,
/// never swallow it. At the cap the injection goes ahead anyway.
enum ModifierClearance {
  /// What a wait ended in. `afterNs` is the time actually spent sleeping, which
  /// is what makes the bound testable without a clock.
  enum Outcome: Equatable {
    /// Nothing was held — the Apply *button*'s case, and the common one.
    case alreadyClear
    case cleared(afterNs: UInt64)
    /// Still held at the cap. Injection proceeds regardless.
    case timedOut(afterNs: UInt64)
  }

  /// Modifiers that change how a posted keystroke is interpreted by the target.
  ///
  /// Shift is deliberately absent: it alters the character an app derives from
  /// a *virtual key*, and Nota posts a Unicode payload rather than a key. ⌘, ⌃
  /// and ⌥ are the three that turn a keystroke into a command.
  static let blocking: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]

  static let pollIntervalNs: UInt64 = 10_000_000 // 10 ms
  /// Half a second: longer than any ⌘↩ press, short enough that a stuck
  /// modifier costs a perceptible pause and not a lost session.
  static let timeoutNs: UInt64 = 500_000_000

  /// Whether `flags` still carries a modifier that would re-tag a keystroke.
  static func isBlocked(_ flags: CGEventFlags) -> Bool {
    !flags.intersection(blocking).isEmpty
  }

  /// The modifier state of the real keyboard, HID and session combined — the
  /// same state a `CGEvent` built from `.combinedSessionState` inherits.
  static func currentFlags() -> CGEventFlags {
    CGEventSource.flagsState(.combinedSessionState)
  }

  /// Poll until nothing blocking is held, or until `timeoutNs` of sleeping has
  /// elapsed.
  ///
  /// `flags` and `sleep` are injected so the loop is pinned by unit test: a
  /// modifier that clears on the third poll, and one that never clears, are
  /// both exercised without a keyboard and without spending real time.
  static func wait(
    timeoutNs: UInt64 = timeoutNs,
    pollIntervalNs: UInt64 = pollIntervalNs,
    flags: () -> CGEventFlags = currentFlags,
    sleep: (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
  ) async -> Outcome {
    guard isBlocked(flags()) else { return .alreadyClear }
    // A zero interval would spin forever against a stuck modifier; one
    // nanosecond still terminates in `timeoutNs / 1` steps.
    let step = max(pollIntervalNs, 1)
    var waited: UInt64 = 0
    while waited < timeoutNs {
      let slice = min(step, timeoutNs - waited)
      await sleep(slice)
      waited += slice
      if !isBlocked(flags()) { return .cleared(afterNs: waited) }
    }
    return .timedOut(afterNs: waited)
  }
}
