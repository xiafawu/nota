import XCTest

@testable import Nota

final class ScreenContextCaptureTests: XCTestCase {
  func testVisualFallbackIsNeededWhenAccessibilityTextIsMissingOrShort() {
    XCTAssertTrue(ScreenContextCapture.shouldUseVisualFallback(focusedText: nil))
    XCTAssertTrue(ScreenContextCapture.shouldUseVisualFallback(focusedText: "genc2rust"))
    XCTAssertFalse(
      ScreenContextCapture.shouldUseVisualFallback(
        focusedText: "let result = try await resolveModel(named: modelID)"
      )
    )
  }

  func testOCRTextIsBoundedAndDropsSensitiveLines() {
    let lines = [
      "genc2rust — src/lower.rs",
      "API key: sk-do-not-send-this",
      String(repeating: "x", count: 2_200),
    ]
    let text = ScreenContextCapture.boundedOCRText(lines)
    XCTAssertNotNil(text)
    XCTAssertFalse(text?.contains("sk-do-not-send-this") == true)
    XCTAssertEqual(text?.count, ScreenContextCapture.maxOCRTextLength)
  }

  func testOCRTextWithOnlySensitiveContentIsUnavailable() {
    XCTAssertNil(ScreenContextCapture.boundedOCRText(["Password: hunter2", "private key"]))
  }

  func testMissingProcessFallsBackWithoutRequestingScreenPermission() async {
    let capturedText = await ScreenContextCapture.captureVisibleText(processID: nil)
    XCTAssertNil(capturedText)
  }
}
