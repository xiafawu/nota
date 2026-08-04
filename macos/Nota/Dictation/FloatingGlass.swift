import AppKit
import SwiftUI

// MARK: - GlassBackingView

/// Liquid Glass behind a floating panel's SwiftUI content.
///
/// **Why AppKit and not `.glassEffect` / `.liquidGlass`.** Measured on this
/// machine before either surface adopted it: a SwiftUI glass modifier inside a
/// transparent `NSPanel` renders as a flat blur. It refracts only what is inside
/// its own SwiftUI hierarchy, and a HUD's hierarchy is a mic glyph and a line of
/// text — so the material has nothing to bend and reads as grey frosting.
/// `NSGlassEffectView` is a real AppKit view with a window-server-side effect,
/// and it refracts the screen behind the panel, which is the entire point of
/// asking for glass on a floating surface.
///
/// **Why the content is a sibling and not `contentView`.** The header is explicit
/// that `NSGlassEffectView` guarantees placement only for its own `contentView`
/// and nothing about arbitrary subviews. Handing it the hosting view would also
/// mean the hosting view inherits the glass's inset frame — and the hosting view
/// already carries `shadowMargin` of transparent padding of its own, which is
/// what every pinned fitting-size baseline is measured with. So the glass is laid
/// out at the *card* rect (bounds inset by that margin) and the hosting view sits
/// above it at full bounds: the content lands exactly where it always did, the
/// glass lands exactly under it, and not one measured number moves.
///
/// The glass never takes a click (`GlassPlateView.hitTest` returns nil). The HUD
/// claims every point for its drag handle and the review card must let a drag
/// inside its text view select text; neither can afford a material intercepting
/// events.
class GlassBackingView: NSView {
  /// The material. Exposed so a panel can tint or restyle it per state.
  let glassView = GlassPlateView()

  /// Transparent room between the window's edge and the glass, where the
  /// surface's shadow falls. A window cannot draw outside its own frame.
  private let inset: CGFloat

  /// Corner curvature of the glass, in points. Clamped to a capsule at layout
  /// time, so a style may ask for "as round as possible" by passing a large
  /// number.
  var glassCornerRadius: CGFloat = 16 {
    didSet { needsLayout = true }
  }

  /// Whether the material is drawn at all. False for a hidden HUD, whose SwiftUI
  /// content collapses to nothing while the window frame stays put — without
  /// this the panel would be a bare pane of glass with no content on it.
  var showsGlass: Bool = true {
    didSet { glassView.isHidden = !showsGlass }
  }

  init(inset: CGFloat) {
    self.inset = inset
    super.init(frame: .zero)
    wantsLayer = true
    glassView.style = .regular
    // Dark, deliberately, and it is the one thing carried over from the flat
    // fill this replaced. These panels sit over arbitrary content — a white
    // document as readily as a dark terminal — and their text is white. Untinted
    // regular glass over a bright background is bright, and white-on-bright is
    // the "washed out" failure the flat dark body was chosen to avoid. The tint
    // is weak enough that the refraction still reads as glass and strong enough
    // that the content never has to compete with what is behind it.
    glassView.tintColor = Self.tint
    addSubview(glassView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// The SwiftUI content, added ABOVE the glass and filling the whole view —
  /// including the margin, because the padding that produces that margin lives
  /// inside the hosted view.
  func setContent(_ view: NSView) {
    view.frame = bounds
    view.autoresizingMask = [.width, .height]
    addSubview(view, positioned: .above, relativeTo: glassView)
    autoresizesSubviews = true
  }

  override func layout() {
    super.layout()
    let card = bounds.insetBy(dx: inset, dy: inset)
    guard card.width > 0, card.height > 0 else {
      glassView.frame = .zero
      return
    }
    glassView.frame = card
    glassView.cornerRadius = min(glassCornerRadius, min(card.width, card.height) / 2)
  }

  /// The dark cast the glass is given. `Color(white: 0.09).opacity(0.9)` was the
  /// flat body; this is the same hue at the weight a refracting material can
  /// carry without becoming the flat body again.
  static let tint = NSColor(white: 0.06, alpha: 0.55)
}

// MARK: - GlassPlateView

/// `NSGlassEffectView` that takes no clicks.
///
/// It is a sibling *under* the content, so any point it swallowed would be a
/// point the HUD could not be dragged by or the review card's editor could not
/// be selected in.
final class GlassPlateView: NSGlassEffectView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Glass metrics

/// Corner curvature for the dictation surfaces' glass, as arithmetic.
///
/// The material is an AppKit view and cannot take a `Shape`, so the curvature
/// each SwiftUI style used to draw has to be restated as one number. Pure, so
/// the restatement is asserted against the shapes' own constants rather than
/// eyeballed.
enum HUDGlassMetrics {
  /// The pill is a `Capsule` in its ordinary states and a 20pt continuous
  /// rectangle in the two that wrap to a second line (see `HUDPillShape`) — a
  /// capsule's end caps grow with height, and a two-line capsule is a lozenge.
  static let pillCappedCornerRadius: CGFloat = 20

  /// Radius of the glass under `style`, in `state`, for a card `cardHeight`
  /// points tall.
  ///
  /// `GlassBackingView` clamps to a capsule anyway; the pill asks for half its
  /// own height so the intent is legible here rather than only in the clamp.
  static func cornerRadius(
    style: HUDStyle,
    state: HUDState,
    cardHeight: CGFloat
  ) -> CGFloat {
    switch style {
    case .bar:
      return HUDBarMetrics.cornerRadius
    case .prompter:
      return HUDPrompterMetrics.cornerRadius
    case .pill:
      switch state {
      case .warning, .error:
        return min(pillCappedCornerRadius, cardHeight / 2)
      default:
        return cardHeight / 2
      }
    }
  }
}
