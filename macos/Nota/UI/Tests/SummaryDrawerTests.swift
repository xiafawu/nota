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

  // MARK: Divider drag stability

  func testDragTargetHeightTracksPointerMonotonically() {
    let available: CGFloat = 1_000
    let cap = SummaryDrawerLayout.expandedMaxHeight(for: available)
    XCTAssertEqual(cap, SummaryDrawerLayout.expandedAbsoluteMaxHeight, accuracy: 0.01)

    var previous = SummaryDrawerLayout.dragTargetHeight(
      startHeight: 260, startY: 100, currentY: 100, availableHeight: available
    )
    XCTAssertEqual(previous, 260, accuracy: 0.01)

    for step in 1...15 {
      let next = SummaryDrawerLayout.dragTargetHeight(
        startHeight: 260,
        startY: 100,
        currentY: 100 + CGFloat(step) * 10,
        availableHeight: available
      )
      XCTAssertGreaterThanOrEqual(next, previous, "height must never move against the pointer")
      previous = next
    }
    // Free run then clamp: the height follows the pointer up to the cap and
    // holds there instead of oscillating.
    XCTAssertEqual(previous, cap, accuracy: 0.01)
    XCTAssertEqual(
      SummaryDrawerLayout.dragTargetHeight(
        startHeight: 260, startY: 100, currentY: 180, availableHeight: available
      ),
      340, accuracy: 0.01
    )
  }

  func testDragTargetHeightIsReversibleWithoutOscillation() {
    let available: CGFloat = 1_000
    let start = SummaryDrawerLayout.expandedDefaultHeight
    let down = SummaryDrawerLayout.dragTargetHeight(
      startHeight: start, startY: 100, currentY: 180, availableHeight: available
    )
    XCTAssertEqual(down, start + 80, accuracy: 0.01)

    // Retracing the pointer path returns exactly to the start — the result is
    // a pure function of the pointer position, never of the applied height.
    let back = SummaryDrawerLayout.dragTargetHeight(
      startHeight: start, startY: 100, currentY: 100, availableHeight: available
    )
    XCTAssertEqual(back, start, accuracy: 0.01)
  }

  func testDragToLimitAndBackUnclampsFromAnchor() {
    let available: CGFloat = 1_000
    let cap = SummaryDrawerLayout.expandedMaxHeight(for: available)
    XCTAssertEqual(
      SummaryDrawerLayout.dragTargetHeight(
        startHeight: 260, startY: 100, currentY: 10_000, availableHeight: available
      ),
      cap, accuracy: 0.01
    )
    // Dragging back out of the clamp resumes from the gesture anchor, so the
    // clamped intermediate value cannot corrupt the drag.
    XCTAssertEqual(
      SummaryDrawerLayout.dragTargetHeight(
        startHeight: 260, startY: 100, currentY: 150, availableHeight: available
      ),
      310, accuracy: 0.01
    )
  }

  func testClampingIsIdempotent() {
    let available: CGFloat = 560
    let maximum = SummaryDrawerLayout.expandedMaxHeight(for: available)
    let clampedOnce = SummaryDrawerLayout.clampedExpandedHeight(999, availableHeight: available)
    XCTAssertEqual(clampedOnce, maximum, accuracy: 0.01)
    XCTAssertEqual(
      SummaryDrawerLayout.clampedExpandedHeight(clampedOnce, availableHeight: available),
      clampedOnce,
      accuracy: 0.01
    )
  }

  // MARK: Transcript scroll-restore coalescing

  func testScrollRestoreDropsStaleRevisionsAndClampsTarget() {
    XCTAssertTrue(RichTextScrollRestore.shouldApply(revision: 3, latestRevision: 3))
    XCTAssertFalse(RichTextScrollRestore.shouldApply(revision: 2, latestRevision: 3))

    // Preserved offset beyond the end of the document clamps to the maximum
    // valid offset; negative offsets clamp to the top.
    XCTAssertEqual(
      RichTextScrollRestore.targetOffset(
        preservedY: 500, documentHeight: 800, viewportHeight: 400
      ),
      400, accuracy: 0.01
    )
    XCTAssertEqual(
      RichTextScrollRestore.targetOffset(
        preservedY: -20, documentHeight: 800, viewportHeight: 400
      ),
      0, accuracy: 0.01
    )
    XCTAssertEqual(
      RichTextScrollRestore.targetOffset(
        preservedY: 100, documentHeight: 200, viewportHeight: 400
      ),
      0, accuracy: 0.01
    )

    // Sub-half-point drift is skipped so a restore cannot feed a
    // bounds-change notification back into layout; real drift applies.
    XCTAssertFalse(RichTextScrollRestore.needsRestore(currentY: 100, targetY: 100.2))
    XCTAssertTrue(RichTextScrollRestore.needsRestore(currentY: 100, targetY: 101))
  }
}
