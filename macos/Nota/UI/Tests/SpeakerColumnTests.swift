import AppKit
import XCTest

@testable import Nota

/// ADR 0008 (the speaker column) and ADR 0006's 2026-09-02 addendum (the pane
/// draws the title and the transcript, and nothing else).
///
/// The column's two edges are asserted twice over, on purpose. The arithmetic
/// (`SpeakerColumn`) is pure and pinned directly; the **laid-out** text is then
/// measured through a real TextKit stack, because XIA-444's lesson in this repo
/// is that a number and the thing it describes can disagree with every geometry
/// test in the file green through it — there, a typed `controlRowHeight` of 40
/// against a row that laid out at 41.
final class SpeakerColumnTests: XCTestCase {
  /// A Nota export, whole: header block, summary sections, the `---` rule, and
  /// the transcript under `## Full Transcript` (`src/pipeline/write.ts`).
  private static let export = """
    # Standup

    **Captured:** 2026-05-20
    **Duration:** 19 minutes
    **Tags:** roadmap, hiring

    ## Summary

    The team agreed to ship the reading column this week.

    ## Key Topics

    - **Graduation timeline** — aiming for fall quarter.

    ## Decisions Made

    - Ship on Thursday.

    ## Action Items

    - Freya to file the ticket.

    ---

    ## Full Transcript

    [00:03] **Brian Demsky:** You've used four of that six quarters.
    [00:28] **Freya Wu:** Okay.
    [00:31] A line with no speaker at all.
    """

  // MARK: - Two columns

  /// **Names right-aligned on one edge, words left-aligned on another.**
  ///
  /// The line is `tab + name + tab + text`: a right tab at the name column's
  /// trailing edge, a left tab at the text edge. Asserted on the paragraph
  /// style the renderer produced *and* on the string it produced, because a tab
  /// stop with no tab character in front of it aligns nothing.
  func testNamesAreRightAlignedAndWordsLeftAlignedOnOneEdgeEach() {
    let rendered = renderMarkdownAsRichText(Self.export, sections: .transcript)
    let text = rendered.string as NSString
    let range = text.range(of: "Brian Demsky")
    XCTAssertNotEqual(range.location, NSNotFound, "the transcript lost its speaker")

    // The two tabs really are in the text, around the name.
    XCTAssertEqual(
      text.substring(with: NSRange(location: range.location - 1, length: 1)), "\t",
      "the name is not preceded by a tab, so the right-aligned stop aligns nothing")
    XCTAssertEqual(
      text.substring(with: NSRange(location: NSMaxRange(range), length: 1)), "\t",
      "the words are not preceded by a tab, so they start wherever the name ended")

    guard
      let style = rendered.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
        as? NSParagraphStyle
    else { return XCTFail("the speaker line carries no paragraph style") }

    let names = ["Brian Demsky", "Freya Wu"]
    // Ordinary names are drawn in full — the ladder is the exception a very
    // long name reaches, not the normal rendering.
    XCTAssertEqual(SpeakerColumn.drawnName("Brian Demsky"), "Brian Demsky")
    let nameWidth = SpeakerColumn.width(forNames: names)
    let edge = SpeakerColumn.textEdge(nameWidth: nameWidth)
    XCTAssertGreaterThan(nameWidth, 0, "the document has speakers and no name column")

    XCTAssertEqual(style.tabStops.count, 2, "a two-column line needs exactly two stops")
    XCTAssertEqual(style.tabStops[0].alignment, .right, "the name column is not right-aligned")
    XCTAssertEqual(style.tabStops[0].location, nameWidth, accuracy: 0.5)
    XCTAssertEqual(style.tabStops[1].alignment, .left, "the words are not left-aligned")
    XCTAssertEqual(style.tabStops[1].location, edge, accuracy: 0.5)
    XCTAssertEqual(
      style.headIndent, edge, accuracy: 0.5,
      "a wrapped line does not return to the text edge")

    // A timestamped line with no speaker starts on the SAME edge — one left
    // edge for the whole transcript is the point.
    let plain = text.range(of: "A line with no speaker at all.")
    guard
      let plainStyle = rendered.attribute(.paragraphStyle, at: plain.location, effectiveRange: nil)
        as? NSParagraphStyle
    else { return XCTFail("the speakerless line carries no paragraph style") }
    XCTAssertEqual(plainStyle.firstLineHeadIndent, edge, accuracy: 0.5)
    XCTAssertEqual(plainStyle.headIndent, edge, accuracy: 0.5)
  }

