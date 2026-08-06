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

  // MARK: - The starting window (XIA-430)

  /// The session is `.idle` for the whole of the mic prompt and the realtime
  /// open + Begin round trip. Saying "Ready" through those seconds told the
  /// user their press had not registered — and the second press is what lost a
  /// meeting's transcript.
  func testStateLabel_startingOverridesIdle() {
    XCTAssertEqual(LiveMeetingFormat.stateLabel(.idle, isStarting: true), "Starting…")
    XCTAssertEqual(LiveMeetingFormat.stateLabel(.idle, isStarting: false), "Ready")
  }

  /// A live session's own state always wins: a stale starting flag may not
  /// relabel a session that is already recording.
  func testStateLabel_startingNeverOverridesALiveSession() {
    XCTAssertEqual(LiveMeetingFormat.stateLabel(.recording, isStarting: true), "Recording")
    XCTAssertEqual(LiveMeetingFormat.stateLabel(.stopping, isStarting: true), "Finalizing…")
  }

  // MARK: - LiveMeetingControls

  func testControls_idleOffersStartUntilAPressIsAccepted() {
    XCTAssertEqual(
      LiveMeetingControls.make(state: .idle, isStarting: false, hasTranscript: false),
      .start
    )
    XCTAssertEqual(
      LiveMeetingControls.make(state: .idle, isStarting: true, hasTranscript: false),
      .starting,
      "the Start button is withdrawn the moment a press is accepted"
    )
  }

  func testControls_recordingAndStopping() {
    XCTAssertEqual(
      LiveMeetingControls.make(state: .recording, isStarting: false, hasTranscript: true),
      .stop
    )
    XCTAssertEqual(
      LiveMeetingControls.make(state: .stopping, isStarting: false, hasTranscript: true),
      .finalizing
    )
  }

  /// The dead end this closes: a session that dropped ten minutes in showed an
  /// error banner with no route to the seal at all, so the transcript it had
  /// already heard could not be saved and the record stayed `recording`.
  func testControls_aFailedSessionWithATranscriptCanStillSaveIt() {
    XCTAssertEqual(
      LiveMeetingControls.make(state: .failed("socket closed"), isStarting: false, hasTranscript: true),
      .saveOrDiscard
    )
  }

  func testControls_aFailedSessionWithNothingHeardOffersNoSave() {
    XCTAssertEqual(
      LiveMeetingControls.make(state: .failed("mic permission denied"), isStarting: false, hasTranscript: false),
      .retryOrDiscard
    )
  }
}
