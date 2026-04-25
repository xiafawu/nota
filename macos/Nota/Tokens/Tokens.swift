import AppKit
import SwiftUI

enum Tokens {
  static let toolbarStatusTintOpacity: Double = 0.1
  static let primaryActionTintOpacity: Double = 0.15
  static let dropFallbackStrokeIdleOpacity: Double = 0.2
  static let emptyIconColorOpacity: Double = 0.85

  static let toolbarStatusTint: Color = .secondary.opacity(toolbarStatusTintOpacity)
  static let primaryActionTint: Color = .accentColor.opacity(primaryActionTintOpacity)
  static let dropAccent: Color = .accentColor
  static let dropFallbackStrokeIdle: Color = .secondary.opacity(dropFallbackStrokeIdleOpacity)
  static let emptyIconColor: Color = .primary.opacity(emptyIconColorOpacity)

  static let statusFont: Font = .callout
  static let historyTitleFont: Font = .callout
  static let historyDateFont: Font = .caption2
  static let historySectionFont: Font = .caption
  static let emptyHistoryLabelFont: Font = .callout
  static let emptyHistoryHelperFont: Font = .caption
  static let emptyHistoryIconFont: Font = .system(size: 26, weight: .regular)
  static let emptyMainIconFont: Font = .system(size: 72, weight: .semibold)
  static let emptyMainTitleFont: Font = .title
  static let emptyMainPathFont: Font = .callout
  static let settingsCaptionFont: Font = .caption

  static let animFast: Animation = .easeInOut(duration: 0.2)
  static let animSnap: Animation = .easeInOut(duration: 0.15)
}

enum NSFonts {
  static let codeBlock: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
  static let h1: NSFont = .boldSystemFont(ofSize: 26)
  static let h2: NSFont = .boldSystemFont(ofSize: 18)
  static let body: NSFont = .systemFont(ofSize: 14)
  static let separator: NSFont = .systemFont(ofSize: 13)
  static let timestamp: NSFont = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
  static let speaker: NSFont = .boldSystemFont(ofSize: 14)
}