  /// **A wrapped line starts at the text edge, not under the name** — measured
  /// on real glyphs, which is the half the paragraph style cannot promise.
  ///
  /// The old inline `"Name: "` prefix put the second line of a long turn back
  /// underneath the name, and that is exactly what a `headIndent` fixes; but a
  /// `headIndent` set on a paragraph whose first line is produced by tab stops
  /// is the kind of thing TextKit can decline. So the turn is laid out in a
  /// container narrow enough to wrap it and the line fragments are read back.
  func testAWrappedLineStartsAtTheTextEdgeAndNotUnderTheName() {
    let long = String(repeating: "words that keep going and going ", count: 12)
    let markdown = """
      ## Full Transcript

      [00:03] **Brian Demsky:** \(long)
      """
    let rendered = renderMarkdownAsRichText(markdown, sections: .transcript)
    let nameWidth = SpeakerColumn.width(forNames: ["Brian Demsky"])
    let edge = SpeakerColumn.textEdge(nameWidth: nameWidth)

    let storage = NSTextStorage(attributedString: rendered)
    let layout = NSLayoutManager()
    let container = NSTextContainer(
      size: NSSize(width: Metrics.readingMeasure, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    layout.addTextContainer(container)
    storage.addLayoutManager(layout)
    layout.ensureLayout(for: container)

    var fragments: [NSRect] = []
    var index = 0
    while index < layout.numberOfGlyphs {
      var effective = NSRange(location: 0, length: 0)
      let used = layout.lineFragmentUsedRect(forGlyphAt: index, effectiveRange: &effective)
      fragments.append(used)
      index = NSMaxRange(effective)
      if effective.length == 0 { break }
    }
    XCTAssertGreaterThan(
      fragments.count, 1, "the sample did not wrap, so there is no wrapped line to check")

    // The name itself ends on the name column's trailing edge.
    let nameRange = (rendered.string as NSString).range(of: "Brian Demsky")
    let nameGlyphs = layout.glyphRange(forCharacterRange: nameRange, actualCharacterRange: nil)
    let nameRect = layout.boundingRect(forGlyphRange: nameGlyphs, in: container)
    XCTAssertEqual(
      nameRect.maxX, nameWidth, accuracy: 1.0,
      "the name is not right-aligned to the column's trailing edge")

    // Every line after the first starts on the text edge.
    for (line, rect) in fragments.enumerated().dropFirst() {
      XCTAssertEqual(
        rect.minX, edge, accuracy: 1.0,
        "wrapped line \(line) starts at \(rect.minX), not on the text edge \(edge)")
    }
  }

  // MARK: - The column is measured

  /// **The column tracks the longest name the document actually draws**, and
  /// nothing else — not a typed constant, not the first name it sees.
  func testTheColumnWidthTracksTheLongestName() {
    let short = SpeakerColumn.width(forNames: ["Al"])
    let mixed = SpeakerColumn.width(forNames: ["Al", "Bartholomew"])
    XCTAssertEqual(mixed, SpeakerColumn.width(of: "Bartholomew"), accuracy: 0.5)
    XCTAssertGreaterThan(mixed, short, "a longer name did not widen the column")
    XCTAssertEqual(
      SpeakerColumn.width(forNames: []), 0,
      "a document with no speakers still reserved a column")
    XCTAssertEqual(
      SpeakerColumn.textEdge(nameWidth: 0), 0,
      "a document with no speakers still indented its words")

    // …and it is capped, so the reading measure keeps its band. The cap is
    // derived from that measure rather than typed, so this asserts the
    // derivation and not a number.
    XCTAssertEqual(
      SpeakerColumn.maximumWidth,
      Metrics.readingMeasure - SpeakerColumn.minimumTextEms * NSFonts.readingBody.pointSize
        - SpeakerColumn.gap,
      accuracy: 0.01)
    let absurd = String(repeating: "Wigglesworth", count: 6)
    XCTAssertLessThanOrEqual(
      SpeakerColumn.width(forNames: [absurd]), SpeakerColumn.maximumWidth + 0.5,
      "one long name ate the reading column")
    // 34em ≈ 74 characters, so ~2.18 characters per em: the text column may not
    // fall under the band's 45-character floor, i.e. ~21em.
    XCTAssertGreaterThanOrEqual(
      SpeakerColumn.minimumTextEms, 21,
      "the text column dropped under the 45–75 character band the measure exists for")
  }

  /// **Abbreviated, never truncated**: full name → `Brian D.` → `B.D.`, with an
  /// ellipsis only when a single word leaves nothing else to try.
  ///
  /// Driven by shrinking the limit rather than by lengthening the name, so each
  /// rung is reached deliberately instead of by whatever the face happens to
  /// measure.
  func testTheAbbreviationLadder() {
    let name = "Brian Demsky"
    let full = SpeakerColumn.width(of: name)
    XCTAssertEqual(
      SpeakerColumn.fitted(name, within: full + 10), name,
      "a name that fits was shortened anyway")

    let shortened = SpeakerColumn.fitted(name, within: full - 1)
    XCTAssertEqual(shortened, "Brian D.", "the first rung is first name + last initial")

    let initials = SpeakerColumn.fitted(name, within: SpeakerColumn.width(of: "Brian D.") - 1)
    XCTAssertEqual(initials, "B.D.", "the second rung is initials")

    // Nothing on the ladder is a mid-word cut.
    XCTAssertFalse(shortened.contains("\u{2026}"))
    XCTAssertFalse(initials.contains("\u{2026}"))

    // One absurd word: the ellipsis is the only rung left, and it is the last
    // one — a name is a person, so it is reached and not taken first.
    let single = "Wigglesworthingtonshire"
    let elided = SpeakerColumn.fitted(single, within: 30)
    XCTAssertTrue(elided.hasSuffix("\u{2026}"), "a single long word was not elided: \(elided)")
    XCTAssertLessThanOrEqual(SpeakerColumn.width(of: elided), 30 + 0.5)
    XCTAssertEqual(
      SpeakerColumn.fitted(single, within: 0), single,
      "a zero limit means no column, and no column may rewrite a name")

    // The full name survives on the run whatever was drawn (`.notaSpeakerName`),
    // which is what the identity-hue pass and the hover path read.
    let markdown = "## Full Transcript\n\n[00:03] **\(single):** hi"
    let rendered = renderMarkdownAsRichText(markdown, sections: .transcript)
    var carried: [String] = []
    rendered.enumerateAttribute(
      .notaSpeakerName, in: NSRange(location: 0, length: rendered.length)
    ) { value, _, _ in
      if let name = value as? String { carried.append(name) }
    }
    XCTAssertEqual(carried, [single], "the drawn name is the only name left in the document")
  }

  /// A renamed speaker is still measured and drawn under its **override**, and
  /// the override is what the run carries — the identity hue is keyed by it.
  func testAnOverrideIsWhatTheColumnMeasuresAndCarries() {
    let markdown = "## Full Transcript\n\n[00:03] **Speaker 1:** hi"
    let rendered = renderMarkdownAsRichText(markdown, overrides: ["Speaker 1": "Kenny Kim"], sections: .transcript)
    let text = rendered.string as NSString
    XCTAssertNotEqual(text.range(of: "Kenny Kim").location, NSNotFound)
    XCTAssertEqual(text.range(of: "Speaker 1").location, NSNotFound)
    XCTAssertEqual(
      rendered.attribute(
        .notaSpeakerName, at: text.range(of: "Kenny Kim").location, effectiveRange: nil)
        as? String,
      "Kenny Kim")

    let chips = [SpeakerChip(label: "Speaker 1", name: "Kenny Kim", indicator: .enrolled)]
    let coloured = MainPaneView.applySpeakerColors(to: rendered, chips: chips)
    XCTAssertEqual(
      coloured.attribute(
        .foregroundColor, at: (coloured.string as NSString).range(of: "Kenny Kim").location,
        effectiveRange: nil) as? NSColor,
      SpeakerColors.nsColor(at: 0),
      "the renamed speaker's run did not take its identity hue")
  }

  // MARK: - The pane is the transcript

  /// **A summarized meeting draws no summary in the body** (ADR 0006 addendum).
  ///
  /// The narrative, key topics, decisions and action items are drawn by
  /// `SummaryRailView` off the record. Drawing them here too was the same text,
  /// twice, on every meeting that had been summarized — and the `## Full
  /// Transcript` heading went with them, because the pane *is* the transcript.
  func testADocumentWithASummaryRendersNoSummaryInTheBody() {
    let body = renderMarkdownAsRichText(Self.export, sections: .transcript).string
    for gone in [
      "The team agreed to ship the reading column this week.",
      "Summary", "Key Topics", "Decisions Made", "Action Items",
      "Graduation timeline", "Freya to file the ticket",
      "Full Transcript", "Captured", "Duration", "Tags",
    ] {
      XCTAssertFalse(body.contains(gone), "\"\(gone)\" is still drawn in the document body")
    }
    // …and the transcript itself is all there.
    XCTAssertTrue(body.contains("You've used four of that six quarters."))
    XCTAssertTrue(body.contains("A line with no speaker at all."))
    // It opens on the transcript, not on the blank line that followed the
    // heading.
    XCTAssertTrue(
      body.hasPrefix("\t\(SpeakerColumn.drawnName("Brian Demsky"))\t"),
      "the body opens with \"\(body.prefix(20))\" rather than the first turn")

    // Copy and export still get the whole document — a different question, and
    // one the pane does not ask.
    let whole = renderMarkdownAsRichText(Self.export, sections: .whole).string
    XCTAssertTrue(whole.contains("The team agreed to ship the reading column this week."))
    XCTAssertTrue(whole.contains("Full Transcript"))
  }

  /// **A foreign `.md` still renders in full.**
  ///
  /// The rule degrades on the presence of `## Full Transcript`: a file without
  /// one is not a Nota export, so there are no summary sections to drop and
  /// nothing to hide. Cutting "everything before the transcript"
  /// unconditionally would render an imported file as nothing at all — which is
  /// the failure ADR 0006 already forbids by name, that nothing about a
  /// document may disappear because of where it was opened from.
  func testAForeignMarkdownFileStillRendersFully() {
    let foreign = """
      # Notes from a book

      Some ordinary prose that a person wrote.

      ## Chapter one

      - a bullet
      - another bullet

      A closing paragraph.
      """
    let body = renderMarkdownAsRichText(foreign, sections: .transcript).string
    for kept in [
      "Some ordinary prose that a person wrote.", "Chapter one",
      "a bullet", "another bullet", "A closing paragraph.",
    ] {
      XCTAssertTrue(body.contains(kept), "the imported file lost \"\(kept)\"")
    }
    // Its `# ` line is the title the pane draws, so the body does not repeat it.
    XCTAssertFalse(
      body.contains("Notes from a book"),
      "the title is in the body as well as on the pane — it would be drawn twice")
    XCTAssertEqual(parseDocumentMeta(foreign)?.title, "Notes from a book")

    // A file with no heading at all keeps every line, because there is no title
    // for the pane to draw either.
    let headerless = "just a line\nand another"
    XCTAssertEqual(
      renderMarkdownAsRichText(headerless, sections: .transcript).string.trimmingCharacters(in: .newlines),
      headerless)
    XCTAssertNil(parseDocumentMeta(headerless))
  }

  /// The body plan is a pure decision, so the two rules are readable without a
  /// render: where the body starts, and which line the pane claimed as a title.
  func testTheBodyPlanNamesTheTitleLineAndWhereTheTranscriptStarts() {
    let lines = Self.export.components(separatedBy: "\n")
    let transcript = DocumentBody.plan(lines: lines, sections: .transcript)
    XCTAssertEqual(transcript.titleLine, 0)
    XCTAssertEqual(
      lines[transcript.range.lowerBound],
      "[00:03] **Brian Demsky:** You've used four of that six quarters.")

    let whole = DocumentBody.plan(lines: lines, sections: .whole)
    XCTAssertEqual(whole.titleLine, 0)
    XCTAssertEqual(lines[whole.range.lowerBound], "## Summary")

    // No `## Full Transcript`: nothing about the file's shape is known, so the
    // plan starts at the top and only the title line is stepped over — in both
    // modes, since copy and export have no more reason to guess than the pane
    // does.
    let imported = ["", "# Title", "prose", "## A heading", "more prose"]
    for mode in [RenderedSections.transcript, .whole] {
      let plan = DocumentBody.plan(lines: imported, sections: mode)
      XCTAssertEqual(plan.titleLine, 1)
      XCTAssertEqual(
        plan.range.lowerBound, 2,
        "\(mode) ate an imported file's opening paragraph")
    }
  }
}
