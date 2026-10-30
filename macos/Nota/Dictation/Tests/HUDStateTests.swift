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
        rmsLevel: 0
      ),
      .processing(step: "Inserting…")
    )
  }

  // MARK: - No success card

  /// The "Inserted" card is gone from every style (owner, 2026-10-30): it did
  /// not match the glass, and it repeated what the text already in the app
  /// shows. A clean finish is `.hidden` — the HUD simply fades — whatever the
  /// session inserted. `compute` no longer even takes the inserted text, so
  /// there is nothing a later edit could hang a snippet off.
  func testACleanFinishIsHiddenNotASuccessCard() {
    XCTAssertEqual(
      HUDState.compute(
        controllerState: .idle,
        isPolishInProgress: false,
        lastPolishWarning: nil,
        lastSecureFieldNotice: nil,
        rmsLevel: 0
      ),
      .hidden
    )
  }

  /// The VoiceOver half of the card survives: a sighted owner learns the
  /// insert landed by seeing the text, a VoiceOver user by being told.
  func testTheInsertIsStillAnnouncedWhenProcessingFadesOut() {
    XCTAssertEqual(
      HUDAnnouncement.between(
        .processing(step: "Inserting…"), .hidden, insertedText: "Hello world"
      ),
      HUDAnnouncement(message: "Dictation inserted", isUrgent: false)
    )
    XCTAssertNil(
      HUDAnnouncement.between(.processing(step: "Transcribing…"), .hidden, insertedText: ""),
      "nothing was inserted, so nothing is announced"
    )
    XCTAssertNil(
      HUDAnnouncement.between(.hidden, .hidden, insertedText: "Hello world"),
      "an idle tick is not an insert"
    )
  }

  func testListeningAndFailureAnnouncementsAreUnchanged() {
    XCTAssertEqual(
      HUDAnnouncement.between(.hidden, .listening(level: 0.2), insertedText: nil)?.message,
      "Dictation listening"
    )
    XCTAssertNil(
      HUDAnnouncement.between(.listening(level: 0.1), .listening(level: 0.4), insertedText: nil)
    )
    XCTAssertEqual(
      HUDAnnouncement.between(.processing(step: "x"), .error(message: "boom"), insertedText: nil),
      HUDAnnouncement(message: "Dictation failed. boom", isUrgent: true)
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
      rmsLevel: 0
    )
    guard case .error(let msg) = state else {
      return XCTFail("expected .error")
    }
    XCTAssertFalse(msg.isEmpty)
  }

  // MARK: - Auto-hide policy

  func testWarningAutoHidesAfterThreeSeconds() {
    XCTAssertEqual(HUDState.warning(message: "Polish failed").autoHideDelay, 3.0)
  }

  func testErrorPersistsLongerThanWarning() throws {
    let error = HUDState.error(message: "Microphone unavailable").autoHideDelay
    let warning = HUDState.warning(message: "Polish failed").autoHideDelay
    XCTAssertEqual(error, 6.0)
    XCTAssertGreaterThan(try XCTUnwrap(error), try XCTUnwrap(warning))
  }

  func testListeningAndProcessingNeverAutoHide() {
    XCTAssertNil(HUDState.listening(level: 0.4).autoHideDelay)
    XCTAssertNil(HUDState.processing(step: "Transcribing…").autoHideDelay)
    XCTAssertNil(HUDState.hidden.autoHideDelay)
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

  func testWarningMessageEquality() {
    XCTAssertEqual(HUDState.warning(message: "hi"), HUDState.warning(message: "hi"))
    XCTAssertNotEqual(HUDState.warning(message: "hi"), HUDState.warning(message: "bye"))
  }

  /// Everything the pill shows while listening comes from the level and the
  /// rough draft — and the rough draft is handed to the panel BESIDE the state,
  /// never inside it, so that equality comparisons keep working. Which means a
  /// listening tick must depend on nothing but the level: the previous
  /// session's warning and inserted text are still set on the controller while the
  /// next one runs, and a state that flickered between them and `.listening`
  /// would restart the panel's frame animation mid-sentence.
  func testListeningDependsOnNothingButTheLevel() {
    let clean = HUDState.compute(
      controllerState: .listening,
      isPolishInProgress: false,
      lastPolishWarning: nil,
      lastSecureFieldNotice: nil,
      rmsLevel: 0.42
    )
    let withStaleNotices = HUDState.compute(
      controllerState: .listening,
      isPolishInProgress: true,
      lastPolishWarning: "Polish failed. Using rules-only result.",
      lastSecureFieldNotice: "Refused secure field",
      rmsLevel: 0.42
    )
    XCTAssertEqual(clean, withStaleNotices)
  }
}
