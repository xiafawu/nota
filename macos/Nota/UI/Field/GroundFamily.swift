import Foundation

/// What a view asks of the ground.
///
/// A role is **not** a colour. It is the job the surface does, and the only
/// thing it decides is `push` — how far the value band is held away from the
/// ink. Which *hue* a role gets is the family's business, so that the same
/// role reads differently on different launches while always doing the same
/// job.
///
/// **`flatten` is deliberately not a role property**, and that is a measured
/// result rather than a simplification. `FieldEngineTests
/// .testLuminanceVariationSurvivesAtFlattenForty` holds a floor of 5.0 points
/// of luminance span per ground, and the shipping value of 0.40 already
/// measures 5.3 on `ink` light — the narrowest of the sixteen. Sweeping it
/// (0.45 → 4.8, 0.50 → 4.3, 0.55 → 3.8, 0.62 → 3.2) puts every raise below the
/// floor. A transcript ground that "calms down" by flattening is the field
/// turning back into flat paint, which is the one thing that measurement
/// exists to prevent. Readability therefore comes from `push` alone: push
/// moves the band away from the ink, flatten collapses the band itself.
enum GroundRole: String, CaseIterable, Sendable {
  /// The front door.
  case home
  /// A live session. The ember cluster floats over this one.
  case recording
  /// A wall of body text — the only surface in the app that carries one.
  case transcript

  /// How far the band is pushed away from the ink.
  ///
  /// `home` and `recording` keep the shipping value: nothing about those two
  /// surfaces asked for a change, and a number that moves without a reason is
  /// a number nobody can defend later.
  ///
  /// `transcript` takes **0.97**, which is not a taste call — it is the most
  /// the band will take. Measured at flatten 0.40: push 0.94 → 5.2pt span,
  /// 0.97 → 5.1pt, and **1.00 → 5.0pt, exactly the floor**. So 0.97 is the
  /// last value with any margin left, and it buys the ink 1.1 points of extra
  /// lightness separation in light mode (mean band value 0.919 → 0.930) and
  /// 1.3 in dark (0.198 → 0.185).
  var push: Double {
    switch self {
    case .home, .recording: return 0.90
    case .transcript: return 0.97
    }
  }
}

/// A chord of three grounds, one per view.
///
/// **The launch draws a family, not a palette** — which is what lets the two
/// things that were previously in tension both be true. The ground is still a
/// different ground every morning (the draw survives, one level up), and the
/// three views are still visibly different from each other (they are three
/// palettes, not one palette tinted three ways).
///
/// **Families overlap on purpose.** A palette is a colour and a role is a job,
/// so the same colour can hold different jobs in different chords — `kiln`
/// records in Riverbank and carries the transcript in Sunfall. Nothing here
/// needs the sixteen to partition into threes, and requiring it would have
/// meant retiring a palette for arithmetic's sake.
///
/// ## How these seven were chosen
///
/// By measurement, not by eye. Every one of the 560 triples was scored on a
/// distance that is 65% base-hue arc plus 35% the mean arc between the two
/// palettes' seed hues — the seed term is what keeps `tidepool` and `quarry`
/// from being called one colour, since they share a base hue of 190° and carry
/// very different families. Three constraints then cut it down:
///
/// - **Minimum pairwise separation ≥ 45.** Below it the three views read as
///   the same room, which loses the entire point of the change.
/// - **Maximum pairwise separation ≤ 98.** Above it they stop being a chord.
///   The highest-scoring triples in the whole set (108.6, `lichen`/`harbour`/
///   `bloom`) are three unrelated colours that happen to be far apart.
/// - **No two families share more than one palette.** Without it the search
///   returns four near-copies of the same violet family, all containing
///   `dusk` and `nocturne`.
///
/// Seven come out, covering fourteen of the sixteen. **`meadow` (44°) and
/// `vellum` (50°) are drawn by no family** — they are near-twins of `orchard`
/// (60°) and `kiln` (30°), which are. That is a real finding about the
/// sixteen rather than a gap to paper over, and they stay in `GroundPalette
/// .all` because the ember proof walks that array and because retiring a
/// colour is a bigger decision than this one.
struct GroundFamily: Equatable, Sendable, Identifiable {
  /// Stable across launches — this is what is persisted as "the last one
  /// drawn", so the next launch can exclude it.
  let id: String
  /// Display name. Nothing shows it yet; it exists so a diagnostic or a
  /// snapshot failure can name the chord rather than an index.
  let name: String

  /// Palette ids by role. Ordered `home`, `recording`, `transcript` — the
  /// same order as `GroundRole.allCases`, which `palette(for:)` relies on.
  let paletteIDs: [String]

