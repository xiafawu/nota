import SwiftUI
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

  /// The two panels are the same width, the same radius and the same shape by
  /// design, and their section headers disagreed anyway — uppercase kerned
  /// caption2 in the rail, 12pt mono in the drawer (P-D9). Both draw
  /// `CraftSectionLabel` now, so what is left to pin is the one style it
  /// carries: a *section label*, not the `metadataFont` a timestamp takes.
  func testTheTwoPanelsShareOneSectionLabelFont() {
    XCTAssertEqual(CraftTokens.sectionLabelFont, .caption2.weight(.semibold))
    XCTAssertNotEqual(CraftTokens.sectionLabelFont, CraftTokens.metadataFont)
    XCTAssertEqual(CraftTokens.sectionLabelKerning, 0.8)
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

  // MARK: The panel is the summary's only home (ADR 0006 addendum, 2026-09-02)
  //
  // The summary left the document body, so `SummaryRailView` is the only place
  // a summary is drawn. Everything the body used to carry for an **imported**
  // `.md` — one with no history record — now has to come out of the markdown
  // itself, or it is visible nowhere at all: the exact failure ADR 0006's own
  // rule forbids, that nothing about a document may disappear because of where
  // it was opened from.
  //
  // All of it is pure. `SummaryRailView` cannot be hosted (`NotaModel.init`
  // sweeps the real `~/.nota` and runs preflight), so the contract is stated as
  // functions the view calls and these tests hold: `summaryHalf` for which half
  // is drawn, `offersRecordControls` for what that half may offer, and
  // `parseDocumentSummary` / `parsedFallback` for what it draws.

  /// A meeting export, exactly the shape `src/pipeline/write.ts` emits.
  private static let meetingExport = """
  # Weekly sync

  **Captured:** 2026-05-20
  **Transcribed:** 2026-05-20
  **Duration:** 19 minutes
  **Source:** sync.m4a
  **Tags:** planning, hiring

  ## Summary

  Kenny walked through the migration plan.

  Freya raised the staffing risk.

  ## Key Topics

  - Migration — the cutover window
  - Hiring

  ## Decisions Made

  - Cut over on the 3rd

  ## Action Items

  - [ ] Kenny drafts the runbook
  - [ ] Freya opens the req

  ---

  ## Full Transcript

  0:00 **Kenny Kim:** So the plan is
  0:04 **Freya Wu:** One risk
  """

  /// The same document with nothing summarized — a transcript-only meeting, or
  /// an imported `.md` that was never more than a transcript.
  private static let transcriptOnlyExport = """
  # Weekly sync

  **Captured:** 2026-05-20
  **Duration:** 19 minutes
  **Source:** sync.m4a

  ---

  ## Full Transcript

  0:00 **Kenny Kim:** So the plan is
  """

  // A document with a record is untouched.

  func testADocumentWithARecordStillDrawsTheRecordsSummary() {
    // The three states the panel had before the fallback existed, spelled the
    // way `SummaryRailDismissalTests` spells them — the new parameter defaults.
    XCTAssertEqual(
      SummaryRailView.summaryHalf(hasRecord: true, isResolvingRecord: false), .summary)
    XCTAssertEqual(
      SummaryRailView.summaryHalf(hasRecord: false, isResolvingRecord: false), .noRecordNotice)
    XCTAssertEqual(
      SummaryRailView.summaryHalf(hasRecord: false, isResolvingRecord: true), .waitingForRecord)

    // And a record wins over a document that could have been parsed, so a
    // recorded meeting never reads its own export back.
    XCTAssertEqual(
      SummaryRailView.summaryHalf(
        hasRecord: true, isResolvingRecord: false, hasParsedSummary: true),
      .summary)
    XCTAssertNil(
      SummaryRailView.parsedFallback(hasRecord: true, markdown: Self.meetingExport))
  }

  // An imported document with a summary.

  func testAnImportedDocumentFallsBackToItsOwnSummary() {
    XCTAssertEqual(
      SummaryRailView.summaryHalf(
        hasRecord: false, isResolvingRecord: false, hasParsedSummary: true),
      .parsedSummary)

    let parsed = SummaryRailView.parsedFallback(
      hasRecord: false, markdown: Self.meetingExport)
    XCTAssertEqual(
      parsed?.narrative,
      "Kenny walked through the migration plan.\n\nFreya raised the staffing risk.")
    XCTAssertEqual(parsed?.keyTopics, ["Migration — the cutover window", "Hiring"])
    XCTAssertEqual(parsed?.decisions, ["Cut over on the 3rd"])
    // The `[ ] ` prefix is kept, exactly as the record's copies carry it —
    // `displayActionItem` strips it for both, so the two renderings cannot
    // disagree about what an action item looks like.
    XCTAssertEqual(
      parsed?.actionItems, ["[ ] Kenny drafts the runbook", "[ ] Freya opens the req"])
  }

  /// A memo writes `## Note` instead of `## Summary` and emits no Key Topics or
  /// Decisions at all (`write.ts`, `isMemo`).
  func testAMemosNoteIsItsNarrative() {
    let memo = """
    # Voice memo

    **Captured:** 2026-05-20

    ## Note

    Remember to renew the domain.

    ## Action Items

    - [ ] Renew nota.app

    ---

    ## Full Transcript

    0:00 Remember to renew
    """
    let parsed = parseDocumentSummary(memo)
    XCTAssertEqual(parsed?.narrative, "Remember to renew the domain.")
    XCTAssertEqual(parsed?.actionItems, ["[ ] Renew nota.app"])
    XCTAssertEqual(parsed?.keyTopics, [])
    XCTAssertEqual(parsed?.decisions, [])
  }

  // A parsed summary is read-only.

  func testAParsedSummaryOffersNoControlThatWouldNeedARecord() {
    // Edit, Regenerate, the Edited pill, the saving spinner and Generate
    // Summary all write to a record. There is none behind a parsed summary, so
    // they are absent rather than disabled — and this is the one answer both
    // arms of the summary fork ask.
    XCTAssertTrue(SummaryRailView.SummaryHalf.summary.offersRecordControls)
    XCTAssertFalse(SummaryRailView.SummaryHalf.parsedSummary.offersRecordControls)
    XCTAssertFalse(SummaryRailView.SummaryHalf.noRecordNotice.offersRecordControls)
    XCTAssertFalse(SummaryRailView.SummaryHalf.waitingForRecord.offersRecordControls)
  }

  // Nothing is drawn while the record lookup is in flight.

  func testTheFallbackWaitsForTheRecordLookupToSettle() {
    // `NotaModel.loadChips` clears the record synchronously and reads the real
    // one off disk in a detached task, so every recorded transcript passes
    // through `record == nil`. Parsing is instant and the disk read is not, so
    // a fallback that did not wait would flash the document's own summary and
    // then swap it for the record's, on open, every time.
    XCTAssertEqual(
      SummaryRailView.summaryHalf(
        hasRecord: false, isResolvingRecord: true, hasParsedSummary: true),
      .waitingForRecord)
    XCTAssertEqual(
      SummaryRailView.summaryHalf(
        hasRecord: false, isResolvingRecord: true, hasParsedSummary: false),
      .waitingForRecord)
  }

  // An imported document with no summary at all.

  func testADocumentWithNoSummaryKeepsTheOneLineNotice() {
    XCTAssertNil(parseDocumentSummary(Self.transcriptOnlyExport))
    XCTAssertNil(
      SummaryRailView.parsedFallback(
        hasRecord: false, markdown: Self.transcriptOnlyExport))
    XCTAssertEqual(
      SummaryRailView.summaryHalf(
        hasRecord: false, isResolvingRecord: false, hasParsedSummary: false),
      .noRecordNotice)
    XCTAssertEqual(
      SummaryRailView.noRecordNotice,
      "No history record for this document, so there is no summary to generate.")

    // An empty `## Summary` is nothing, not an empty heading over nothing.
    XCTAssertNil(
      parseDocumentSummary("# T\n\n## Summary\n\n---\n\n## Full Transcript\n\n0:00 hi"))
  }

  /// The cost rule, asserted behaviourally. `parseDocumentMeta` stops at the
  /// *first* `## `; this parse starts there and stops at the boundary the writer
  /// puts above the transcript. A transcript line that looks like a heading or a
  /// bullet is below that boundary, so it can never reach the panel — and if it
  /// did, the loop had gone on reading the long half of the document.
  func testTheParseStopsAboveTheTranscript() {
    let trap = """
    # Trap

    ## Summary

    The real narrative.

    ---

    ## Action Items

    - This bullet is below the separator
    0:00 **Speaker:** ## Key Topics
    """
    let parsed = parseDocumentSummary(trap)
    XCTAssertEqual(parsed?.narrative, "The real narrative.")
    XCTAssertEqual(parsed?.actionItems, [])
    XCTAssertEqual(parsed?.keyTopics, [])

    // `## Full Transcript` stops it too, for a document whose separator was
    // dropped.
    let noRule = """
    # Trap

    ## Summary

    The real narrative.

    ## Full Transcript

    ## Action Items

    - Below the transcript heading
    """
    XCTAssertEqual(parseDocumentSummary(noRule)?.actionItems, [])

    // A document that opens with YAML front matter is not cut off at its first
    // line: the `---` stop only counts once a `## ` heading has been seen.
    let frontMatter = """
    ---
    title: Imported
    ---

    ## Summary

    Still found.
    """
    XCTAssertEqual(parseDocumentSummary(frontMatter)?.narrative, "Still found.")
  }

  /// The panel reads this two to four times per body evaluation and its own
  /// `TextEditor` writes an `@Published` on the model it observes, so the parse
  /// has to be free on the repeat. The memo makes it free; `parseCount` makes
  /// that a fact rather than a claim in a comment.
  func testTheParseIsMemoizedAgainstTheMarkdown() {
    // Unique per run, because the memo is one entry shared by every test in
    // this class and XCTest picks the order: a fixture another test has
    // already read would be a cache *hit* on the line asserting the miss.
    // The nonce rides below `## Full Transcript`, where the parse has already
    // stopped, so these are the fixtures' own parses under different keys.
    let stamp = UUID().uuidString
    let summarized = Self.meetingExport + "\n<!-- \(stamp) -->"
    let bare = Self.transcriptOnlyExport + "\n<!-- \(stamp) -->"

    let before = DocumentSummaryCache.parseCount
    let first = DocumentSummaryCache.summary(for: summarized)
    let afterFirst = DocumentSummaryCache.parseCount
    XCTAssertEqual(afterFirst, before + 1, "the first read of a document parses it once")
    XCTAssertEqual(first, parseDocumentSummary(Self.meetingExport))

    for _ in 0..<25 {
      XCTAssertEqual(DocumentSummaryCache.summary(for: summarized), first)
    }
    XCTAssertEqual(
      DocumentSummaryCache.parseCount, afterFirst,
      "re-reading the same markdown must not re-parse it")

    // A different document does parse, and the memo cannot hand back the old
    // one — a stale summary under a new title would be the worst failure this
    // whole fallback could have.
    XCTAssertNil(DocumentSummaryCache.summary(for: bare))
    XCTAssertEqual(DocumentSummaryCache.parseCount, afterFirst + 1)
    XCTAssertEqual(DocumentSummaryCache.summary(for: summarized), first)
  }
}
