import AppKit
import XCTest

@testable import Nota

final class AppLifecycleTests: XCTestCase {
  func testDockReopenRequestsSwiftUIMainWindowWhenWindowGroupHasNoWindow() {
    let request = expectation(description: "main window reopen request")
    let observer = NotificationCenter.default.addObserver(
      forName: .notaReopenMainWindow,
      object: nil,
      queue: .main
    ) { _ in
      request.fulfill()
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    let appDelegate = AppDelegate()
    XCTAssertFalse(
      appDelegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
    )
    wait(for: [request], timeout: 1)
  }
}
