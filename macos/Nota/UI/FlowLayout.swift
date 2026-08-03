import SwiftUI

/// Wrapping layout for the expanded tag list: left-to-right, wrapping to a new
/// line when the next pill would exceed the available width. Originally lived
/// alongside the retired HistoryPaneView; the document header still uses it.
struct FlowLayout: Layout {
  var spacing: CGFloat = 4
  var lineSpacing: CGFloat = 4

  /// Measure a subview, re-proposing the available width when its ideal size
  /// would overflow it (e.g. a long topic chip), so the subview truncates or
  /// wraps instead of drawing past the container's trailing edge.
  private func fittedSize(of subview: LayoutSubview, maxWidth: CGFloat) -> CGSize {
    var size = subview.sizeThatFits(.unspecified)
    if size.width > maxWidth {
      size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
      size.width = min(size.width, maxWidth)
    }
    return size
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    var x: CGFloat = 0
    var y: CGFloat = 0
    var lineHeight: CGFloat = 0
    var widestRow: CGFloat = 0

    for subview in subviews {
      let size = fittedSize(of: subview, maxWidth: maxWidth)
      if x > 0, x + size.width > maxWidth {
        widestRow = max(widestRow, x - spacing)
        x = 0
        y += lineHeight + lineSpacing
        lineHeight = 0
      }
      x += size.width + spacing
      lineHeight = max(lineHeight, size.height)
    }
    widestRow = max(widestRow, x - spacing)
    let width = maxWidth.isFinite ? min(widestRow, maxWidth) : widestRow
    return CGSize(width: max(width, 0), height: y + lineHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var lineHeight: CGFloat = 0

    for subview in subviews {
      let size = fittedSize(of: subview, maxWidth: bounds.width)
      if x > 0, x + size.width > bounds.width {
        x = 0
        y += lineHeight + lineSpacing
        lineHeight = 0
      }
      subview.place(
        at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
        anchor: .topLeading,
        proposal: ProposedViewSize(size)
      )
      x += size.width + spacing
      lineHeight = max(lineHeight, size.height)
    }
  }
}
