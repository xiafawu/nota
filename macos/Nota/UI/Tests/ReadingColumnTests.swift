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
    let rendered = renderMarkdownAsRichText(Self.sample)
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
    let rendered = renderMarkdownAsRichText(Self.sample)
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

  // MARK: - The type

  /// Headings get room **above** them, which the pane never had: only
  /// `paragraphSpacing` (after) was ever set, so a section title sat on the last
  /// line of the paragraph before it.
  func testHeadingsCarrySpaceAboveThem() {
    let rendered = renderMarkdownAsRichText(Self.sample)
    let text = rendered.string as NSString
    let range = text.range(of: "Key Topics")
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
}
