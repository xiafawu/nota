import XCTest

@testable import Nota

/// The zombie-detection state machine, driven by a fake window number instead
/// of a WindowServer.
@MainActor
final class HUDVisibilityMonitorTests: XCTestCase {
  /// Stand-in for `NSPanel.windowNumber`: positive is a real window device,
  /// zero is the 2026-07-27 zombie state.
  private final class FakePanel {
    var windowNumber = 1
  }

  private func makeMonitor() -> (HUDVisibilityMonitor, FakePanel) {
    let panel = FakePanel()
    let monitor = HUDVisibilityMonitor { panel.windowNumber }
    return (monitor, panel)
  }

  // MARK: - Healthy

  func testHealthyPanelNeedsNoAction() {
    let (monitor, _) = makeMonitor()
    XCTAssertTrue(monitor.hasWindowDevice)
    XCTAssertEqual(monitor.evaluate(), .none)
    XCTAssertEqual(monitor.evaluate(), .none)
  }

  // MARK: - Escalation

  func testFirstFailureRecreates() {
    let (monitor, panel) = makeMonitor()
    panel.windowNumber = 0
    XCTAssertFalse(monitor.hasWindowDevice)
    XCTAssertEqual(monitor.evaluate(), .recreate)
  }

  func testNegativeWindowNumberIsAlsoAFailure() {
    let (monitor, panel) = makeMonitor()
    panel.windowNumber = -1
    XCTAssertEqual(monitor.evaluate(), .recreate)
  }

  func testSecondConsecutiveFailureReportsOnce() {
    let (monitor, panel) = makeMonitor()
    panel.windowNumber = 0
    XCTAssertEqual(monitor.evaluate(), .recreate)
    XCTAssertEqual(monitor.evaluate(), .reportUnavailable)
  }

  /// The watchdog keeps firing while the HUD is up; it must not turn into a
  /// notification loop.
  func testFurtherFailuresStaySilent() {
    let (monitor, panel) = makeMonitor()
    panel.windowNumber = 0
    XCTAssertEqual(monitor.evaluate(), .recreate)
    XCTAssertEqual(monitor.evaluate(), .reportUnavailable)
    XCTAssertEqual(monitor.evaluate(), .silent)
    XCTAssertEqual(monitor.evaluate(), .silent)
  }

  /// One `.recreate` per run of failures, never two: a heal that produced a
  /// working panel must not spend the run's escalation budget.
  func testRecoveryResetsTheEscalation() {
    let (monitor, panel) = makeMonitor()
    panel.windowNumber = 0
    XCTAssertEqual(monitor.evaluate(), .recreate)

    panel.windowNumber = 7
    XCTAssertEqual(monitor.evaluate(), .none)

    panel.windowNumber = 0
    XCTAssertEqual(monitor.evaluate(), .recreate)
  }

  // MARK: - Reset

  func testHidingClearsTheFailureRunButNotTheNotificationBudget() {
    let (monitor, panel) = makeMonitor()
    panel.windowNumber = 0
    XCTAssertEqual(monitor.evaluate(), .recreate)
    XCTAssertEqual(monitor.evaluate(), .reportUnavailable)

    // A deliberate hide is not a failure.
    monitor.reset()

    // The next session may still recreate…
    XCTAssertEqual(monitor.evaluate(), .recreate)
    // …but the user is told "restart Nota" only once a run.
    XCTAssertEqual(monitor.evaluate(), .silent)
  }

  func testResetWhileHealthyChangesNothing() {
    let (monitor, _) = makeMonitor()
    XCTAssertEqual(monitor.evaluate(), .none)
    monitor.reset()
    XCTAssertEqual(monitor.evaluate(), .none)
  }

  // MARK: - Watchdog policy

  func testWatchdogDelayIsAboutASecond() {
    XCTAssertEqual(HUDVisibilityMonitor.watchdogDelay, 1.0, accuracy: 0.001)
  }
}
