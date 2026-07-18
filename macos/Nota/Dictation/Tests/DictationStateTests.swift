import AppKit
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
    // P2 adds .finalizing and .injecting states; titles are user-facing
    // progress wording, not pipeline jargon.
    XCTAssertEqual(DictationState.finalizing.statusTitle, "Working…")
    XCTAssertEqual(DictationState.injecting.statusTitle, "Inserting…")
    XCTAssertEqual(
      DictationState.failed(message: "Speech engine unavailable.").statusTitle,
      "Failed — Try Again"
    )

    // Transient states use progress-flavored symbols that resolve in SF Symbols.
    XCTAssertEqual(DictationState.finalizing.symbolName, "ellipsis.circle")
    XCTAssertEqual(DictationState.injecting.symbolName, "text.insert")
    XCTAssertNotNil(
      NSImage(systemSymbolName: DictationState.finalizing.symbolName, accessibilityDescription: nil)
    )
    XCTAssertNotNil(
      NSImage(systemSymbolName: DictationState.injecting.symbolName, accessibilityDescription: nil)
    )
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
