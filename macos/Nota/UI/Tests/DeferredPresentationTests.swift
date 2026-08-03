import SwiftUI
import XCTest
@testable import Nota

/// The health popover is anchored in a toolbar item, so raising its flag inside
/// the caller's update presents an `NSPopover` during `NSHostingView.layout` —
/// a child window ordered mid-display-cycle, which AppKit turns into a fatal
/// ObjC exception. These pin the one rule that prevents it: the flag is never
/// set synchronously with the request.
@MainActor
final class DeferredPresentationTests: XCTestCase {
  /// Box + binding standing in for the `@State` ContentView owns.
  private final class Flag {
    var value = false
    var binding: Binding<Bool> {
      Binding(get: { self.value }, set: { self.value = $0 })
    }
  }

  func testOpenDoesNotSetTheFlagSynchronously() {
    let flag = Flag()
    var scheduled: [@MainActor () -> Void] = []

    DeferredPresentation.open(flag.binding, using: { scheduled.append($0) })

    XCTAssertFalse(flag.value, "the flag must not move inside the caller's pass")
    XCTAssertEqual(scheduled.count, 1)
  }

  func testScheduledWorkRaisesTheFlag() {
    let flag = Flag()
    var scheduled: [@MainActor () -> Void] = []

    DeferredPresentation.open(flag.binding, using: { scheduled.append($0) })
    scheduled.forEach { $0() }

    XCTAssertTrue(flag.value)
  }

  func testAlreadyPresentedSchedulesNothing() {
    let flag = Flag()
    flag.value = true
    var scheduled: [@MainActor () -> Void] = []

    DeferredPresentation.open(flag.binding, using: { scheduled.append($0) })

    XCTAssertTrue(scheduled.isEmpty, "an open popover must not queue a re-present")
  }

  /// Two requests in one pass (a gated card click that also re-lays the
  /// toolbar) cost exactly one write: the second sees the popover already open
  /// on its turn and drops. A redundant `true` is another SwiftUI transaction
  /// against the view whose layout started all this.
  func testASecondRequestInTheSameBurstWritesNothing() {
    let flag = Flag()
    var scheduled: [@MainActor () -> Void] = []
    var writes = 0
    let counting = Binding<Bool>(
      get: { flag.value },
      set: { writes += 1; flag.value = $0 }
    )

    DeferredPresentation.open(counting, using: { scheduled.append($0) })
    DeferredPresentation.open(counting, using: { scheduled.append($0) })
    XCTAssertEqual(scheduled.count, 2, "both requests were made before either ran")

    scheduled.forEach { $0() }

    XCTAssertTrue(flag.value)
    XCTAssertEqual(writes, 1, "one burst of requests is one presentation write")
  }

  /// The production scheduler really defers — it does not run inline.
  func testDefaultSchedulerRunsOnALaterRunLoopTurn() {
    let flag = Flag()
    let raised = expectation(description: "flag raised")

    DeferredPresentation.open(flag.binding)
    XCTAssertFalse(flag.value, "the default scheduler must not run inline")

    DispatchQueue.main.async { raised.fulfill() }
    wait(for: [raised], timeout: 1)
    XCTAssertTrue(flag.value)
  }
}
