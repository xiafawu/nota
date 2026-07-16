import XCTest

@testable import Nota

final class HUDStateTests: XCTestCase {
  // MARK: - Hidden

  func testHiddenWhenDisabled() {
    XCTAssertEqual(
      HUDState.compute(
        controllerState: .disabled(reason: "No permission"),
        isPolishInProgress: false,
        lastPolishWarning: nil,
        lastSecureFieldNotice: nil,
        lastProcessedText: nil,
        rmsLevel: 0
      ),
      .hidden
    )
  }

  func testHiddenWhenIdleWithoutOutput() {
    XCTAssertEqual(
      HUDState.compute(
        controllerState: .idle,
        isPolishInProgress: false,
        lastPolishWarning: nil,
        lastSecureFieldNotice: nil,
        lastProcessedText: nil,
        rmsLevel: 0
      ),
      .hidden
    )
  }

  func testHiddenWhenIdleWithEmptySnippet() {
    XCTAssertEqual(
      HUDState.compute(
        controllerState: .idle,
        isPolishInProgress: false,
        lastPolishWarning: nil,
        lastSecureFieldNotice: nil,
        lastProcessedText: "",
        rmsLevel: 0
      ),
      .hidden
    )
  }

  // MARK: - Listening

  func testListeningReturnsListeningWithLevel() {
    XCTAssertEqual(
      HUDState.compute(
        controllerState: .listening,
        isPolishInProgress: false,
        lastPolishWarning: nil,
        lastSecureFieldNotice: nil,
        lastProcessedText: nil,
        rmsLevel: 0.5
      ),
      .listening(level: 0.5)
    )
  }

  func testListeningZeroLevel() {
    XCTAssertEqual(
      HUDState.compute(
        controllerState: .listening,
        isPolishInProgress: false,
        lastPolishWarning: nil,
        lastSecureFieldNotice: nil,
        lastProcessedText: nil,
        rmsLevel: 0
      ),
      .listening(level: 0)
    )
  }

  // MARK: - Processing

  func testProcessingTranscribingDuringFinalizing() {
    XCTAssertEqual(
      HUDState.compute(
        controllerState: .finalizing,
        isPolishInProgress: false,
        lastPolishWarning: nil,
        lastSecureFieldNotice: nil,
        lastProcessedText: nil,
        rmsLevel: 0
      ),
      .processing(step: "Transcribing…")
    )
  }

  func testProcessingPolishingDuringFinalizingWithPolish() {
    XCTAssertEqual(
      HUDState.compute(
        controllerState: .finalizing,
        isPolishInProgress: true,
        lastPolishWarning: nil,
        lastSecureFieldNotice: nil,
        lastProcessedText: nil,
        rmsLevel: 0
      ),
      .processing(step: "Polishing…")
    )
  }

  func testProcessingInjecting() {
    XCTAssertEqual(
      HUDState.compute(
        controllerState: .injecting,
        isPolishInProgress: false,
        lastPolishWarning: nil,
        lastSecureFieldNotice: nil,
        lastProcessedText: nil,
        rmsLevel: 0
      ),
      .processing(step: "Injecting…")
    )
  }

  // MARK: - Success

  func testSuccessWhenIdleWithProcessedText() {
    XCTAssertEqual(
      HUDState.compute(
        controllerState: .idle,
        isPolishInProgress: false,
        lastPolishWarning: nil,
        lastSecureFieldNotice: nil,
        lastProcessedText: "Hello world",
        rmsLevel: 0
      ),
      .success(snippet: "Hello world")
    )
  }

  // MARK: - Warning precedence

  func testPolishWarningTakesPrecedenceOverSecureFieldNotice() {
    XCTAssertEqual(
      HUDState.compute(
        controllerState: .idle,
        isPolishInProgress: false,
        lastPolishWarning: "Polish failed. Using rules-only result.",
        lastSecureFieldNotice: "Refused secure field",
        lastProcessedText: "Hello",
        rmsLevel: 0
      ),
      .warning(message: "Polish failed. Using rules-only result.")
    )
  }

  func testSecureFieldNoticeTakesPrecedenceOverProcessedText() {
    XCTAssertEqual(
      HUDState.compute(
        controllerState: .idle,
        isPolishInProgress: false,
        lastPolishWarning: nil,
        lastSecureFieldNotice: "Refused secure field",
        lastProcessedText: "Hello",
        rmsLevel: 0
      ),
      .warning(message: "Refused secure field")
    )
  }

  // MARK: - Error

  func testErrorWhenFailed() {
    XCTAssertEqual(
      HUDState.compute(
        controllerState: .failed(message: "Microphone unavailable"),
        isPolishInProgress: false,
        lastPolishWarning: nil,
        lastSecureFieldNotice: nil,
        lastProcessedText: nil,
        rmsLevel: 0
      ),
      .error(message: "Microphone unavailable")
    )
  }

  func testErrorMessageNotEmpty() {
    let state = HUDState.compute(
      controllerState: .failed(message: "Something broke"),
      isPolishInProgress: false,
      lastPolishWarning: nil,
      lastSecureFieldNotice: nil,
      lastProcessedText: nil,
      rmsLevel: 0
    )
    guard case .error(let msg) = state else {
      return XCTFail("expected .error")
    }
    XCTAssertFalse(msg.isEmpty)
  }

  // MARK: - Equatable conformance

  func testListeningLevelEquality() {
    let a = HUDState.listening(level: 0.3)
    let b = HUDState.listening(level: 0.3)
    let c = HUDState.listening(level: 0.5)
    XCTAssertEqual(a, b)
    XCTAssertNotEqual(a, c)
  }

  func testProcessingStepEquality() {
    XCTAssertEqual(
      HUDState.processing(step: "Transcribing…"),
      HUDState.processing(step: "Transcribing…")
    )
    XCTAssertNotEqual(
      HUDState.processing(step: "Transcribing…"),
      HUDState.processing(step: "Polishing…")
    )
  }

  func testSuccessSnippetEquality() {
    XCTAssertEqual(
      HUDState.success(snippet: "hi"),
      HUDState.success(snippet: "hi")
    )
    XCTAssertNotEqual(
      HUDState.success(snippet: "hi"),
      HUDState.success(snippet: "bye")
    )
  }
}
