import CoreGraphics
import Foundation

/// Pure sizing and preview rules for the transcript summary drawer.
///
/// Keeping these rules out of the view makes the small-window guarantees
/// explicit and gives the UI test target a cheap way to cover the bounds.
enum SummaryDrawerLayout {
  static let compactHeight: CGFloat = 92
  static let expandedMinHeight: CGFloat = 176
  static let expandedDefaultHeight: CGFloat = 260
  static let expandedAbsoluteMaxHeight: CGFloat = 360
  static let transcriptMinimumHeight: CGFloat = 160
  static let previewCharacterLimit = 240

  /// A short, whitespace-normalized preview that does not cut a word in half
  /// when the narrative is longer than the compact drawer can show.
  static func preview(for narrative: String) -> String {
    let normalized = narrative
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard normalized.count > previewCharacterLimit else { return normalized }

    let prefix = normalized.prefix(previewCharacterLimit + 1)
    if let breakpoint = prefix.lastIndex(of: " ") {
      return String(prefix[..<breakpoint]) + "…"
    }
    return String(normalized.prefix(previewCharacterLimit)) + "…"
  }

  /// Caps the expanded drawer to a modest fraction of the available window
  /// while reserving a minimum readable transcript viewport. The floor relaxes
  /// for unusually short windows so the drawer never exceeds its container.
  static func expandedMaxHeight(for availableHeight: CGFloat) -> CGFloat {
    let available = availableHeight.isFinite ? max(0, availableHeight) : 0
    let spaceCap = max(0, available - transcriptMinimumHeight)
    let safeFloor = min(expandedMinHeight, spaceCap)
    let proportionalCap = available * 0.42
    let preferred = max(safeFloor, min(proportionalCap, spaceCap))
    return min(expandedAbsoluteMaxHeight, preferred)
  }

  static func clampedExpandedHeight(
    _ height: CGFloat,
    availableHeight: CGFloat
  ) -> CGFloat {
    let maximum = expandedMaxHeight(for: availableHeight)
    let minimum = min(expandedMinHeight, maximum)
    return min(max(height, minimum), maximum)
  }

  /// The expanded height for a divider drag, computed from the height and
  /// pointer position captured when the drag began. Recomputed from the
  /// gesture anchor on every event (rather than accumulating deltas onto the
  /// current height) it is a pure function of the pointer position: the
  /// applied value never feeds back into the next measurement, so the drag
  /// stays monotonic, reversible, and stable against its own clamping.
  static func dragTargetHeight(
    startHeight: CGFloat,
    startY: CGFloat,
    currentY: CGFloat,
    availableHeight: CGFloat
  ) -> CGFloat {
    clampedExpandedHeight(
      startHeight + (currentY - startY),
      availableHeight: availableHeight
    )
  }
}
