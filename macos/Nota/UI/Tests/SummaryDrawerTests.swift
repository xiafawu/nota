import XCTest
@testable import Nota

final class SummaryDrawerTests: XCTestCase {
  func testPreviewNormalizesWhitespaceAndKeepsShortNarrative() {
    XCTAssertEqual(
      SummaryDrawerLayout.preview(for: " First\n\nshort summary. "),
      "First short summary."
    )
  }

  func testPreviewTruncatesAtAWordBoundary() {
    let narrative = String(repeating: "A useful sentence. ", count: 30)
    let preview = SummaryDrawerLayout.preview(for: narrative)

    XCTAssertLessThanOrEqual(preview.count, SummaryDrawerLayout.previewCharacterLimit + 1)
    XCTAssertTrue(preview.hasSuffix("…"))
    XCTAssertFalse(preview.dropLast().last == " ")
  }

  func testExpandedHeightLeavesTranscriptRoomAndHonorsAbsoluteCap() {
    XCTAssertEqual(
      SummaryDrawerLayout.expandedMaxHeight(for: 320),
      160,
      accuracy: 0.01
    )
    XCTAssertEqual(
      SummaryDrawerLayout.expandedMaxHeight(for: 1_000),
      SummaryDrawerLayout.expandedAbsoluteMaxHeight,
      accuracy: 0.01
    )
  }

  func testExpandedHeightClampsToSafeBounds() {
    XCTAssertEqual(
      SummaryDrawerLayout.clampedExpandedHeight(-1, availableHeight: 560),
      SummaryDrawerLayout.expandedMinHeight,
      accuracy: 0.01
    )
    XCTAssertEqual(
      SummaryDrawerLayout.clampedExpandedHeight(999, availableHeight: 560),
      SummaryDrawerLayout.expandedMaxHeight(for: 560),
      accuracy: 0.01
    )
  }
}
