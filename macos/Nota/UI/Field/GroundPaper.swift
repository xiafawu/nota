import SwiftUI

/// The surface under a wall of text in light mode: flat paper, tinted from
/// the launch.
///
/// Owner's call, 2026-09-02 ("C for light and A for dark"), from a sheet that
/// put four surfaces under the same transcript side by side. The measurement
/// behind it (`three-lanes-for-text-on-colour`, 2026-08-15, eight shipping
/// apps): long-form text sits on one strong hue, or on a **dark** multi-hue
/// field, or on something neutral with the colour kept to the edges — and never
/// on a pale multi-hue field, which is what the light transcript was. The dark
/// transcript is the second lane and keeps the field; only the light one moves
/// onto paper.
///
/// **Both reading states wear it** (ADR 0007). The live session and the
/// finished document are one surface with two states, so the recording page
/// takes the paper in light mode too — with a 34em reading column at 18.5pt,
/// a live transcript *is* long-form text and falls under the same measured
/// lane rule. Dark mode is untouched: every role keeps the field.
///
/// **And it is the SAME paper, which is the half that matters.** The launch's
/// `GroundFamily` gives `.recording` and `.transcript` different palettes, so
/// tinting each role from its own would still change the ground under the
/// owner at Stop — a quieter version of the exact event ADR 0007 exists to
/// remove. There is therefore no way to ask this type for "the paper for a
/// role": `palette(in:)` is the one function that answers which palette a
/// paper surface tints from, and it answers `.transcript` for all of them.
///
/// Two costs, both accepted by the owner:
/// - In light mode the family's **`recording` palette goes undrawn.** Home
///   keeps its own field, so a launch still shows two of its three grounds;
///   what is lost is the third, and only in light.
/// - The recording cluster's **Liquid Glass capsules refract less**, because
///   flat paper has nothing moving behind them. The ember meter still carries
///   liveness, which is the thing that surface owes.
///
/// **The paper is not white.** It carries the base hue of the palette the
/// family gave the transcript, at a few percent of saturation, so home and the
/// document still read as one app on the same launch, and a warm launch gets
/// warm paper. Value is fixed, which is what makes the contrast a constant
/// rather than a sweep: `GroundPaperTests` walks all sixteen palettes anyway.
///
/// The transcribing screen wears it too — it is `.transcript` for the same
/// reason it always was (a run is the transcript arriving), and a ground swap
/// at the moment the text lands would be the second event that role exists
/// to prevent.
enum GroundPaper {
  /// HSV saturation of the tint. `hsl(h, 30%, 96%)` on the sheet, which is
  /// this in HSV.
  static let saturation: Double = 0.024
  /// HSV value. High enough that the warm ink's `body` tier clears 15:1 on
  /// every palette; low enough not to be paper-white.
  static let value: Double = 0.973

  /// Which surfaces wear paper instead of the field: the two reading states,
  /// in light.
  ///
  /// A `switch` with no `default`, so a fourth role cannot be added without
  /// someone answering this question for it — the difference between a
  /// surface that reads as paper and one that reads as the moving field is
  /// not a default anybody should inherit.
  static func wears(role: GroundRole, light: Bool) -> Bool {
    guard light else { return false }
    switch role {
    case .recording, .transcript: return true
    case .home: return false
    }
  }

  /// **The one function that answers which palette a paper surface tints
  /// from**, and it takes no role on purpose.
  ///
  /// Every paper surface is the transcript's paper. Two call sites that
  /// happened to agree would be one edit away from disagreeing, and what they
  /// would disagree about is a colour change at the instant the owner presses
  /// Stop.
  static func palette(in family: GroundFamily) -> GroundPalette {
    family.palette(for: .transcript)
  }

  /// The paper for a palette, 0…255 per channel like every `FieldColor.RGB`.
  ///
  /// The primitive, kept separate from `palette(in:)` because the contrast
  /// proof walks all sixteen palettes rather than the seven a family can hand
  /// the transcript.
  static func color(for palette: GroundPalette) -> FieldColor.RGB {
    FieldColor.rgb(hue: palette.baseHue, saturation: saturation, value: value)
  }

  /// What a view draws. There is deliberately no role parameter: see
  /// `palette(in:)`.
  static func swiftUIColor(in family: GroundFamily) -> Color {
    let c = color(for: palette(in: family))
    return Color(red: c.x / 255, green: c.y / 255, blue: c.z / 255)
  }
}
