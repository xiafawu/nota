import Foundation

/// One of the sixteen grounds the field can be drawn in.
///
/// A palette is **drawn once per launch and held for the whole process**. It is
/// never re-rolled on a phase change and never mid-session, because the field
/// morphs continuously and a palette swap would be a cut in something whose
/// whole quality is that it never cuts.
///
/// All sixteen ship (owner, 2026-08-09: *"all palette works for me. tbh. lets
/// keep all of them"*). There is no cull and no ranking — the draw is uniform.
///
/// Each palette is a **base hue** for the wash plus **three family hues** for
/// the seeds. Three families is the shape, not a limit that was almost broken:
/// the constraint on the look is that families do not *contest* the same region
/// of the frame, not that there are at most two of them. Six seeds on a fixed
/// lattice take the family hues in rotation, so each family owns two territories.
struct GroundPalette: Equatable, Sendable, Identifiable {
  /// Stable across launches — it is what gets persisted as "the last one drawn"
  /// so the next launch can exclude it.
  let id: String
  /// Display name. Nothing in the app shows it yet; it exists so a diagnostic
  /// or a snapshot failure can name the ground rather than an index.
  let name: String
  /// Hue of the base wash, in degrees.
  let baseHue: Double
  /// Hues of the seeds, in degrees, taken in rotation by the six seeds.
  let familyHues: [Double]

  static let all: [GroundPalette] = [
    GroundPalette(id: "meadow", name: "Meadow", baseHue: 44, familyHues: [24, 104, 252]),
    GroundPalette(id: "tide", name: "Tide", baseHue: 210, familyHues: [186, 252, 52]),
    GroundPalette(id: "dusk", name: "Dusk", baseHue: 280, familyHues: [252, 34, 342]),
    GroundPalette(id: "ink", name: "Ink", baseHue: 250, familyHues: [258, 296, 214]),
    GroundPalette(id: "orchard", name: "Orchard", baseHue: 60, familyHues: [32, 78, 210]),
    GroundPalette(id: "harbour", name: "Harbour", baseHue: 200, familyHues: [214, 165, 44]),
    GroundPalette(id: "heath", name: "Heath", baseHue: 300, familyHues: [288, 116, 18]),
    GroundPalette(id: "frost", name: "Frost", baseHue: 210, familyHues: [200, 268, 150]),
    GroundPalette(id: "kiln", name: "Kiln", baseHue: 30, familyHues: [12, 40, 230]),
    GroundPalette(id: "fern", name: "Fern", baseHue: 120, familyHues: [128, 178, 28]),
    GroundPalette(id: "tidepool", name: "Tidepool", baseHue: 190, familyHues: [172, 246, 8]),
    GroundPalette(id: "vellum", name: "Vellum", baseHue: 50, familyHues: [46, 96, 224]),
    GroundPalette(id: "nocturne", name: "Nocturne", baseHue: 240, familyHues: [226, 276, 26]),
    GroundPalette(id: "lichen", name: "Lichen", baseHue: 80, familyHues: [88, 40, 250]),
    GroundPalette(id: "quarry", name: "Quarry", baseHue: 190, familyHues: [208, 20, 100]),
    GroundPalette(id: "bloom", name: "Bloom", baseHue: 320, familyHues: [348, 292, 110]),
  ]

  static func palette(id: String) -> GroundPalette? {
    all.first { $0.id == id }
  }

  /// Draw a ground, excluding the one the previous launch used.
  ///
  /// The generator is a parameter rather than `SystemRandomNumberGenerator`
  /// reached for inside, so a snapshot test can pin one ground and a
  /// reproducibility test can prove the draw is a function of the seed.
  ///
  /// The exclusion is a preference, not a guarantee the caller has to check:
  /// with an unknown id (a palette retired between launches) it excludes
  /// nothing, and it can never exclude its way down to an empty pool.
  static func pick<G: RandomNumberGenerator>(
    excluding excludedID: String?,
    using generator: inout G
  ) -> GroundPalette {
    let remaining = all.filter { $0.id != excludedID }
    let pool = remaining.isEmpty ? all : remaining
    // `all` is a non-empty literal, so `pool` is too.
    return pool.randomElement(using: &generator)!
  }
}
