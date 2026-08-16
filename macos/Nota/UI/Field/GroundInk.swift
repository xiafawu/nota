import Foundation
import SwiftUI

/// One fixed ink per theme, and a fixed alpha per text tier.
///
/// Measured across all sixteen grounds, 600 frames, at the shipping flatten and
/// push: light worst 9.96:1, dark worst 9.72:1. **Every ground clears AAA with
/// the same ink**, which is what kills the derived-text-palette idea before it
/// gets built. MusicKit derives a background plus four text tiers per artwork
/// because Apple cannot constrain album art; a generated field is the opposite
/// case, so the constraint goes in at generation time. You either control the
/// ground or you derive the ink, not both — and deriving would also make the
/// text colour move while the field moves.
///
/// The alphas are **solved**, not eyeballed: the minimum each tier needs on
/// every cell of every ground, then rounded up. That is not pedantry — a
/// plausible-looking 52% timestamp measured 2.81:1 against a 3.0 bar on
/// Tidepool and Meadow, and nothing but the solve would have caught it.
///
/// ```
/// tier        target   needs light   needs dark   ships
/// Body         7.0:1       89%           78%       100%
/// Speaker      4.5:1       70%           57%        78%
/// Timestamp    3.0:1       54%           40%        56%
/// Rail         1.2:1       10%            7%        12%
/// ```
///
/// A solved alpha is a bar, not a preference, and the two are not the same
/// thing: `.primary`/`.secondary`/`.tertiary` used to hand macOS's Increase
/// contrast setting to every label on the ground for free, and a constant
/// cannot. `Tier.promoted` is where that setting lands now — each tier steps
/// one up this table, so the raised draw is an alpha the same sweep measured
/// against the raised bar.
///
/// What this does **not** fix is hue collision: flattening pins luminance, not
/// hue, so two tinted speaker labels — or a label against a seed of the same
/// family — still need a minimum hue separation enforced somewhere else. Not
/// designed yet.
enum GroundInk {
  /// `#1C1A16` over a light ground.
  static let light = FieldColor.RGB(0x1C, 0x1A, 0x16)
  /// `#EEEAE2` over a dark ground.
  static let dark = FieldColor.RGB(0xEE, 0xEA, 0xE2)

  static func ink(light isLight: Bool) -> FieldColor.RGB { isLight ? light : dark }

  enum Tier: String, CaseIterable {
    case body, reading, speaker, timestamp, rail

    /// What the tier is drawn at.
    var alpha: Double {
      switch self {
      case .body: return 1.00
      case .reading: return 0.80
      case .speaker: return 0.78
      case .timestamp: return 0.56
      case .rail: return 0.12
      }
    }

    /// The contrast ratio it has to clear against every cell of every ground.
    ///
    /// **`reading` carries a different bar because it is a different size**, not
    /// because it was allowed to fail body's. WCAG's large-text threshold is
    /// 18pt (or 14pt bold), where AAA is 4.5:1 rather than 7.0:1 and AA is 3.0
    /// rather than 4.5 — and the transcript body is 18.5pt
    /// (`NSFonts.readingBody`), so it qualifies outright. Drawn at 0.80 it
    /// measures 5.69:1 at its worst over all sixteen palettes, which clears
    /// large-AAA with margin and would have been AA at body's size. The tier
    /// exists rather than `Tier.body` moving because the live transcript draws
    /// `.body` at 14pt on the same grounds: one alpha cannot answer two sizes,
    /// and lowering the shared one would silently take the small text with it.
    var minimumContrast: Double {
      switch self {
      case .body: return 7.0
      case .reading: return 4.5
      case .speaker: return 4.5
      case .timestamp: return 3.0
      case .rail: return 1.2
      }
    }

