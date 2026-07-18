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
}
