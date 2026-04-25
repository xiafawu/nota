import SwiftUI

private struct LiquidGlassModifier<S: Shape>: ViewModifier {
  let glass: Glass
  let shape: S
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    if reduceTransparency {
      content.background(.regularMaterial, in: shape)
    } else {
      content.glassEffect(glass, in: shape)
    }
  }
}

private struct LiquidGlassButtonModifier: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    if reduceTransparency {
      content.buttonStyle(.bordered)
    } else {
      content.buttonStyle(.glass)
    }
  }
}

private struct DropTargetGlassModifier: ViewModifier {
  let isTargeted: Bool
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    if reduceTransparency {
      content
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Metrics.dropCornerRadius))
        .overlay(
          RoundedRectangle(cornerRadius: Metrics.dropCornerRadius)
            .strokeBorder(isTargeted ? Tokens.dropAccent : Tokens.dropFallbackStrokeIdle, lineWidth: isTargeted ? Metrics.dropStrokeActive : Metrics.dropStrokeIdle)
        )
    } else if isTargeted {
      content.glassEffect(.clear.tint(Tokens.dropAccent), in: RoundedRectangle(cornerRadius: Metrics.dropCornerRadius))
    } else {
      content.glassEffect(.clear, in: RoundedRectangle(cornerRadius: Metrics.dropCornerRadius))
    }
  }
}

extension View {
  func liquidGlass<S: Shape>(_ glass: Glass = .regular, in shape: S) -> some View {
    modifier(LiquidGlassModifier(glass: glass, shape: shape))
  }

  func liquidGlassButton() -> some View {
    modifier(LiquidGlassButtonModifier())
  }

  func dropTargetGlass(isTargeted: Bool) -> some View {
    modifier(DropTargetGlassModifier(isTargeted: isTargeted))
  }
}
