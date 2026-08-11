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

  /// A **re-fork guard**, and nothing more than that — which is a correction to
  /// how it was presented. `LiveMeetingFormat.duration` *is* one line calling
  /// `SessionTimerMetrics.text`, so comparing the two is comparing a delegation
  /// against its own callee: it can only fail if someone re-implements the
  /// body, which is exactly the day it should fail. It is not evidence that two
  /// clocks agree, because there are not two clocks.
  ///
  /// So the values are pinned against literals as well. That half fails if both
  /// sides drift together, which the comparison alone never could.
  func testDuration_stillDelegatesAndStillReadsTheSame() {
    for elapsed in [TimeInterval(0), 0.9, 59, 60, 3599, 3600, 3661, 36_000, 86_399] {
      XCTAssertEqual(
        LiveMeetingFormat.duration(elapsed),
        SessionTimerMetrics.text(elapsed: elapsed),
        "the pane's clock was re-implemented instead of delegating, at \(elapsed)"
      )
    }
    XCTAssertEqual(LiveMeetingFormat.duration(0), "00:00")
    XCTAssertEqual(LiveMeetingFormat.duration(59), "00:59")
    XCTAssertEqual(LiveMeetingFormat.duration(3599), "59:59")
    XCTAssertEqual(LiveMeetingFormat.duration(3600), "1:00:00")
    XCTAssertEqual(LiveMeetingFormat.duration(86_399), "23:59:59")
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

  // MARK: - Which states wear the two-column pane (XIA-432)

  /// The session column is the indicator that a session is *flowing*. A failed
  /// session is not flowing, so it does not get one — a breathing ring and a
  /// live meter over a dead microphone would be the exact lie the meter exists
  /// to make impossible. What that state needs is the transcript it heard and
  /// one decision about it, which is the banner.
  func testOnlyALiveSessionWearsTheRecordingPane() {
    XCTAssertTrue(LiveMeetingControls.stop.showsRecordingPane)
    XCTAssertTrue(LiveMeetingControls.finalizing.showsRecordingPane)
    XCTAssertFalse(LiveMeetingControls.start.showsRecordingPane)
    XCTAssertFalse(LiveMeetingControls.starting.showsRecordingPane)
    XCTAssertFalse(LiveMeetingControls.saveOrDiscard.showsRecordingPane)
    XCTAssertFalse(LiveMeetingControls.retryOrDiscard.showsRecordingPane)
  }
}