    /// The tier this one is drawn as when the owner has asked for more
    /// contrast — **each tier is promoted one step up its own table.**
    ///
    /// Fixing the alphas took something away that nobody wrote down. `.primary`
    /// / `.secondary` / `.tertiary` resolve through `NSColor.labelColor` and
    /// friends, which macOS substitutes with higher-contrast variants under
    /// System Settings → Accessibility → Display → **Increase contrast**; a
    /// constant per (tier, scheme) cannot, so the gutter timestamps and the
    /// volatile in-flight line would have stayed pinned at 3.0:1 — under
    /// AA's 4.5:1 for body text — however loudly the owner asked. The solve was
    /// for a bar, not for a preference, and this is where the preference lands.
    ///
    /// Promotion rather than a second table: every alpha it can reach is one
    /// the sweep already measured on all sixteen grounds, so the raised draw
    /// carries a *measured* bar too — timestamp promotes to speaker's 4.5:1,
    /// speaker to body's 7.0:1, rail to timestamp's 3.0:1 — and
    /// `testEveryTierClearsItsBarOnEveryGroundInBothThemes` sweeps both
    /// settings against `minimumContrast(_:)`. Body is already the ink at
    /// alpha 1: there is nothing above it, and it is the one tier that needed
    /// nothing, having measured 9.96:1 / 9.72:1 at its worst.
    var promoted: Tier {
      switch self {
      case .body: return .body
      // Reading promotes to full opacity rather than to `speaker`, which is
      // *below* it: the table is ordered by alpha and promotion means one step
      // up it. An owner asking for more contrast on 18.5pt body text wants the
      // ink, and body is the only thing above 0.80.
      case .reading: return .body
      case .speaker: return .body
      case .timestamp: return .speaker
      case .rail: return .timestamp
      }
    }

    /// What the tier is drawn at for a given contrast preference.
    func alpha(_ contrast: ColorSchemeContrast) -> Double {
      contrast == .increased ? promoted.alpha : alpha
    }

    /// The bar the tier has to clear for a given contrast preference.
    func minimumContrast(_ contrast: ColorSchemeContrast) -> Double {
      contrast == .increased ? promoted.minimumContrast : minimumContrast
    }
  }

  /// Ink composited onto a ground colour at a tier's alpha.
  static func composite(_ tier: Tier, over ground: FieldColor.RGB, light isLight: Bool)
    -> FieldColor.RGB
  {
    FieldColor.mix(ground, ink(light: isLight), tier.alpha)
  }

