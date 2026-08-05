import CoreGraphics
import Foundation

/// Layout rules for the summary rail (XIA-415, decisions 1-3).
///
/// The rail has one size: fixed 380pt width, full height minus the host's
/// insets, anchored bottom-right. The old compact/expanded states, the
/// divider drag, and the 92 / 260 / 360pt heights are retired along with the
/// inline enrichment slot; `preview(for:)` went with them (nothing renders a
/// truncated preview anymore — the rail scrolls).
enum SummaryDrawerLayout {
  /// Fixed rail width, matching the history drawer's 380pt (decision 1).
  static let railWidth: CGFloat = 380
}
