import Foundation

// MARK: - HUDVisibilityMonitor

/// Failure detection and backoff for the HUD zombie state.
///
/// 2026-07-27 incident: the panel updated and resized normally, `show()` ran
/// `orderFrontRegardless()` without complaint, and nothing ever appeared on
/// screen. AppKit reported `windowNumber == 0` — the panel had no server-side
/// window at all — while WindowServer churned OcclusionDetection at ~115 Hz on
/// "Window 0x0". Only quitting and relaunching Nota fixed it. See
/// `macos-app-lifecycle-traps` §12.
///
/// The cause below AppKit is unknown and was not reproducible (n=1); this is
/// detection, one bounded heal, and telemetry. `windowNumber <= 0` right after
/// a show is the signal, and the only AppKit fact this type knows — everything
/// else is an injected closure, so the whole state machine is testable without
/// a WindowServer.
@MainActor
final class HUDVisibilityMonitor {
  /// What the controller should do about the panel it just tried to show.
  enum Action: Equatable {
    /// The panel has a window device. Nothing to do.
    case none
    /// First failure: throw the NSPanel away and build a fresh one. A dead
    /// server-side window cannot be revived — only replaced.
    case recreate
    /// A freshly created panel failed too. Log a fault and tell the user once;
    /// a third attempt would just be the second one again.
    case reportUnavailable
    /// Still failing, already reported this run. Stay quiet: the watchdog runs
    /// on a timer and would otherwise notify on a loop.
    case silent
  }

  /// How long after a show the watchdog re-checks. Covers the failure modes
  /// that pass the immediate check and only miss the screen a moment later.
  static let watchdogDelay: TimeInterval = 1.0

  private let windowNumberProvider: @MainActor () -> Int
  private var consecutiveFailures = 0
  private var didReport = false

  init(windowNumberProvider: @escaping @MainActor () -> Int) {
    self.windowNumberProvider = windowNumberProvider
  }

  /// AppKit's own answer to "does this panel have a window device": positive
  /// window numbers are real windows, zero and negatives are not.
  var hasWindowDevice: Bool { windowNumberProvider() > 0 }

  /// Judge the panel after a show attempt and decide what to do about it.
  ///
  /// Idempotent per outcome, not per call: repeated healthy calls stay `.none`,
  /// and the escalation only ever advances one step per failing call.
  func evaluate() -> Action {
    guard !hasWindowDevice else {
      consecutiveFailures = 0
      return .none
    }
    consecutiveFailures += 1
    guard consecutiveFailures > 1 else { return .recreate }
    guard !didReport else { return .silent }
    didReport = true
    return .reportUnavailable
  }

  /// The HUD was hidden on purpose. A panel with no window because nobody
  /// asked for one is not a failure, and the next session gets its own shot at
  /// the recreate path — the notification budget, deliberately, does not
  /// reset: "restart Nota" is worth saying once a run, not once a sentence.
  func reset() {
    consecutiveFailures = 0
  }
}
