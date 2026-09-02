import AppKit
import SwiftUI
import XCTest

@testable import Nota

/// XIA-441 stage 1: the document pane is painted for the field it sits on.
///
/// The defect this suite exists for is an **adoption gap**, not a wrong value:
/// `GroundInk` solved four text tiers whose names are exactly the transcript's
/// parts, and for three tickets `RecordingPane` was the only file in the app
/// that used them while the document path drew with `NSColor.labelColor` over
/// the same moving ground. A gap is invisible to a test that checks the values
/// that *are* there, so the first test below reads the render path's own output
/// and fails on any macOS semantic colour in it.
final class ReadingColumnTests: XCTestCase {
  private static let sample = """
    # Meeting

    **Captured:** 2026-07-24

    ## Key Topics

    - **Graduation timeline** — aiming for fall quarter.

    ## Full Transcript

    [00:03] **Brian Demsky:** You've used four of that six quarters.
    [00:28] **Freya Wu:** Okay.
    [00:31] A line with no speaker at all.

    ---
    """

  /// A `.md` that is **not** one of Nota's exports: a heading, prose, a bullet,
  /// and no `## Full Transcript` anywhere. Nothing may disappear from it.
  private static let foreign = """
    # Notes from a book

    Some ordinary prose that a person wrote.

    ## Chapter one

    - a bullet
    - another bullet

    A closing paragraph.
    """

  /// What the pane really hands the text view: the title, then the transcript.
  private static func paneBody(_ markdown: String, chips: [SpeakerChip] = [])
    -> NSAttributedString {
    MainPaneView.documentBody(
      DocumentRender(meta: parseDocumentMeta(markdown), body: renderMarkdownAsRichText(markdown)),
      chips: chips)
  }

  // MARK: - The adoption gap

  /// **Nothing in the rendered document draws with a macOS semantic colour.**
  ///
  /// `labelColor` and friends are dynamic catalog colours resolved against the
  /// window's appearance, and they assume an opaque neutral backdrop.
  /// `RichTextViewer` sets `drawsBackground = false`, so they composite straight
  /// onto the field — measured 2026-08-15, `secondaryLabelColor` came out at
  /// 3.42–3.68:1 against a 4.5 bar on every light ground and
  /// `tertiaryLabelColor` at 1.79–2.15 against 3.0 on all fourteen.
  ///
  /// Asserted by **identity against the catalog colours themselves** rather than
  /// by resolved value: two colours can resolve equal on one ground and diverge
  /// on the next, and the rule is about which system the ink comes from.
  func testTheRenderedDocumentUsesNoSemanticColours() {
    // The whole surface, title included — the title moved into the body on
    // 2026-09-02 and it was the last run drawn outside `GroundInk`.
    let rendered = Self.paneBody(Self.sample)
    XCTAssertGreaterThan(rendered.length, 0, "the sample rendered to nothing")

    let banned: [(String, NSColor)] = [
      ("labelColor", .labelColor),
      ("secondaryLabelColor", .secondaryLabelColor),
      ("tertiaryLabelColor", .tertiaryLabelColor),
      ("quaternaryLabelColor", .quaternaryLabelColor),
      ("separatorColor", .separatorColor),
      ("textColor", .textColor),
    ]
    var offenders: [String] = []
    rendered.enumerateAttribute(
      .foregroundColor, in: NSRange(location: 0, length: rendered.length)
    ) { value, range, _ in
      guard let color = value as? NSColor else { return }
      for (name, semantic) in banned where color == semantic {
        let text = (rendered.string as NSString).substring(with: range)
        offenders.append("\(name) on \"\(text.prefix(40))\"")
      }
    }
    XCTAssertEqual(
      offenders, [],
      "the document path is drawing with macOS semantic colours again: \(offenders)")
  }

  /// …and the ink it *does* use is the ground ink, at a tier that was measured.
  func testEveryRunIsDrawnInAGroundInkTier() {
    let rendered = Self.paneBody(Self.sample)
    let known = GroundInk.Tier.allCases.map { GroundInk.nsColor($0) }
    var unknown = 0
    rendered.enumerateAttribute(
      .foregroundColor, in: NSRange(location: 0, length: rendered.length)
    ) { value, _, _ in
      guard let color = value as? NSColor else { return }
      if !known.contains(where: { $0 == color }) { unknown += 1 }
    }
    XCTAssertEqual(unknown, 0, "\(unknown) runs are drawn in ink from no tier")
  }

