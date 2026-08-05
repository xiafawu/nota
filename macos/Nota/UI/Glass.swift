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
  let prominent: Bool
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    if reduceTransparency {
      content.buttonStyle(prominent ? AnyPrimitiveButtonStyle(.borderedProminent) : AnyPrimitiveButtonStyle(.bordered))
    } else {
      content.buttonStyle(prominent ? AnyPrimitiveButtonStyle(.glassProminent) : AnyPrimitiveButtonStyle(.glass))
    }
  }
}

/// A type-erased `PrimitiveButtonStyle` so one modifier can pick between the
/// plain and prominent styles at runtime. `buttonStyle(_:)` is generic over
/// the style, so the two arms would otherwise be different types and could
/// not be chosen with a ternary.
private struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
  private let makeBodyClosure: (Configuration) -> AnyView

  init<S: PrimitiveButtonStyle>(_ style: S) {
    makeBodyClosure = { configuration in
      AnyView(style.makeBody(configuration: configuration))
    }
  }

  func makeBody(configuration: Configuration) -> some View {
    makeBodyClosure(configuration)
  }
}

/// A circular Liquid Glass button sized for a single icon — the shape ADR 0005
/// specifies for the bottom-right local cluster.
///
/// The glass has to come from the **button style**, not from a hand-drawn
/// `Circle().fill(.thinMaterial)` behind an icon: a material is a blur, glass
/// refracts, and only the style gives the pressed and hover states the rest of
/// the app's controls have. It also has to come from the style rather than a
/// `.liquidGlass(in: .circle)` background, or the shape would be painted at
/// the label's size while the style drew its own capsule around it.
/// Sized to match a **toolbar** item, not scaled up: the cluster is the same
/// class of control as History and Settings at the top right, only local, and
/// the two sets read as unrelated if they are different sizes. Toolbar items
/// are bare `Button`s at the default control size that the toolbar wraps in
/// its own glass, so the cluster takes the default control size too — an
/// earlier `.controlSize(.large)` here is what made them look like a
/// different kind of button.
private struct LocalClusterButtonModifier: ViewModifier {
  let prominent: Bool

  func body(content: Content) -> some View {
    content
      .buttonBorderShape(.circle)
      .modifier(LiquidGlassButtonModifier(prominent: prominent))
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

  func liquidGlassButton(prominent: Bool = false) -> some View {
    modifier(LiquidGlassButtonModifier(prominent: prominent))
  }

  /// Circular glass button for the bottom-right local cluster (ADR 0005).
  /// `prominent` is the accent-filled variant — used for the Summary button
  /// once a summary exists.
  func localClusterButton(prominent: Bool = false) -> some View {
    modifier(LocalClusterButtonModifier(prominent: prominent))
  }

  func dropTargetGlass(isTargeted: Bool) -> some View {
    modifier(DropTargetGlassModifier(isTargeted: isTargeted))
  }
}
