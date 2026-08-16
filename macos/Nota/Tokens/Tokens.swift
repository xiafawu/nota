import AppKit
import SwiftUI

enum Tokens {
  static let toolbarStatusTintOpacity: Double = 0.1
  static let primaryActionTintOpacity: Double = 0.15
  static let tagPillFillOpacity: Double = 0.12
  static let dropFallbackStrokeIdleOpacity: Double = 0.2
  static let emptyIconColorOpacity: Double = 0.85
  static let rowHoverWashOpacity: Double = 0.06
  static let rowPressedWashOpacity: Double = 0.12
  /// Residual opacity of body text where it dissolves under the document
  /// header once scrolled (0 = vanish, ~0.2 = ghost).
  static let docBodyFadeGhostOpacity: Double = 0.15

  static let toolbarStatusTint: Color = .secondary.opacity(toolbarStatusTintOpacity)
  static let primaryActionTint: Color = .accentColor.opacity(primaryActionTintOpacity)
  static let dropAccent: Color = .accentColor
  static let dropFallbackStrokeIdle: Color = .secondary.opacity(dropFallbackStrokeIdleOpacity)
  static let emptyIconColor: Color = .primary.opacity(emptyIconColorOpacity)
  static let tagPillFill: Color = .secondary.opacity(tagPillFillOpacity)

  static let statusFont: Font = .callout
  static let historyTitleFont: Font = .callout
  static let historyDateFont: Font = .caption2
  static let historySectionFont: Font = .caption
  static let historyTagFont: Font = .caption2
  static let emptyHistoryLabelFont: Font = .callout
  static let emptyHistoryHelperFont: Font = .caption
  static let emptyHistoryIconFont: Font = .system(size: 26, weight: .regular)
  static let emptyMainIconFont: Font = .system(size: 72, weight: .semibold)
  static let emptyMainTitleFont: Font = .title
  static let emptyMainPathFont: Font = .callout
  static let settingsCaptionFont: Font = .caption

  static let docTitleFont: Font = .title2
  static let docTitleCompactFont: Font = .headline
  static let docSubtitleFont: Font = .subheadline

  /// The live meeting pane's type now lives in `RecordingPaneMetrics` and
  /// `SessionTimerMetrics` (XIA-432): the timer's size is *derived* (it steps at
  /// the hour and the ring is sized from it), so a `liveMeetingTimerFont`
  /// constant here could only ever be a second opinion. The six fonts and the
  /// error wash this block held had no readers left after the rewrite.

  static let animFast: Animation = .easeInOut(duration: 0.2)
  static let animSnap: Animation = .easeInOut(duration: 0.15)
  static let hoverFadeDuration: Double = 0.18
}

/// Distinct per-speaker identity hues: the chip dot and the transcript speaker
/// name share one palette entry, assigned by chip order within the document.
enum SpeakerColors {
  static let nsPalette: [NSColor] = [
    .systemBlue, .systemGreen, .systemOrange, .systemPurple,
    .systemPink, .systemTeal, .systemIndigo, .systemBrown,
  ]

  static func nsColor(at index: Int) -> NSColor {
    nsPalette[((index % nsPalette.count) + nsPalette.count) % nsPalette.count]
  }

  static func color(at index: Int) -> Color {
    Color(nsColor: nsColor(at: index))
  }
}

enum NSFonts {
  static let codeBlock: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
  static let h1: NSFont = .boldSystemFont(ofSize: 26)
  static let h2: NSFont = .boldSystemFont(ofSize: 18)
  static let body: NSFont = .systemFont(ofSize: 14)
  static let separator: NSFont = .systemFont(ofSize: 13)
  static let timestamp: NSFont = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
  static let speaker: NSFont = .boldSystemFont(ofSize: 14)
  static let gutterTimestamp: NSFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

  // MARK: - The reading column (XIA-441)
  //
  // A separate scale rather than a change to the four above, because those are
  // read elsewhere and the document is the only surface that grew. **18.5 is
  // the owner's number**, dialled against the real ground on 2026-08-16, and it
  // is load-bearing beyond taste: at 18pt and up WCAG calls the text *large*,
  // which is what lets `GroundInk.Tier.reading` draw at 0.80 against a 4.5:1
  // bar instead of 7.0. Taking the size back down without taking the alpha up
  // puts the body under its bar.
  static let readingBody: NSFont = .systemFont(ofSize: 18.5)
  /// 1.4× the body, where the old pair was 18/14 — a 1.29 step that left
  /// section titles barely announcing themselves.
  static let readingH2: NSFont = .systemFont(ofSize: 26, weight: .semibold)
  static let readingH1: NSFont = .systemFont(ofSize: 32, weight: .bold)
  /// The speaker name is a **label**, not reading, so it stays small, semibold
  /// and set in the interface face even as the body grows. It is the row's
  /// structure rather than part of the sentence.
  static let readingSpeaker: NSFont = .systemFont(ofSize: 14, weight: .semibold)
  /// Mono, because the gutter is a column of times and they have to align.
  static let readingGutter: NSFont = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
}