  /// WCAG relative luminance.
  static func relativeLuminance(_ c: FieldColor.RGB) -> Double {
    func f(_ u: Double) -> Double {
      let x = u / 255
      return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * f(c.x) + 0.7152 * f(c.y) + 0.0722 * f(c.z)
  }

  /// WCAG contrast ratio, 1...21.
  static func contrast(_ a: FieldColor.RGB, _ b: FieldColor.RGB) -> Double {
    let l = relativeLuminance(a), m = relativeLuminance(b)
    return (max(l, m) + 0.05) / (min(l, m) + 0.05)
  }

  /// What a tier actually achieves over a ground colour.
  static func contrast(of tier: Tier, over ground: FieldColor.RGB, light isLight: Bool) -> Double {
    contrast(composite(tier, over: ground, light: isLight), ground)
  }

  // MARK: - The ink, drawn

  /// The tier as a colour a view can draw with: the theme's ink, at the tier's
  /// solved alpha.
  ///
  /// **It observes nothing.** The ground is a moving value and the obvious
  /// design is to sample the frame under the glyph and pick an ink to suit it —
  /// which is the one thing the solve exists to make unnecessary. Every tier
  /// clears its bar on all sixteen grounds in both themes, at every moment of
  /// the flow, so the ink is a **constant per (tier, scheme)** and no label on
  /// the surface has any reason to watch `FieldEngine`. Sampling per frame would
  /// hang a ~20 Hz publisher off every piece of text on the two largest views in
  /// the app, which is the XIA-432 trap rebuilt by hand.
  ///
  /// Drawing the ink at `tier.alpha` is the same arithmetic
  /// `composite(_:over:light:)` measured, and that is checked rather than
  /// assumed: `FieldColor.mix` is a straight per-channel lerp, the compositor
  /// does a straight per-channel lerp in the destination's own encoding, and
  /// `testTheSurfaceCompositesEachTierAtExactlyItsAlpha` renders both endpoints
  /// and the tier and compares them. Had the compositor been working in linear
  /// light instead, every partial-alpha tier would land lighter than it was
  /// measured and the 3.0:1 timestamp would be the first through its floor.
  /// The one thing it *does* answer is the owner's contrast preference, which
  /// is a setting and not a sample of the ground: `.increased` promotes the
  /// tier (see `Tier.promoted`) and changes nothing else. It is a parameter
  /// rather than a read of the environment so the promotion is assertable
  /// without a hosting view — `EnvironmentValues.colorSchemeContrast` is
  /// get-only, so a test cannot ask for the increased case any other way.
  static func color(
    _ tier: Tier, _ scheme: ColorScheme, _ contrast: ColorSchemeContrast = .standard
  ) -> Color {
    let rgb = ink(light: scheme == .light)
    return Color(
      .sRGB,
      red: rgb.x / 255,
      green: rgb.y / 255,
      blue: rgb.z / 255,
      opacity: tier.alpha(contrast))
  }
}

/// `.foregroundStyle(.ground(.body))` — a tier, resolved against whatever colour
/// scheme the view is being drawn in.
///
/// A `ShapeStyle` rather than a `Color` the caller has to build, for two
/// reasons. It keeps the alpha in one place: a view that took
/// `GroundInk.ink(light:)` and applied its own `.opacity()` would be typing in a
/// number nobody measured, and the tier table is the *minimum* each tier needs
/// on the worst cell of the worst ground — every one of them was rounded up to
/// reach it. And it spares six views an `@Environment(\.colorScheme)` they would
/// otherwise carry only to hand it straight back to this type; the environment
/// is read at resolve time, where SwiftUI already has it.
///
/// It reads **two** values, and the second is the whole reason a `ShapeStyle`
/// is the right shape for this: `colorSchemeContrast` is the Increase contrast
/// setting, and it is only free here because SwiftUI already has it at resolve
/// time. Fixed alphas took that setting away from every label on the ground
/// (see `GroundInk.Tier.promoted`); this is the one place that could give it
/// back, and every call site gets it without knowing it exists.
extension GroundInk {
  /// The tier as an `NSColor`, for the AppKit half of the app.
  ///
  /// `MarkdownRender` builds `NSAttributedString` attributes rather than SwiftUI
  /// views, so `.foregroundStyle(.ground(_:))` cannot reach the document pane at
  /// all — which is exactly why that pane spent XIA-442 through XIA-446 drawing
  /// with `NSColor.labelColor` while `RecordingPane` drew the same words in the
  /// solved ink. One accessor closes the gap; without it "adopt GroundInk" is
  /// not a thing the document path can do.
  ///
  /// **Dynamic, never resolved at build time.** The obvious version reads a
  /// `ColorScheme` and returns a flat `NSColor`, and it is wrong in a way that
  /// only shows up later: the attributed string is built once and handed to a
  /// text view that lives across theme changes, so baked light ink would stay
  /// dark-on-dark the moment the owner switched appearance — a regression
  /// against `labelColor`, which has always been dynamic. `NSColor(name:
  /// dynamicProvider:)` is resolved by AppKit at *draw* time, per appearance,
  /// which is the same contract the semantic colours were honouring.
  ///
  /// It answers Increase contrast for the same reason the `ShapeStyle` does:
  /// the appearance carries the accessibility variants, so `Tier.promoted` is
  /// still reachable from a surface that has no SwiftUI environment.
  static func nsColor(_ tier: Tier) -> NSColor {
    NSColor(name: NSColor.Name("ground.\(tier.rawValue)")) { appearance in
      let increased = appearance.bestMatch(from: [
        .aqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
      ]).map { $0 == .accessibilityHighContrastAqua || $0 == .accessibilityHighContrastDarkAqua }
        ?? false
      let light = appearance.bestMatch(from: [.aqua, .darkAqua]) != .darkAqua
      let rgb = ink(light: light)
      return NSColor(
        srgbRed: rgb.x / 255,
        green: rgb.y / 255,
        blue: rgb.z / 255,
        alpha: tier.alpha(increased ? .increased : .standard))
    }
  }
}

struct GroundInkStyle: ShapeStyle {
  let tier: GroundInk.Tier

  func resolve(in environment: EnvironmentValues) -> Color {
    GroundInk.color(tier, environment.colorScheme, environment.colorSchemeContrast)
  }
}

extension ShapeStyle where Self == GroundInkStyle {
  static func ground(_ tier: GroundInk.Tier) -> GroundInkStyle { GroundInkStyle(tier: tier) }
}
