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
    didSet {
      glassView.isHidden = !showsGlass
      tintView.isHidden = !showsGlass
    }
  }

  /// The tint, drawn by us and not by the material (see `tintView`).
  let tintView = TintOverlayView()

  /// How dark the plate is cast, redrawing the live tint on assignment.
  ///
  /// The owner sets this (Dictation → Heads-Up Display → Glass opacity), so it
  /// can move while a panel is on screen; assigning it is the whole of applying
  /// it. Only the alpha is theirs — the hue is fixed, see `GlassTint`.
  ///
  /// The tint is an overlay view of our own, NOT `NSGlassEffectView.tintColor`:
  /// the `.regular` material runs the tint through its own legibility
  /// treatment, and alpha moves that are obvious on `.clear` are invisible on
  /// frosted — measured 2026-08-03 as "the slider is not changing the pill's
  /// opacity if the material is frosted". An overlay we draw obeys the slider
  /// identically on both materials.
  var tintAlpha: Double = GlassTint.standard {
    didSet { tintView.alphaValue = CGFloat(GlassTint.clamped(tintAlpha)) }
  }

  /// Which of the two Liquid Glass materials the plate is, restyling the live
  /// view on assignment. Owner-set, same pathway as `tintAlpha`.
  var material: GlassMaterial = .standard {
    didSet { glassView.style = material.nsStyle }
  }

  init(inset: CGFloat) {
    self.inset = inset
    super.init(frame: .zero)
    wantsLayer = true
    glassView.style = material.nsStyle
    addSubview(glassView)
    // Dark, deliberately, and it is the one thing carried over from the flat
    // fill this replaced. These panels sit over arbitrary content — a white
    // document as readily as a dark terminal — and their text is white. Untinted
    // glass over a bright background is bright, and white-on-bright is the
    // "washed out" failure the flat dark body was chosen to avoid. The cast is
    // weak enough that the refraction still reads as glass and strong enough
    // that the content never has to compete with what is behind it. How strong
    // is the owner's call within bounds that keep both halves of that true —
    // `GlassTint`, applied through `tintAlpha` whenever the setting moves.
    tintView.wantsLayer = true
    tintView.layer?.backgroundColor = NSColor(white: GlassTint.hue, alpha: 1).cgColor
    tintView.alphaValue = CGFloat(GlassTint.clamped(tintAlpha))
    addSubview(tintView, positioned: .above, relativeTo: glassView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// The SwiftUI content, added ABOVE the glass and filling the whole view —
  /// including the margin, because the padding that produces that margin lives
  /// inside the hosted view.
  func setContent(_ view: NSView) {
    view.frame = bounds
    view.autoresizingMask = [.width, .height]
    addSubview(view, positioned: .above, relativeTo: tintView)
    autoresizesSubviews = true
  }

  override func layout() {
    super.layout()
    let card = bounds.insetBy(dx: inset, dy: inset)
    guard card.width > 0, card.height > 0 else {
      glassView.frame = .zero
      tintView.frame = .zero
      return
    }
    let radius = min(glassCornerRadius, min(card.width, card.height) / 2)
    glassView.frame = card
    glassView.cornerRadius = radius
    tintView.frame = card
    tintView.layer?.cornerRadius = radius
    tintView.layer?.cornerCurve = .continuous
  }

}

// MARK: - Glass material

/// The two Liquid Glass materials `NSGlassEffectView` offers, as a setting.
///
/// `.frosted` is AppKit's `.regular` — a diffusing legibility plate; what is
/// behind the panel blurs into it. `.clear` lets the backdrop flow through
/// sharp, with the refractive rim. The owner has now asked for each in turn
/// (2026-08-03: "more transparent" → clear; "a little bit too clear, might
/// need a different material" → this picker), which is how the material became
/// a setting rather than a constant. Raw-value Codable so an unknown value in
/// a payload decodes to nil and the caller falls back to `.standard`.
enum GlassMaterial: String, Codable, CaseIterable, Sendable {
  case frosted, clear

  /// The default: the diffusing plate. Over arbitrary desktops the frost is
  /// what makes the panel read as its own surface rather than a smudge.
  static let standard: GlassMaterial = .frosted

  var nsStyle: NSGlassEffectView.Style {
    switch self {
    case .frosted: return .regular
    case .clear: return .clear
    }
  }

  /// Picker label.
  var label: String {
    switch self {
    case .frosted: return "Frosted"
    case .clear: return "Clear"
    }
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

// MARK: - HUDInk

/// The ink on the dictation surfaces — one implementation of the treatment the
/// prompter, the pill's draft and the review card's editor all draw.
///
/// All three floating panels are pinned `.darkAqua` with a dark `colorScheme`
/// forced on their content, so these are stated as white with an alpha rather
/// than as `.primary`. The prompter used to draw the finalized half of one
/// sentence out of `labelColor` at 92% — which composites to ~0.78 white under
/// that scheme — against a tail specified as pure white at 55%: two halves of
/// one sentence from two different bases, with the dim step smaller than the
/// two documented numbers promise. The pill's draft was a fourth value again.
///
/// The two alphas are the documented ones and do not move: 92% finalized, 55%
/// volatile.
enum HUDInk {
  /// Text the recognizer has finalized.
  static let finalized: Color = Color(nsColor: nsFinalized)

  /// The volatile tail, still being resolved.
  static let volatile: Color = Color(nsColor: nsVolatile)

  /// `NSColor` twins, for the review card's attributed suffix.
  static let nsFinalized: NSColor = NSColor.white.withAlphaComponent(0.92)
  static let nsVolatile: NSColor = NSColor.white.withAlphaComponent(0.55)

  /// "The microphone is open", on the dictation HUD only.
  ///
  /// Deliberately **not** red: the bar and the pill drew the live-mic mark and
  /// the error mark in the same `.red`, one glyph apart, on a surface with
  /// three visual elements — the two states that most need telling apart at a
  /// glance. It is deliberately not the ember either: `CraftTokens.ember` means
  /// "the microphone is open" for the *recording* surfaces, and a second
  /// consumer would make it mean "Nota" instead (see "The ember" in CLAUDE.md).
  /// So the mark is neutral and red is left to the error state, orange to the
  /// warning — the vocabulary the HUD's own wash and stroke already use.
  static let listening: Color = Color(nsColor: NSColor.white.withAlphaComponent(0.90))
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

/// The dark cast, as a view of our own so the opacity slider works on both
/// materials (see `GlassBackingView.tintAlpha`). Takes no clicks, same as the
/// plate under it.
final class TintOverlayView: NSView {
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

// MARK: - Panel motion

/// How Nota's three floating panels arrive and leave: **one fade, named once.**
///
/// The pill, the mini-recorder island and the review card already share every
/// other rule of a floating surface (an AppKit glass plate, `.darkAqua`, a
/// verified `orderFrontRegardless`, their own position store). They did not
/// share this one: the pill faded in with an 8pt rise and out over 0.18s while
/// the other two blinked on and off — and the island is the surface that
/// appears the instant the owner switches away mid-session, which is the most
/// jarring place in the app for a hard cut. The numbers are the pill's,
/// unchanged; what moved is where they live.
///
/// Two things this deliberately does **not** touch:
///
/// - **A panel's logical state stays immediate.** `fadeIn` orders the window
///   front inside the call and hands back whatever the caller's own verified
///   `orderFrontRegardless` returned; only `alphaValue` (and the arrival rise)
///   is animated. A show that reached the screen reports so synchronously, as
///   it always did, and a presenter's own bookkeeping never waits on a curve.
/// - **The HUD's one frame-animation authority.** The rise is the same frame
///   nudge `DictationHUDPanel.show()` has always made on the way in — it is
///   over before `update` can animate a growth, and a drag still moves the
///   window with `setFrameOrigin` and never through an animator.
///
/// The rise is a **movement**, so Reduce Motion drops it to zero and the panel
/// simply fades — read from AppKit, since these are `NSPanel`s and a hosting
/// view's SwiftUI environment says nothing about the window.
@MainActor
enum PanelMotion {
  static let panelFadeIn: TimeInterval = 0.2
  static let panelFadeOut: TimeInterval = 0.18
  /// How far a panel is lifted as it arrives.
  static let panelRise: CGFloat = 8

  /// One arrival or departure, as a value.
  ///
  /// Test seam: a fade is a window-server effect and nothing in an unhosted
  /// bundle can watch alpha interpolate, so what gets asserted instead is that
  /// a successful show asked for exactly one fade-in and a dismissal for
  /// exactly one fade-out.
  struct Fade: Equatable {
    enum Direction { case arriving, leaving }
    var direction: Direction
    var duration: TimeInterval
    var rise: CGFloat
  }

  /// Set by tests only; nil on every shipping path.
  static var observer: ((Fade) -> Void)?

  static var reduceMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  /// The arrival rise, which is zero when the owner has asked for less motion.
  static func rise(reduceMotion: Bool) -> CGFloat {
    reduceMotion ? 0 : panelRise
  }

  /// Bookkeeping so a present during a fade-out cannot be undone by that
  /// fade-out's completion handler — the one way a panel could end up ordered
  /// out, or stuck transparent, while its presenter believes it is up.
  private static var generations: [ObjectIdentifier: Int] = [:]

  @discardableResult
  private static func bump(_ window: NSWindow) -> Int {
    let key = ObjectIdentifier(window)
    let next = (generations[key] ?? 0) + 1
    generations[key] = next
    return next
  }

  /// Replace whatever alpha animation is in flight with an immediate value, so
  /// a reversal starts from a value the window really has.
  private static func haltFade(_ window: NSWindow, at alpha: CGFloat) {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      window.animator().alphaValue = alpha
    }
    window.alphaValue = alpha
  }

  /// Bring `window` on screen: transparent and `rise` points low, then up to
  /// full over `panelFadeIn`.
  ///
  /// `order` is the caller's own ordering-and-verifying. It runs inside, after
  /// the panel has been prepared and before the animation starts, and its
  /// result comes back unchanged.
  static func fadeIn<Result>(
    _ window: NSWindow,
    rise: CGFloat? = nil,
    order: () -> Result
  ) -> Result {
    // A panel that is still on screen is either fully up or halfway through a
    // fade-out. Either way it does not arrive again: it carries on from the
    // alpha it has, with no rise, so a present during a departure reads as the
    // departure being called off rather than as a second arrival.
    let arriving = !window.isVisible
    let lift = arriving ? (rise ?? self.rise(reduceMotion: reduceMotion)) : 0
    bump(window)
    haltFade(window, at: arriving ? 0 : window.alphaValue)
    // A panel caught mid-dismissal had its clicks taken away; it is staying, so
    // it gets them back.
    window.ignoresMouseEvents = false

    let destination = window.frame
    if lift != 0 {
      var start = destination
      start.origin.y -= lift
      window.setFrame(start, display: false)
    }

    let result = order()

    observer?(Fade(direction: .arriving, duration: panelFadeIn, rise: lift))
    NSAnimationContext.runAnimationGroup { context in
      context.duration = panelFadeIn
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      window.animator().alphaValue = 1
      if lift != 0 { window.animator().setFrame(destination, display: true) }
    }
    return result
  }

  /// Take `window` off screen over `panelFadeOut`.
  ///
  /// The panel is inert for the whole fade: it stops taking clicks and gives up
  /// its first responder immediately, so a card the owner has just discarded
  /// cannot swallow a keystroke on its way out. The frame is untouched — a
  /// departure is a fade and nothing else.
  static func fadeOut(_ window: NSWindow, completion: (() -> Void)? = nil) {
    let generation = bump(window)
    guard window.isVisible else {
      window.orderOut(nil)
      window.alphaValue = 1
      completion?()
      return
    }

    let tookClicks = window.ignoresMouseEvents
    window.ignoresMouseEvents = true
    window.makeFirstResponder(nil)

    observer?(Fade(direction: .leaving, duration: panelFadeOut, rise: 0))
    NSAnimationContext.runAnimationGroup(
      { context in
        context.duration = panelFadeOut
        context.timingFunction = CAMediaTimingFunction(name: .easeIn)
        window.animator().alphaValue = 0
      },
      completionHandler: {
        MainActor.assumeIsolated {
          // Something asked for this panel again while it was leaving. That
          // request wins: ordering it out here is the one way a live surface
          // could vanish under the presenter that believes it is up.
          guard generations[ObjectIdentifier(window)] == generation else { return }
          window.orderOut(nil)
          window.alphaValue = 1
          window.ignoresMouseEvents = tookClicks
          completion?()
        }
      }
    )
  }
}
