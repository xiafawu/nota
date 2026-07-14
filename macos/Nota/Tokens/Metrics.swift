import CoreGraphics
import Foundation

enum Metrics {
  static let statusPillH: CGFloat = 10
  static let statusPillV: CGFloat = 4
  static let statusHStackSpacing: CGFloat = 6

  static let newButtonH: CGFloat = 12
  static let newButtonV: CGFloat = 10
  static let newButtonOuterH: CGFloat = 10
  static let newButtonOuterTop: CGFloat = 10
  static let newButtonOuterBottom: CGFloat = 6
  static let newButtonStackSpacing: CGFloat = 8
  static let primaryActionCornerRadius: CGFloat = 10

  static let historyEmptyHorizontalPadding: CGFloat = 16
  static let historyRowVerticalPadding: CGFloat = 2
  static let emptyHistoryStackSpacing: CGFloat = 8

  static let emptySubtextHorizontalPadding: CGFloat = 24
  static let emptyMainOuterPadding: CGFloat = 40
  static let emptyMainSpacing: CGFloat = 24
  static let emptyTextSpacing: CGFloat = 10
  static let emptyProgressWidth: CGFloat = 220

  static let windowMinWidth: CGFloat = 780
  static let windowMinHeight: CGFloat = 560
  static let settingsWidth: CGFloat = 420
  static let settingsHeight: CGFloat = 160
  static let sidebarMin: CGFloat = 220
  static let sidebarIdeal: CGFloat = 260
  static let sidebarMax: CGFloat = 320
  static let detailMin: CGFloat = 520
  static let detailIdeal: CGFloat = 720

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

  static let paraSpacingTight: CGFloat = 4
  static let paraSpacingTranscript: CGFloat = 5
  static let paraSpacingH2: CGFloat = 8
  static let paraSpacingH1: CGFloat = 10
  static let lineSpacingDefault: CGFloat = 2
  static let bulletHeadIndent: CGFloat = 18

  static let tightStackSpacing: CGFloat = 2

  static let tagPillH: CGFloat = 8
  static let tagPillV: CGFloat = 3
  static let tagSpacing: CGFloat = 4
  static let tagTopPadding: CGFloat = 4
  static let tagToggleIconSpacing: CGFloat = 2
  static let maxVisibleTags: Int = 3
}
