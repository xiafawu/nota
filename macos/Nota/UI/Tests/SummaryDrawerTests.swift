import XCTest
@testable import Nota

/// The summary rail has one size (decisions 1-3): the compact/expanded
/// states, divider drag, and 92/260/360pt heights are retired with the inline
/// slot, so `preview(for:)`, `expandedMaxHeight`, `clampedExpandedHeight`,
/// and `dragTargetHeight` and their tests are removed. What remains of the
/// layout contract is the fixed 380pt rail width — matching the history
/// drawer (decision 1). The transcript scroll-restore contract below is
/// untouched by this change.
final class SummaryDrawerTests: XCTestCase {
  func testRailWidthMatchesHistoryDrawer() {
    XCTAssertEqual(SummaryDrawerLayout.railWidth, 380)
    XCTAssertEqual(SummaryDrawerLayout.railWidth, HistoryDrawerView.drawerWidth)
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
