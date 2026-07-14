import XCTest
@testable import Nota

final class DictationStateTests: XCTestCase {
  func testStatusLabelsDistinguishP1States() {
    XCTAssertEqual(DictationState.idle.statusTitle, "Idle")
    XCTAssertEqual(DictationState.listening.statusTitle, "Listening")
    XCTAssertEqual(
      DictationState.disabled(reason: "Microphone permission is missing.").statusTitle,
      "Permission Required"
    )
  }

  func testPermissionGateOnlyPassesWhenEveryPermissionIsGranted() {
    XCTAssertFalse(
      DictationPermissionGate.isReady(
        accessibility: .granted,
        inputMonitoring: .granted,
        microphone: .denied
      )
    )
    XCTAssertTrue(
      DictationPermissionGate.isReady(
        accessibility: .granted,
        inputMonitoring: .granted,
        microphone: .granted
      )
    )
  }

  func testCaptureDiagnosticsReportsCompletedDuration() {
    let start = Date(timeIntervalSince1970: 100)
    var diagnostics = CaptureDiagnostics(
      sessionID: UUID(),
      startedAt: start,
      stoppedAt: nil,
      bufferCount: 2,
      sampleCount: 3_200,
      lastBufferAt: start.addingTimeInterval(0.1)
    )

    XCTAssertNil(diagnostics.duration)
    diagnostics.stoppedAt = start.addingTimeInterval(0.25)
    guard let duration = diagnostics.duration else {
      XCTFail("A stopped capture should report a duration.")
      return
    }
    XCTAssertEqual(duration, 0.25, accuracy: 0.0001)
  }
}
