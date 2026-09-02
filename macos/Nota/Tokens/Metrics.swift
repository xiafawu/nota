import CoreGraphics
import Foundation

enum Metrics {
  static let statusPillH: CGFloat = 10
  static let statusPillV: CGFloat = 4
  static let statusHStackSpacing: CGFloat = 6

  static let newButtonH: CGFloat = 12
  static let newButtonV: CGFloat = 10
  static let newButtonStackSpacing: CGFloat = 8
  static let primaryActionCornerRadius: CGFloat = 10

  static let historyEmptyHorizontalPadding: CGFloat = 16
  static let historyRowVerticalPadding: CGFloat = 2
  static let emptyHistoryStackSpacing: CGFloat = 8

  static let emptySubtextHorizontalPadding: CGFloat = 24
  static let emptyMainOuterPadding: CGFloat = 40
  static let emptyMainSpacing: CGFloat = 24
  static let emptyTextSpacing: CGFloat = 10

  static let windowMinWidth: CGFloat = 780
  static let windowMinHeight: CGFloat = 560
  // The settings window's own size and a split view's column widths used to be
  // declared here and were read by nothing: `SettingsView` sizes itself, and no
  // `NavigationSplitView` has ever existed in this app. Seven numbers that
  // looked like the answer to "how wide is the sidebar" and were not (P-D5).

  static let richTextInsetX: CGFloat = 20
  static let richTextInsetY: CGFloat = 18

  // Left reading margin doubles as the hover-timestamp gutter for transcript lines.
  static let gutterWidth: CGFloat = 48
  static let tsGutterTrailingGap: CGFloat = 8

  static let docHeaderTopPadding: CGFloat = 16
  static let docHeaderBottomPadding: CGFloat = 12
  static let docHeaderSpacing: CGFloat = 6

  static let dropCornerRadius: CGFloat = 20
  static let dropFullBleedCornerRadius: CGFloat = 0
  static let dropStrokeIdle: CGFloat = 1
  static let dropStrokeActive: CGFloat = 2
  static let dropTargetStrokeWidth: CGFloat = 3

  // MARK: - The reading column (XIA-441)
  //
  // Every number below moved once, together, and the ones that did not exist
  // before are the interesting half: nothing in the document path had ever set
  // a measure cap or space *above* a heading, so the pane inherited whatever
  // the window was and ran section titles straight into the paragraph above.

  /// **The cap on line length**, in ems of the reading face, applied to the
  /// text container rather than to the insets — a wider inset moves the column
  /// left, a container width centres it.
  ///
  /// The pane had none: `widthTracksTextView` plus a 48pt inset means a
  /// 1400pt window draws 140-character lines, which is most of what "it looks
  /// like a text editor" was. 34em at 18.5pt is ~74 characters at the face's
  /// average advance, inside the 45–75 band every reference in the study sits
  /// in.
  static let readingMeasureEms: CGFloat = 34
  static var readingMeasure: CGFloat { readingMeasureEms * NSFonts.readingBody.pointSize }

  static let paraSpacingTight: CGFloat = 4
  /// The gap between one speaker's turn and the next. Was 5 — barely more than
  /// `lineSpacingDefault`, so a turn never visibly ended and the transcript
  /// read as one wall.
  static let paraSpacingTranscript: CGFloat = 15
  static let paraSpacingH2: CGFloat = 12
  static let paraSpacingH1: CGFloat = 14
  /// Space **above** a heading, which had no representation at all: only
  /// `paragraphSpacing` (after) was ever set, so `## Key Topics` sat on the
  /// last line of the paragraph before it. A heading needs more room above than
  /// below — that is what groups it with what it introduces.
  static let paraSpacingBeforeH2: CGFloat = 34
  static let paraSpacingBeforeH1: CGFloat = 38
  /// Leading for the reading column: 18.5pt body at ~1.62 wants ~11pt of extra
  /// lead over the font's own line height. The old value of 2 made 1.36, which
  /// is tight for a page of prose and very tight over a moving ground.
  static let lineSpacingReading: CGFloat = 11
  static let lineSpacingDefault: CGFloat = 2
  static let bulletHeadIndent: CGFloat = 22

  static let tightStackSpacing: CGFloat = 2

  static let tagPillH: CGFloat = 8
  static let tagPillV: CGFloat = 3

  /// The clickable rectangle under a chip-scale glyph — a tag's ×, a
  /// suggestion's accept/dismiss, the drawer row's pin (P-C3). Those glyphs are
  /// 7–11pt and were their own hit targets; the glyph size is unchanged and
  /// only the rectangle grows. 18 rather than the 22 the window's close buttons
  /// use, because these sit inside rows and pills the close buttons do not.
  static let chipHitTarget: CGFloat = 18
  static let tagSpacing: CGFloat = 4
  static let tagTopPadding: CGFloat = 4
  static let tagToggleIconSpacing: CGFloat = 2

  // One card vocabulary on the home surface: section cards vs. row elements.
  static let cardCornerRadius: CGFloat = 12
  static let rowCornerRadius: CGFloat = 8
  static let cardPadding: CGFloat = 16

  static let speakerDotSize: CGFloat = 6
  static let speakerPopoverFieldWidth: CGFloat = 180

  // Body top fade.
  static let docBodyTopFadeHeight: CGFloat = 28
  /// Where the body's top fade turns on. One threshold, and it may stay one:
  /// the fade changes no layout, so unlike the header collapse it replaced
  /// (XIA-441 — two thresholds and a range floor, all deleted with the card)
  /// it cannot move the offset that decides it.
  static let docBodyFadeThreshold: CGFloat = 4

  // The live meeting pane's own numbers now live in `RecordingPaneMetrics`
  // (XIA-432): the pane is a two-column arrangement with a derived ring and a
  // derived fold, and six loose paddings here had no readers left. Anything the
  // recording surface lays out with belongs beside the arithmetic that derives
  // it, not in the general token table.

  // Staged run progress (validate → transcribe → summarize → write).
  static let stageRowSpacing: CGFloat = 16
  static let stageItemSpacing: CGFloat = 5
  static let stageIndicatorSize: CGFloat = 13
  static let mainSwapRise: CGFloat = 8
}
