import XCTest

@testable import Nota

/// **A second alert waits; it does not replace the first** (FB-1).
///
/// The window mounts one alert and used to hold one value, so a report raised
/// while another was up overwrote it — the owner read the second and never the
/// first. `OwnerAlertQueue` is the order they are shown in.
final class OwnerAlertQueueTests: XCTestCase {
  private let deleteFailed = OwnerAlert(title: "Delete failed", message: "Still on disk.")
  private let refused = OwnerAlert(title: "Cannot open", message: "Not a supported file.")
  private let discardFailed = OwnerAlert(title: "Discard failed", message: "Kept.")

  func testAlertsRaisedWhileOneIsUpAreShownInTheOrderTheyWereRaised() {
    var queue = OwnerAlertQueue()
    XCTAssertEqual(queue.raise(deleteFailed), deleteFailed, "nothing was up, so it goes up now")
    XCTAssertNil(queue.raise(refused), "a second alert replaced the one on screen")
    XCTAssertNil(queue.raise(discardFailed))
    XCTAssertEqual(queue.current, deleteFailed)
    XCTAssertEqual(queue.waiting, [refused, discardFailed])

    // Each dismissal promotes the next, which the model raises again after its hop.
    XCTAssertEqual(queue.dismissCurrent(), refused)
    XCTAssertEqual(queue.raise(refused), refused, "the promoted alert was not let back on screen")
    XCTAssertEqual(queue.dismissCurrent(), discardFailed)
    XCTAssertEqual(queue.raise(discardFailed), discardFailed)
    XCTAssertNil(queue.dismissCurrent(), "nothing was waiting")
    XCTAssertNil(queue.current)
    XCTAssertEqual(queue.raise(deleteFailed), deleteFailed, "an empty queue shows at once again")
  }

  /// The promotion is immediate and the presentation is a hop later, so a
  /// report raised in that gap must queue behind the promoted alert, not jump it.
  func testAReportRaisedDuringTheHandOffQueuesBehindThePromotedAlert() {
    var queue = OwnerAlertQueue()
    _ = queue.raise(deleteFailed)
    _ = queue.raise(refused)
    XCTAssertEqual(queue.dismissCurrent(), refused)

    XCTAssertNil(queue.raise(discardFailed), "a later report jumped the alert already promoted")
    XCTAssertEqual(queue.raise(refused), refused)
    XCTAssertEqual(queue.waiting, [discardFailed])
  }

  /// One action can reach the model twice; saying the same thing twice is noise.
  func testARepeatOfAnAlertUpOrWaitingIsDropped() {
    var queue = OwnerAlertQueue()
    _ = queue.raise(deleteFailed)
    _ = queue.raise(refused)
    XCTAssertNil(queue.raise(deleteFailed), "a repeat of the alert on screen")
    XCTAssertNil(queue.raise(refused), "a repeat of a waiting alert")
    XCTAssertEqual(queue.waiting, [refused])
  }

  /// A dismissal with nothing up is ignored, so it cannot skip an alert that
  /// has been promoted and is on its way to the screen.
  func testADismissalWithNothingUpSkipsNothing() {
    var empty = OwnerAlertQueue()
    XCTAssertNil(empty.dismissCurrent())
    XCTAssertEqual(empty, OwnerAlertQueue())

    var queue = OwnerAlertQueue()
    _ = queue.raise(deleteFailed)
    _ = queue.raise(refused)
    _ = queue.raise(discardFailed)
    XCTAssertEqual(queue.dismissCurrent(), refused)
    XCTAssertNil(queue.dismissCurrent(), "a second dismissal skipped the promoted alert")
    XCTAssertEqual(queue.current, refused)
    XCTAssertEqual(queue.waiting, [discardFailed])
  }

  /// The queue is only worth what the window does with it: the model raises
  /// through it, a dismissal hands the turn on, and `ContentView`'s binding
  /// is what reports the dismissal. Read from the source, because `NotaModel`
  /// cannot be built in a test.
  func testTheWindowsAlertIsDrivenThroughTheQueue() throws {
    let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let ui = tests.deletingLastPathComponent()
    let model = try String(
      contentsOf: ui.deletingLastPathComponent().appendingPathComponent("App/NotaModel.swift"),
      encoding: .utf8)
    let contentView = try String(
      contentsOf: ui.appendingPathComponent("ContentView.swift"), encoding: .utf8)

    XCTAssertTrue(model.contains("guard let alert = self?.ownerAlerts.raise(alert) else { return }"))
    XCTAssertTrue(model.contains("guard let next = ownerAlerts.dismissCurrent() else { return }"))
    XCTAssertTrue(
      contentView.contains("model.ownerAlertDismissed()"),
      "dismissing the alert no longer hands the turn to the next one")
  }
}
