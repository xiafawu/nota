import Foundation

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
    case body, speaker, timestamp, rail

    /// What the tier is drawn at.
    var alpha: Double {
      switch self {
      case .body: return 1.00
      case .speaker: return 0.78
      case .timestamp: return 0.56
      case .rail: return 0.12
      }
    }

    /// The contrast ratio it has to clear against every cell of every ground.
    var minimumContrast: Double {
      switch self {
      case .body: return 7.0
      case .speaker: return 4.5
      case .timestamp: return 3.0
      case .rail: return 1.2
      }
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
}
