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

  /// Which surfaces wear paper instead of the field: the transcript, in light.
  static func wears(role: GroundRole, light: Bool) -> Bool {
    role == .transcript && light
  }

  /// The paper for a palette, 0…255 per channel like every `FieldColor.RGB`.
  static func color(for palette: GroundPalette) -> FieldColor.RGB {
    FieldColor.rgb(hue: palette.baseHue, saturation: saturation, value: value)
  }

  static func swiftUIColor(for palette: GroundPalette) -> Color {
    let c = color(for: palette)
    return Color(red: c.x / 255, green: c.y / 255, blue: c.z / 255)
  }
}
