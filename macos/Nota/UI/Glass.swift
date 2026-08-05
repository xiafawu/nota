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

/// Applies one of four button styles by branching in a `@ViewBuilder`, never
/// by type-erasing the style itself.
///
/// A hand-rolled `AnyPrimitiveButtonStyle` was tried here so a ternary could
/// pick between the plain and prominent glass, and it silently cost the glass:
/// re-implementing `makeBody` to return an `AnyView` hands SwiftUI an opaque
/// view where it expected a style it can recognise, and the window server's
/// glass is attached from the recognised style rather than from anything in
/// the returned hierarchy. It failed *selectively*, which is what made it hard
/// to see — the `Button` still looked plausibly styled while the `Menu` beside
/// it rendered no chrome at all.
///
/// Branching produces four different concrete types, which is exactly why the
/// erasure was reached for; `@ViewBuilder` accepts them because each branch is
/// its own arm of the result builder's generated enum.
private struct LiquidGlassButtonModifier: ViewModifier {
  let prominent: Bool
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  @ViewBuilder
  func body(content: Content) -> some View {
    if reduceTransparency {
      if prominent {
        content.buttonStyle(.borderedProminent)
      } else {
        content.buttonStyle(.bordered)
      }
    } else {
      if prominent {
        content.buttonStyle(.glassProminent)
      } else {
        content.buttonStyle(.glass)
      }
    }
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
/// Sized to match a **toolbar** item: the cluster is the same class of control
/// as History and Settings at the top right, only local, and the two sets read
/// as unrelated if they are different sizes.
///
/// `.large` is not a decoration. A toolbar applies its own metrics to the bare
/// `Button`s it is given, so "default control size" in the content area is
/// visibly *smaller* than the same button in a toolbar — matching the toolbar
/// means asking for the larger size explicitly, not omitting the modifier.
///
/// The glass is drawn **directly**, with `.glassEffect(_:in:)` over a `.plain`
/// control — not asked for via `.buttonStyle(.glass)`.
///
/// `.buttonStyle(.glass)` paints glass only when SwiftUI resolves the control
/// as a button. A `Menu` goes through menu plumbing instead, so the style is
/// advisory there even after `.menuStyle(.button)`: Share rendered as a stock
/// grey pull-down while the Summary `Button` beside it took the glass. Two
/// controls, one modifier, one of them a no-op — and no amount of reordering
/// the chain fixes it, because the difference is in who resolves the style,
/// not in what the style says.
///
/// Drawing the plate removes that dependency: `.plain` guarantees neither
/// control brings chrome of its own, and the effect is attached to the view
/// rather than negotiated with a style resolver.
///
/// The diameter is fixed rather than derived from `controlSize`, for the same
/// reason: a toolbar applies its own metrics to the items it is given, so
/// nothing in the content area matches it by asking for a size by name.
enum LocalCluster {
  /// Matches the diameter a macOS 26 toolbar gives its glass items.
  static let diameter: CGFloat = 30
}

private struct LocalClusterButtonModifier: ViewModifier {
  let prominent: Bool
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  @ViewBuilder
  func body(content: Content) -> some View {
    let base = content
      .menuStyle(.button)
      .buttonStyle(.plain)
      .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
      .frame(width: LocalCluster.diameter, height: LocalCluster.diameter)
      .contentShape(.circle)

    if reduceTransparency {
      if prominent {
        base.background(Color.accentColor, in: .circle)
      } else {
        base.background(.regularMaterial, in: .circle)
      }
    } else if prominent {
      base.glassEffect(.regular.tint(.accentColor).interactive(), in: .circle)
    } else {
      base.glassEffect(.regular.interactive(), in: .circle)
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