  /// **The ink stays dynamic.** The attributed string is built once and lives in
  /// a text view across theme changes, so a colour resolved at build time would
  /// leave the document dark-on-dark the moment the owner switched appearance —
  /// a regression against `labelColor`, which was always dynamic.
  func testTheGroundInkResolvesPerAppearance() {
    let color = GroundInk.nsColor(.reading)
    func resolved(_ name: NSAppearance.Name) -> NSColor {
      var out = NSColor.clear
      NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
        out = color.usingColorSpace(.sRGB) ?? .clear
      }
      return out
    }
    let light = resolved(.aqua)
    let dark = resolved(.darkAqua)
    XCTAssertNotEqual(
      light.redComponent, dark.redComponent, accuracy: 0.001,
      "the ink resolved to the same value in both themes — it was baked, not dynamic")
    // …and to the right values: the warm ink, not neutral black or white.
    XCTAssertEqual(light.redComponent, 0x1C / 255, accuracy: 0.01)
    XCTAssertEqual(dark.redComponent, 0xEE / 255, accuracy: 0.01)
    XCTAssertEqual(light.alphaComponent, GroundInk.Tier.reading.alpha, accuracy: 0.01)
  }

  // MARK: - The reading tier

  /// The owner dialled 0.80 against the real ground on 2026-08-16, and it is
  /// only allowed because the body grew to 18.5pt: WCAG calls 18pt and up
  /// *large text*, where AAA is 4.5:1 rather than 7.0. The two numbers are one
  /// decision, so taking the size back down has to fail here rather than
  /// quietly put the body under its bar.
  func testTheReadingTierIsLargeTextAndSaysSo() {
    XCTAssertEqual(GroundInk.Tier.reading.alpha, 0.80, accuracy: 0.001)
    XCTAssertEqual(GroundInk.Tier.reading.minimumContrast, 4.5, accuracy: 0.001)
    XCTAssertGreaterThanOrEqual(
      NSFonts.readingBody.pointSize, 18,
      "the reading tier's 4.5:1 bar is WCAG's LARGE-text bar, and the body is no longer large text")
    // Body is untouched: the live transcript draws it at 14pt on the same
    // grounds, and one alpha cannot answer two sizes.
    XCTAssertEqual(GroundInk.Tier.body.alpha, 1.00, accuracy: 0.001)
    XCTAssertEqual(GroundInk.Tier.body.minimumContrast, 7.0, accuracy: 0.001)
  }

  /// Increase contrast still reaches the reading tier, and upward.
  func testReadingPromotesToFullInk() {
    XCTAssertEqual(GroundInk.Tier.reading.promoted, .body)
    XCTAssertEqual(GroundInk.Tier.reading.alpha(.increased), 1.00, accuracy: 0.001)
    XCTAssertGreaterThan(
      GroundInk.Tier.reading.alpha(.increased), GroundInk.Tier.reading.alpha,
      "promotion made the ink fainter")
  }

  // MARK: - The column

  /// **The measure is capped and the column is centred.** The pane had no cap at
  /// all: `widthTracksTextView` plus a 48pt inset means the line length was
  /// whatever the window was, so a wide window drew ~140-character lines.
  func testTheColumnNeverExceedsTheMeasureAndStaysCentred() {
    for width in [400.0, 700.0, 1000.0, 1440.0, 2560.0] as [CGFloat] {
      let container = RichTextViewer.Column.containerWidth(available: width)
      let inset = RichTextViewer.Column.inset(available: width)

      XCTAssertLessThanOrEqual(
        container, Metrics.readingMeasure + 0.5,
        "at \(width)pt the column ran to \(container)pt, past the measure")
      XCTAssertGreaterThanOrEqual(
        inset, Metrics.gutterWidth,
        "at \(width)pt the inset fell under the gutter the pips are drawn in")
      // Centred: the two margins agree to within a rounding error.
      let trailing = width - container - inset
      if width >= Metrics.readingMeasure + 2 * Metrics.gutterWidth {
        XCTAssertEqual(
          inset, trailing, accuracy: 0.5,
          "at \(width)pt the column is \(inset)pt from the left and \(trailing)pt from the right")
      }
    }
  }

  /// A window too narrow for the measure gives the text everything that is left
  /// rather than clipping it to a cap it cannot afford.
  func testANarrowWindowGivesUpTheMeasureNotTheGutter() {
    let width: CGFloat = 400
    let container = RichTextViewer.Column.containerWidth(available: width)
    XCTAssertEqual(container, width - 2 * Metrics.gutterWidth, accuracy: 0.5)
    XCTAssertEqual(RichTextViewer.Column.inset(available: width), Metrics.gutterWidth, accuracy: 0.5)
  }

  /// The laid-out text view agrees with the arithmetic — XIA-444's lesson, where
  /// a typed constant disagreed with the row it described and every geometry
  /// test in the file stayed green through it.
  func testTheTextViewIsLaidOutToTheColumnItComputed() {
    let textView = HoverTimestampTextView()
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.lineFragmentPadding = 0
    RichTextViewer.layout(textView, in: 1440)

    XCTAssertEqual(
      textView.textContainer?.size.width ?? 0,
      RichTextViewer.Column.containerWidth(available: 1440), accuracy: 0.5)
    XCTAssertEqual(
      textView.textContainerInset.width,
      RichTextViewer.Column.inset(available: 1440), accuracy: 0.5)
  }

  /// **A height-only frame change must not re-lay out the column**, because
  /// re-applying it writes `textContainerInset`, which invalidates the whole
  /// text layout.
  ///
  /// This is a regression test with a symptom: the transcript visibly shook
  /// while being scrolled (owner, 2026-08-17). Scrolling reports an offset, the
  /// host collapses the document header on it, the collapse changes the scroll
  /// view's height, the clip view's frame changes — and the frame observer
  /// rebuilt the column, moved the document under the scroller, and produced
  /// another offset. The column is a function of width alone.
  func testAHeightOnlyFrameChangeDoesNotRebuildTheColumn() {
    XCTAssertFalse(
      RichTextViewer.Column.needsRelayout(from: 900, to: 900),
      "an unchanged width asked for a relayout — this is the scroll shake")
    XCTAssertFalse(
      RichTextViewer.Column.needsRelayout(from: 900, to: 900.4),
      "sub-half-point drift is not worth invalidating the text layout for")
    XCTAssertTrue(
      RichTextViewer.Column.needsRelayout(from: 900, to: 1200),
      "a real resize was ignored, so the column would keep the old width")
    // A clip view can report zero mid-teardown; rebuilding to nothing would
    // collapse the column and there is nothing to show anyway.
    XCTAssertFalse(RichTextViewer.Column.needsRelayout(from: 900, to: 0))
  }

  // MARK: - The title, and the band that used to hold it

  /// **Nothing is pinned above the transcript, and the document's metadata
  /// cannot add height to it.**
  ///
  /// This is the honest replacement for
  /// `testTheHeaderIsOneHeightWhateverTheDocumentCarries`, which laid out
  /// `DocumentHeaderView` three times and required one height. That view is
  /// deleted (2026-09-02): the title is the document's own first line, drawn in
  /// the reading column and scrolling with the text.
  ///
  /// What the old test *guaranteed* is what is asserted here, in the two halves
  /// that survive the deletion. **The loop cannot start**: the owner saw the
  /// transcript shaking under a scroll, and the shape of it was a band whose
  /// height changed on scroll changing the scroll range that decided it should
  /// change — so the band's contents are what mattered. Vary the document's
  /// metadata (a subtitle, three tags, twenty tags) and the drawn body must be
  /// **byte-identical**: none of it reaches the reading surface at all, so none
  /// of it can change a height. And **there is no band left**: the pane draws
  /// the viewer directly, with no `DocumentHeaderView` and no hairline under it.
  ///
  /// The second half is a source read for the reason the `Divider()` scan below
  /// is one — a hosting view in this bundle publishes no accessibility tree, so
  /// "there is no band" is not a question a rendered pane can answer here.
  /// (The compiler holds most of it already: `DocumentHeaderView` no longer
  /// exists, so a reference to it would not build.)
  func testNothingIsPinnedAboveTheTranscriptAndTheMetadataCannotResizeIt() {
    let markdown = """
      # Team Sync

      **Captured:** 2026-05-20

      ## Full Transcript

      [00:03] **Alice:** hello
      """
    func body(subtitle: String, tags: [String]) -> NSAttributedString {
      MainPaneView.documentBody(
        DocumentRender(
          meta: DocMeta(title: "Team Sync", subtitle: subtitle, tags: tags),
          body: renderMarkdownAsRichText(markdown)),
        chips: [])
    }
    let bare = body(subtitle: "", tags: [])
    XCTAssertGreaterThan(bare.length, 0, "the sample rendered to nothing")
    XCTAssertTrue(
      body(subtitle: "May 20 · 30 min", tags: ["a", "b", "c"]).isEqual(to: bare),
      "a subtitle and tags reached the reading surface — they can change its height again")
    XCTAssertTrue(
      body(subtitle: "May 20 · 51 min", tags: Array(repeating: "tag", count: 20))
        .isEqual(to: bare),
      "the document's metadata grew the body; that is the loop that shook")

    let pane = Self.uiSource("MainPaneView.swift")
    var offenders: [String] = []
    for (index, line) in pane.split(separator: "\n", omittingEmptySubsequences: false)
      .enumerated() {
      let text = line.trimmingCharacters(in: .whitespaces)
      guard !text.hasPrefix("//") else { continue }
      if text.contains("DocumentHeaderView(") || text.contains(".ground(.rail))") {
        offenders.append("MainPaneView.swift:\(index + 1) \(text)")
      }
    }
    XCTAssertEqual(
      offenders, [], "a pinned band is back above the transcript: \(offenders)")
  }

  /// **The title is the document's first line, in the reading column, at full
  /// ink.**
  ///
  /// Three claims, all about the one run: it opens the body, it is set at the
  /// H1 face (the `# ` heading it literally is in the markdown), and it is
  /// drawn at `GroundInk.Tier.body` — the tier the pinned title used, and the
  /// only tier at full alpha. It carries **no** `.notaTimestamp`, because it is
  /// not a transcript line and hovering it must reveal nothing in the gutter.
  func testTheTitleOpensTheBodyInTheReadingFaceAndFullInk() {
    let rendered = Self.paneBody(Self.sample)
    let text = rendered.string as NSString
    XCTAssertTrue(
      text.hasPrefix("Meeting\n"),
      "the document does not open with its title; it opens \"\(text.substring(to: min(40, text.length)))\"")

    let font = rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    XCTAssertEqual(font?.pointSize ?? 0, NSFonts.readingH1.pointSize, accuracy: 0.01)
    XCTAssertEqual(
      rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
      GroundInk.nsColor(.body),
      "the title is drawn in something other than the full-ink tier")
    XCTAssertNil(
      rendered.attribute(.notaTimestamp, at: 0, effectiveRange: nil),
      "the title carries a timestamp — the hover gutter would answer on it")

    // …and exactly once. The renderer skips whichever `# ` line
    // `parseDocumentMeta` took, so the title cannot also appear in the body.
    XCTAssertEqual(
      text.components(separatedBy: "Meeting").count - 1, 1,
      "the title is drawn twice — the pane and the renderer are both claiming it")
  }

  /// **A tag pill is one width whether or not the pointer is on it** (P-C4).
  ///
  /// The × used to be an element of the pill's `HStack`, inserted on hover, so
  /// the pill widened by ~10pt the instant the pointer landed on it — and the
  /// chips sit in a `FlowLayout`, so a hover near a line break pushed later
  /// chips onto the next line. That is the moment tally's rule (a control may
  /// not move under the pointer) on the one control the pointer has to reach,
  /// and the fix is the tally's mechanism: an overlay, reserving nothing.
  ///
  /// Shaped after `testTheNumberOfMomentsNeverMovesStop` — lay the same view
  /// out in both states and require the same geometry.
  @MainActor
  func testATagPillIsTheSameWidthHoveredAndNot() {
    func width(hovering: Bool) -> CGFloat {
      let host = NSHostingView(
        rootView: RemovableTagChip(tag: "roadmap", onRemove: {}, hovering: hovering))
      host.layoutSubtreeIfNeeded()
      return host.fittingSize.width
    }
    let rest = width(hovering: false)
    XCTAssertGreaterThan(rest, 0, "the hosting view produced no layout")
    XCTAssertEqual(
      width(hovering: true), rest, accuracy: 0.5,
      "the pill changed width on hover — the × is back in the layout, and every "
        + "chip after it on the row moves when the pointer arrives")
  }

  /// **A speaker suggestion is the only chip state that asks anything.**
  ///
  /// Putting the chips behind a button costs exactly one thing: they are the
  /// naming workflow, not metadata. A chip holding a suggestion is Nota asking
  /// "Speaker 2 → Kenny Kim? 0.62", and it asks once, when the transcription
  /// lands. Behind a panel nobody opens, that question is never seen. An
  /// unnamed speaker is not a question — nothing is waiting on an answer.
  ///
  /// This is now the speaker HALF of the merged dot rule below.
  func testASpeakerSuggestionIsTheOnlyChipStateThatAsksAnything() {
    let pending = SpeakerSuggestion(
      label: "Speaker 2", suggestedName: "Kenny Kim", score: 0.62, state: "pending")

    XCTAssertFalse(DocumentInfoBadge.hasPendingDecision(chips: []))
    XCTAssertFalse(
      DocumentInfoBadge.hasPendingDecision(chips: [
        SpeakerChip(label: "Speaker 1", name: "", indicator: .none),
        SpeakerChip(label: "Speaker 2", name: "Alice", indicator: .enrolled),
      ]),
      "an unnamed speaker is not a question — nothing is waiting on an answer")
    XCTAssertTrue(
      DocumentInfoBadge.hasPendingDecision(chips: [
        SpeakerChip(label: "Speaker 1", name: "Alice", indicator: .enrolled),
        SpeakerChip(label: "Speaker 2", name: "", indicator: .none, suggestion: pending),
      ]),
      "a pending suggestion went unannounced behind a closed panel")
  }

  /// **One dot, two claimants, and the label says which.**
  ///
  /// The Summary button carried a stale-summary dot and the info toggle carried
  /// a speaker-suggestion dot; merging them into one Details button must not
  /// merge away either question. So the dot lights for both and the string the
  /// tooltip and VoiceOver share names whichever is waiting — both, when both
  /// are.
  ///
  /// Asserted on the rule rather than on a rendered control, for the reason
  /// `RecordingPaneTests` already records: SwiftUI publishes no accessibility
  /// tree for a hosting view in an unhosted test bundle, so walking it cannot
  /// answer this. `DocumentInfoBadge` is pure, so there is nothing to walk.
  func testTheDetailsDotNamesWhichDecisionIsWaiting() {
    let pending = SpeakerSuggestion(
      label: "Speaker 2", suggestedName: "Kenny Kim", score: 0.62, state: "pending")
    let quiet = [SpeakerChip(label: "Speaker 1", name: "Alice", indicator: .enrolled)]
    let asking = quiet + [
      SpeakerChip(label: "Speaker 2", name: "", indicator: .none, suggestion: pending),
    ]

    // Nothing waiting: no dot, and the button says only what it is.
    XCTAssertNil(DocumentInfoBadge.waiting(chips: quiet, isSummaryOutdated: false))
    XCTAssertEqual(DocumentInfoBadge.label(nil), "Details")

    // Each claimant alone lights the one dot and names ITSELF.
    XCTAssertEqual(DocumentInfoBadge.waiting(chips: asking, isSummaryOutdated: false), .speaker)
    XCTAssertEqual(DocumentInfoBadge.waiting(chips: quiet, isSummaryOutdated: true), .summary)
    XCTAssertTrue(DocumentInfoBadge.label(.speaker).contains("speaker"))
    XCTAssertTrue(DocumentInfoBadge.label(.summary).contains("summary"))
    XCTAssertFalse(DocumentInfoBadge.label(.speaker).contains("summary"),
      "the dot named the wrong waiting decision")

    // Both: still one dot, and the label names BOTH — a merged button that
    // reports only the first thing waiting hides the second one for good.
    XCTAssertEqual(DocumentInfoBadge.waiting(chips: asking, isSummaryOutdated: true), .both)
    XCTAssertTrue(DocumentInfoBadge.label(.both).contains("speaker"))
    XCTAssertTrue(DocumentInfoBadge.label(.both).contains("summary"))

    // An unnamed speaker with no suggestion is not a question either.
    XCTAssertNil(DocumentInfoBadge.waiting(
      chips: [SpeakerChip(label: "Speaker 1", name: "", indicator: .none)],
      isSummaryOutdated: false))
  }

  // MARK: - The type

  /// Headings get room **above** them, which the pane never had: only
  /// `paragraphSpacing` (after) was ever set, so a section title sat on the last
  /// line of the paragraph before it.
  ///
  /// Read off the **foreign** sample: a Nota export's own headings are all
  /// above `## Full Transcript` and no longer reach the body at all, so the
  /// only documents that still draw one are the imported ones.
  func testHeadingsCarrySpaceAboveThem() {
    let rendered = renderMarkdownAsRichText(Self.foreign)
    let text = rendered.string as NSString
    let range = text.range(of: "Chapter one")
    XCTAssertNotEqual(range.location, NSNotFound, "the sample lost its heading")

    let style = rendered.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
      as? NSParagraphStyle
    XCTAssertEqual(
      style?.paragraphSpacingBefore ?? 0, Metrics.paraSpacingBeforeH2, accuracy: 0.5,
      "the heading has nothing above it")
    XCTAssertGreaterThan(
      style?.paragraphSpacingBefore ?? 0, style?.paragraphSpacing ?? .greatestFiniteMagnitude,
      "a heading needs more room above than below — that is what groups it with what it introduces")
  }

  /// A turn ends visibly. It used to be 5pt against 2pt of line spacing, so one
  /// speaker's turn and the next line looked the same distance apart.
  func testATurnIsSeparatedFromTheNextByMoreThanItsOwnLeading() {
    let rendered = renderMarkdownAsRichText(Self.sample)
    let range = (rendered.string as NSString).range(of: "Brian Demsky")
    XCTAssertNotEqual(range.location, NSNotFound)
    let style = rendered.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
      as? NSParagraphStyle
    XCTAssertEqual(style?.paragraphSpacing ?? 0, Metrics.paraSpacingTranscript, accuracy: 0.5)
    XCTAssertGreaterThan(
      style?.paragraphSpacing ?? 0, style?.lineSpacing ?? .greatestFiniteMagnitude,
      "the gap between turns is no bigger than the gap inside one")
  }

  /// The speaker name stays a **label** while the body grows: small, semibold,
  /// interface face. It is the row's structure, not part of the sentence.
  func testTheSpeakerNameDoesNotGrowWithTheBody() {
    XCTAssertLessThan(NSFonts.readingSpeaker.pointSize, NSFonts.readingBody.pointSize)
    let rendered = renderMarkdownAsRichText(Self.sample)
    let range = (rendered.string as NSString).range(of: "Brian Demsky")
    let font = rendered.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
    XCTAssertEqual(font?.pointSize ?? 0, NSFonts.readingSpeaker.pointSize, accuracy: 0.01)
  }

  /// The heading is a real step above the body, not the old 1.29×.
  func testTheHeadingIsAClearStepAboveTheBody() {
    let step = NSFonts.readingH2.pointSize / NSFonts.readingBody.pointSize
    XCTAssertGreaterThanOrEqual(step, 1.35, "sections do not announce themselves at \(step)×")
  }

  /// The timestamp attributes survive all of it — the gutter and the XIA-429
  /// moment pips are both built from them.
  func testTimestampsStillRideOnTheText() {
    let rendered = renderMarkdownAsRichText(Self.sample)
    var stamps: [String] = []
    rendered.enumerateAttribute(
      .notaTimestamp, in: NSRange(location: 0, length: rendered.length)
    ) { value, _, _ in
      if let s = value as? String { stamps.append(s) }
    }
    XCTAssertEqual(stamps, ["0:03", "0:28", "0:31"])
  }

  // MARK: - The rest of the surface the ground carries

  /// **The empty / in-progress pane is inked too.**
  ///
  /// It is the one screen an owner stares at for the whole length of a
  /// transcription, and `MainPaneView` draws it straight on
  /// `FieldBackground(role: .transcript)` — no glass, no card. Every glyph on it
  /// used to be `labelColor`/`secondaryLabelColor`/`tertiaryLabelColor`
  /// composited onto the moving field, while the transcript that replaces it a
  /// moment later was drawn entirely in solved ink.
  ///
  /// Asserted two ways, because neither alone is enough. The stage labels'
  /// three states are a pure mapping, so they are read off `stageTextStyle`
  /// directly — SwiftUI publishes no accessibility tree for a hosting view in
  /// this bundle, so a rendered pane cannot answer which tier a label took. And
  /// the *other* four call sites are plain modifiers with no function to ask, so
  /// the file itself is scanned: this is an adoption gap, and a gap is invisible
  /// to a test that only checks the values that are there.
  @MainActor
  func testTheRunningPaneIsInkedAndNotLabelled() {
    let running = EmptyMainView(
      state: EmptyMainState(
        isRunning: true, displayName: "standup.m4a", displayPath: "/tmp/standup.m4a",
        phase: RunStages.phaseLabels[1]),
      isDropTargeted: false)
    XCTAssertEqual(running.stageTextStyle(for: 0).tier, .speaker, "a finished stage")
    XCTAssertEqual(running.stageTextStyle(for: 1).tier, .body, "the stage that is running")
    XCTAssertEqual(running.stageTextStyle(for: 3).tier, .timestamp, "a stage still to come")

    let preparing = EmptyMainView(
      state: EmptyMainState(
        isRunning: true, displayName: "standup.m4a", displayPath: "/tmp/standup.m4a"),
      isDropTargeted: false)
    XCTAssertEqual(
      preparing.stageTextStyle(for: 0).tier, .timestamp,
      "nothing has started, so no stage may be drawn as the current one")

    let banned = [
      ".foregroundStyle(.primary", ".foregroundStyle(.secondary", ".foregroundStyle(.tertiary",
    ]
    var offenders: [String] = []
    for (index, line) in Self.uiSource("EmptyMainView.swift").split(
      separator: "\n", omittingEmptySubsequences: false
    ).enumerated() {
      let text = line.trimmingCharacters(in: .whitespaces)
      guard !text.hasPrefix("//") else { continue }
      if banned.contains(where: { text.contains($0) }) {
        offenders.append("EmptyMainView.swift:\(index + 1) \(text)")
      }
    }
    XCTAssertEqual(
      offenders, [],
      "the pane that sits bare on the ground is back on macOS label colours: \(offenders)")
  }

  /// **No hairline, and no `Divider()`, on the document surface.**
  ///
  /// This used to be a two-part test: the pinned title's darkest glyph measured
  /// against `GroundInkStyle(tier: .body)` and against `labelColor`, plus a
  /// source read for `Divider()`. The title half moved into the rendered body
  /// on 2026-09-02 and is asserted directly on the attributed string now
  /// (`testTheTitleOpensTheBodyInTheReadingFaceAndFullInk`) — reading the
  /// attribute beats measuring pixels when the attribute is what ships. The
  /// hairline it was divided from is gone with the band.
  ///
  /// What is left is the rule that outlives both: a hairline on this surface
  /// has no glyph to measure, so its call site is read. `Divider()` is
  /// `separatorColor` over the moving ground, on a surface whose own `---` rule
  /// already draws at the measured `.rail` tier.
  func testTheDocumentSurfaceDrawsNoDivider() {
    var dividers: [String] = []
    for line in Self.uiSource("MainPaneView.swift").split(
      separator: "\n", omittingEmptySubsequences: false
    ) {
      let text = line.trimmingCharacters(in: .whitespaces)
      if !text.hasPrefix("//"), text.contains("Divider()") { dividers.append(text) }
    }
    XCTAssertEqual(
      dividers, [],
      "the document surface drew a Divider() — that is separatorColor over the ground")
  }

  /// A UI source file, found relative to this test's own path. Same mechanism
  /// `RecordingStorageTests` uses for its fixture: the test target copies no
  /// resources, so a bundle lookup would silently resolve to nil.
  private static func uiSource(_ name: String) -> String {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent(name)
    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    XCTAssertFalse(text.isEmpty, "could not read \(name) beside this test")
    return text
  }
}
