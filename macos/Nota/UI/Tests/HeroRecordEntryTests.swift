import AppKit
import SwiftUI
import XCTest
@testable import Nota

/// The hero-as-record-entry gating rule (ADR 0004): the home hero starts a
/// live meeting when the preflight verdict allows it, and is inert while
/// `.blocked` or unknown. The pure rule is the testable contract; the button
/// wiring lives in the view and is verified at render time.
@MainActor
final class HeroRecordEntryTests: XCTestCase {
  func testGating_readyAndUnverifiedAllowRecording() {
    XCTAssertTrue(PreflightHomeView.canStartRecording(.ready))
    XCTAssertTrue(PreflightHomeView.canStartRecording(.unverified))
  }

  func testGating_blockedAndUnknownDoNotAllowRecording() {
    XCTAssertFalse(PreflightHomeView.canStartRecording(.blocked))
    XCTAssertFalse(PreflightHomeView.canStartRecording(nil))
  }
}
