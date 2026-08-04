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

  /// How dark the plate is cast, retinting the live material on assignment.
  ///
  /// The owner sets this (Dictation → Heads-Up Display → Glass opacity), so it
  /// can move while a panel is on screen; assigning it is the whole of applying
  /// it. Only the alpha is theirs — the hue is fixed, see `GlassTint`.
  var tintAlpha: Double = GlassTint.standard {
    didSet { glassView.tintColor = GlassTint.color(alpha: tintAlpha) }
  }

  init(inset: CGFloat) {
    self.inset = inset
    super.init(frame: .zero)
    wantsLayer = true
    // `.clear`, not `.regular`: regular is a frosted legibility plate that
    // reads as plain blur over most backdrops; clear lets the backdrop flow
    // through with the refractive rim — the "more transparent" the owner asked
    // for (2026-08-03). Legibility is carried by the tint below.
    glassView.style = .clear
    // Dark, deliberately, and it is the one thing carried over from the flat
    // fill this replaced. These panels sit over arbitrary content — a white
    // document as readily as a dark terminal — and their text is white. Untinted
    // regular glass over a bright background is bright, and white-on-bright is
    // the "washed out" failure the flat dark body was chosen to avoid. The tint
    // is weak enough that the refraction still reads as glass and strong enough
    // that the content never has to compete with what is behind it. How strong
    // is the owner's call within bounds that keep both halves of that true —
    // `GlassTint`, reassigned through `tintAlpha` whenever the setting moves.
    glassView.tintColor = GlassTint.color(alpha: tintAlpha)
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

}

// MARK: - Glass tint

/// The dark cast the floating surfaces' glass is given, as arithmetic.
///
/// `Color(white: 0.09).opacity(0.9)` was the flat body this replaced; the hue is
/// the same and is **not** adjustable — a tint that could move off neutral would
/// colour a surface whose only job is to let white text be read over an
/// arbitrary backdrop. What moves is the alpha, because the right weight is a
/// judgement about the owner's own screen and wallpaper: shipped at 0.35 with
/// the move to `.clear`, and reported as "a little too see-through" the same
/// week (2026-08-03), which is what the setting exists to settle.
///
/// The bounds are what keep the setting from being able to break the surface.
/// Below `range.lowerBound` the tint stops carrying white text over a white
/// document — the washed-out failure the flat fill was originally chosen to
/// prevent. Above `upperBound` the refraction stops reading as glass at all and
/// the panel is that flat fill again. Every value in between is a look; neither
/// end is.
enum GlassTint {
  /// Fixed. Only the alpha is the owner's.
  static let hue: CGFloat = 0.06

  /// What the slider offers, and what a stored value is clamped to.
  static let range: ClosedRange<Double> = 0.20...0.90

  /// The default, and the answer for a value that is not a number at all.
  static let standard: Double = 0.55

  static func clamped(_ alpha: Double) -> Double {
    guard alpha.isFinite else { return standard }
    return min(max(alpha, range.lowerBound), range.upperBound)
  }

  static func color(alpha: Double) -> NSColor {
    NSColor(white: hue, alpha: CGFloat(clamped(alpha)))
  }
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
