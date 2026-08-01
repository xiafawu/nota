import XCTest
@testable import Nota

final class LiveMeetingViewTests: XCTestCase {
  // MARK: - LiveMeetingFormat.duration

  func testDuration_zero() {
    XCTAssertEqual(LiveMeetingFormat.duration(0), "00:00")
  }

  func testDuration_subSecondTruncates() {
    XCTAssertEqual(LiveMeetingFormat.duration(0.9), "00:00")
  }

  func testDuration_seconds() {
    XCTAssertEqual(LiveMeetingFormat.duration(59), "00:59")
  }

  func testDuration_minuteBoundary() {
    XCTAssertEqual(LiveMeetingFormat.duration(60), "01:00")
  }

  func testDuration_underAnHour() {
    XCTAssertEqual(LiveMeetingFormat.duration(3599), "59:59")
  }

  func testDuration_hourBoundary() {
    XCTAssertEqual(LiveMeetingFormat.duration(3600), "1:00:00")
  }

  func testDuration_overAnHour() {
    XCTAssertEqual(LiveMeetingFormat.duration(3661), "1:01:01")
  }

  func testDuration_hourWithLeadingMinutes() {
    XCTAssertEqual(LiveMeetingFormat.duration(3600 + 12 * 60 + 5), "1:12:05")
  }

  func testDuration_fractionalHourTruncates() {
    XCTAssertEqual(LiveMeetingFormat.duration(3600.99), "1:00:00")
  }

  func testDuration_negativeClampsToZero() {
    XCTAssertEqual(LiveMeetingFormat.duration(-5), "00:00")
  }

  // MARK: - LiveMeetingFormat.stateLabel

  func testStateLabel_idle() {
    XCTAssertEqual(LiveMeetingFormat.stateLabel(.idle), "Ready")
  }

  func testStateLabel_recording() {
    XCTAssertEqual(LiveMeetingFormat.stateLabel(.recording), "Recording")
  }

  func testStateLabel_stopping() {
    XCTAssertEqual(LiveMeetingFormat.stateLabel(.stopping), "Finalizing…")
  }

  /// The failed label is generic; the per-run message lives on the banner.
  func testStateLabel_failedIgnoresMessage() {
    XCTAssertEqual(LiveMeetingFormat.stateLabel(.failed("mic permission denied")), "Recording failed")
  }

  // MARK: - SessionState equality

  func testSessionState_failedDistinguishesMessages() {
    XCTAssertNotEqual(
      LiveMeetingSession.SessionState.failed("network error"),
      LiveMeetingSession.SessionState.failed("mic permission denied")
    )
  }

  func testSessionState_recordingMatchesItself() {
    XCTAssertEqual(LiveMeetingSession.SessionState.recording, .recording)
  }
}
