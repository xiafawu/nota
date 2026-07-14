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

  // MARK: - P2 tests

  func testHypothesisEquality() {
    let a = Hypothesis(text: "hello", isFinal: false)
    let b = Hypothesis(text: "hello", isFinal: false)
    let c = Hypothesis(text: "hello world", isFinal: true)
    XCTAssertEqual(a, b)
    XCTAssertNotEqual(a, c)
    XCTAssertFalse(a.isFinal)
    XCTAssertTrue(c.isFinal)
  }

  func testP2StateTransitions() {
    // P2 adds .finalizing and .injecting states
    XCTAssertEqual(DictationState.finalizing.statusTitle, "Stopping")
    XCTAssertEqual(DictationState.injecting.statusTitle, "Injecting")

    // .finalizing and .injecting should have blue tint
    let finalizingSymbol = DictationState.finalizing.symbolName
    let injectingSymbol = DictationState.injecting.symbolName
    XCTAssertFalse(finalizingSymbol.isEmpty)
    XCTAssertFalse(injectingSymbol.isEmpty)
  }

  func testAppleSpeechErrorDescriptions() {
    XCTAssertFalse(AppleSpeechError.unavailable.errorDescription?.isEmpty ?? true)
    XCTAssertFalse(AppleSpeechError.notAuthorized.errorDescription?.isEmpty ?? true)
    XCTAssertNotEqual(
      AppleSpeechError.unavailable.errorDescription,
      AppleSpeechError.notAuthorized.errorDescription
    )
  }

  func testSpeechStreamProtocolShape() {
    // Compile-time check that AppleSpeechStream conforms
    let _: any SpeechStream = AppleSpeechStream()
   }
}