  /// The ground this family gives that view.
  ///
  /// Falls back to the first palette rather than trapping: this reads a
  /// hand-written table, and a typo in it must cost one wrong colour, never a
  /// launch. The table is pinned by `GroundFamilyTests` so the fallback is
  /// unreachable in practice.
  func palette(for role: GroundRole) -> GroundPalette {
    let index = GroundRole.allCases.firstIndex(of: role) ?? 0
    guard index < paletteIDs.count,
      let palette = GroundPalette.palette(id: paletteIDs[index])
    else {
      return GroundPalette.all[0]
    }
    return palette
  }

  /// Role order inside each chord is assigned by rule as well.
  ///
  /// Each ground is scored on **restlessness** — the mean hue distance of its
  /// three seeds from its own base wash, i.e. how much colour argument it
  /// contains. The busiest becomes `home`, which is the front door and can
  /// afford to be the loudest thing. The quietest becomes `transcript`, which
  /// is read rather than looked at. The middle one records.
  static let all: [GroundFamily] = [
    GroundFamily(
      id: "riverbank", name: "Riverbank",
      paletteIDs: ["lichen", "kiln", "fern"]),
    GroundFamily(
      id: "deepwater", name: "Deepwater",
      paletteIDs: ["heath", "tide", "ink"]),
    GroundFamily(
      id: "nightfall", name: "Nightfall",
      paletteIDs: ["harbour", "dusk", "nocturne"]),
    GroundFamily(
      id: "sunfall", name: "Sunfall",
      paletteIDs: ["bloom", "orchard", "kiln"]),
    GroundFamily(
      id: "frostline", name: "Frostline",
      paletteIDs: ["quarry", "nocturne", "frost"]),
    GroundFamily(
      id: "amethyst", name: "Amethyst",
      paletteIDs: ["tidepool", "dusk", "ink"]),
    GroundFamily(
      id: "watermeadow", name: "Watermeadow",
      paletteIDs: ["quarry", "tide", "fern"]),
  ]

  static func family(id: String) -> GroundFamily? {
    all.first { $0.id == id }
  }

  /// Draw a family, excluding the one the previous launch used.
  ///
  /// Same contract as `GroundPalette.pick` and for the same reasons: the
  /// generator is a parameter so a test can pin the draw, the exclusion is a
  /// preference rather than a guarantee the caller must check, and it can
  /// never exclude its way down to an empty pool.
  static func pick<G: RandomNumberGenerator>(
    excluding excludedID: String?,
    using generator: inout G
  ) -> GroundFamily {
    let remaining = all.filter { $0.id != excludedID }
    let pool = remaining.isEmpty ? all : remaining
    // `all` is a non-empty literal, so `pool` is too.
    return pool.randomElement(using: &generator)!
  }
}

/// Moving the ground from one view's colour to the next.
///
/// **The morph is not an animation.** Nothing here interpolates pixels or
/// cross-fades two images. The field already relaxes toward its target by
/// `FieldSimulation.relaxation` (7%) every step, so a *target* whose hues move
/// is followed by the buffer over about a second and a half, on the curl
/// current it is already flowing on. All this type does is move the target.
///
/// That distinction is the whole reason a section change is cheap, and it is
/// also the trap: the cut that `FieldEngine`'s note warns about comes from
/// `reprime()`, which paints the target outright, and **not** from changing
/// colour. So a view switch may move hues and `push`, and may never reprime,
/// rebuild the seeds, or replace the simulation.
enum GroundMorph {
  /// Seconds. How long the target takes to travel most of the way to the new
  /// ground, on top of which the field's own 7% relaxation does the rest.
  ///
  /// Deliberately shorter than the field's own response: the target arriving
  /// early and the buffer chasing it is what reads as the ground *resolving*,
  /// where a target that crawls alongside the buffer reads as a slow fade.
  static let timeConstant: TimeInterval = 0.55

  /// How far to travel this step. Framed off `dt` rather than a per-frame
  /// constant so a dropped frame does not slow the morph down, for the same
  /// reason `FieldEngine.tick` asks the clock instead of assuming its interval.
  static func fraction(dt: TimeInterval) -> Double {
    guard dt > 0 else { return 0 }
    return 1 - exp(-dt / timeConstant)
  }

  /// Move a hue toward another **the short way round**.
  ///
  /// The same rule as `GroundWarmth.rotate` and load-bearing for the same
  /// reason: a hue that takes the long arc crosses the far side of the wheel,
  /// and every intermediate on the way is mud. `GroundWarmth.rotate` cannot be
  /// reused because it only ever travels toward one fixed anchor.
  static func hue(_ from: Double, toward target: Double, by amount: Double) -> Double {
    var delta = target - from
    if delta > 180 { delta -= 360 }
    if delta < -180 { delta += 360 }
    return from + delta * amount
  }
}
