import Foundation

// MARK: - Colour

/// The colour arithmetic the field is built out of, in one place.
///
/// Components are 0...255 doubles rather than a `Color` or an `NSColor`,
/// because the whole engine has to run with no window server, no colour space
/// negotiation and no main actor — the field is a `[Float]` array and every
/// number in it is assertable.
enum FieldColor {
  typealias RGB = SIMD3<Double>

  /// HSV to straight sRGB, hue in degrees, s and v in 0...1.
  static func rgb(hue: Double, saturation: Double, value: Double) -> RGB {
    let h = (hue.truncatingRemainder(dividingBy: 360) + 360)
      .truncatingRemainder(dividingBy: 360) / 60
    let c = value * saturation
    let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
    let m = value - c
    let sector = Int(h) % 6
    let t: (Double, Double, Double)
    switch sector {
    case 0: t = (c, x, 0)
    case 1: t = (x, c, 0)
    case 2: t = (0, c, x)
    case 3: t = (0, x, c)
    case 4: t = (x, 0, c)
    default: t = (c, 0, x)
    }
    return RGB((t.0 + m) * 255, (t.1 + m) * 255, (t.2 + m) * 255)
  }

  /// Straight sRGB back to HSV. Hue in degrees; hue is 0 for a grey.
  static func hsv(_ c: RGB) -> (hue: Double, saturation: Double, value: Double) {
    let r = c.x / 255, g = c.y / 255, b = c.z / 255
    let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
    var h = 0.0
    if d != 0 {
      if mx == r {
        h = 60 * (((g - b) / d).truncatingRemainder(dividingBy: 6))
      } else if mx == g {
        h = 60 * ((b - r) / d + 2)
      } else {
        h = 60 * ((r - g) / d + 4)
      }
    }
    return ((h + 360).truncatingRemainder(dividingBy: 360), mx == 0 ? 0 : d / mx, mx)
  }

  static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB { a + (b - a) * t }

  /// HSV value, without computing hue or saturation.
  @inline(__always) static func value(of c: RGB) -> Double {
    max(c.x, max(c.y, c.z)) / 255
  }

  /// The same colour at a different HSV value — hue and saturation untouched.
  ///
  /// This is a **scale**, not a round trip, and that is exact rather than an
  /// approximation: for fixed hue and saturation, every component of
  /// `rgb(h, s, v)` is linear in `v` (`c = v·s`, `x = c·…`, `m = v − c`), so
  /// changing the value is multiplying the triple. Going out to HSV and back
  /// just to move one component cost two conversions per cell — a third of the
  /// step's whole runtime — to compute a hue and a saturation it then handed
  /// straight back unchanged.
  ///
  /// This is where flatten is applied, which is what makes "flatten touches
  /// value only" true by construction instead of by care.
  @inline(__always) static func settingValue(of c: RGB, to v: Double) -> RGB {
    let current = value(of: c)
    guard current > 0 else { return RGB(repeating: v * 255) }
    return c * (v / current)
  }
}

@inline(__always) func fieldLerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
  a + (b - a) * t
}

@inline(__always) func fieldClamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
  x < lo ? lo : (x > hi ? hi : x)
}

// MARK: - Theme

/// Where the value band sits, and how saturated the field is allowed to be.
///
/// This is where **push** lands. Push moves the band *away* from the ink —
/// lighter under dark text, darker under light text — and it is the mechanism
/// that buys readability. Flatten (which lives on the simulation, not here)
/// only collapses whatever band is left toward its own middle.
///
/// That order matters and was measured the wrong way round first: with push
/// held at 90, worst body contrast moves **0.32 across the entire flatten
/// slider** while luminance variation falls from 15.5 points to zero. Push does
/// the work; flatten is a tax on the photographic quality. Ship
/// `push = 0.90, flatten = 0.40`.
struct FieldTheme: Equatable, Sendable {
  /// Saturation of the base wash.
  var baseSaturation: Double
  /// Value at the top of the frame.
  var bandTop: Double
  /// Value at the bottom of the frame. The ramp between the two is monotonic
  /// down the long axis and never comes back up — that is what makes the field
  /// read as layered rather than as scattered lights.
  var bandBottom: Double
  /// Saturation of a seed.
  var seedSaturation: Double
  /// Value of a seed.
  var seedValue: Double
  /// A small lateral lean on the band, so no column is ever constant.
  var tilt: Double

  static func make(light: Bool, push: Double) -> FieldTheme {
    let p = fieldClamp(push, 0, 1)
    if light {
      return FieldTheme(
        baseSaturation: 0.07,
        bandTop: fieldLerp(0.86, 0.985, p),
        bandBottom: fieldLerp(0.70, 0.885, p),
        seedSaturation: 0.28,
        seedValue: fieldLerp(0.80, 0.965, p),
        tilt: 0.014)
    }
    return FieldTheme(
      baseSaturation: 0.11,
      bandTop: fieldLerp(0.46, 0.26, p),
      bandBottom: fieldLerp(0.26, 0.10, p),
      seedSaturation: 0.40,
      seedValue: fieldLerp(0.50, 0.30, p),
      tilt: 0.020)
  }

  var bandMiddle: Double { (bandTop + bandBottom) / 2 }
}

// MARK: - Simulation

/// The field itself: six colour seeds carried on a curl current, with the whole
/// frame advected along that same current and relaxed back toward the seeds'
/// target every frame.
///
/// Semi-Lagrangian advection is what makes it flow rather than crossfade: each
/// cell asks where its colour *came from* one step ago and takes it from there.
/// Relaxing toward the target afterwards is what keeps it on palette — pure
/// advection would smear the whole frame into an average within a minute or two.
///
/// **`step(dt:)` is the only mutator.** Everything else is a read. Reduce Motion
/// is therefore implemented by not calling it, and a snapshot test is a fixed
/// number of steps and then a look at `buffer`.
///
/// Cost, measured on an M1 Pro with `swiftc -O` against **this** code: **274 µs**
/// a frame at 64×36 — 0.8% of a 33 ms frame — plus 10 µs to build the `CGImage`.
///
/// The `soft-field` skill's table says 115 µs and 1 µs, and the difference is
/// not a regression: that benchmark timed the advection alone, and a real step
/// also evaluates `target` for every cell (six seed mixes and a value rescale).
/// Worth writing down, because the table is what the skill points at when it
/// tells you not to reach for Metal, and the honest figure is 2.4× it. The
/// conclusion is unchanged with room to spare — and what staying on the CPU
/// buys is a plain `[Float]` array, which is why every invariant above this
/// line is a unit test instead of a screenshot.
///
/// (First cut measured 433 µs. The flatten step was going out to HSV and back
/// per cell to move one component; see `FieldColor.settingValue(of:to:)`.)
final class FieldSimulation {
  /// The six seed positions. A fixed lattice: only the colours are drawn per
  /// launch, so the *composition* is identical on every ground and only the
  /// palette changes. Colour lives at the perimeter and the body stays
  /// near-neutral, which is the arrangement hand-built versions usually invert.
  static let spots: [(u: Double, v: Double)] = [
    (0.16, 0.18), (0.80, 0.30), (0.30, 0.54),
    (0.86, 0.68), (0.12, 0.76), (0.58, 0.88),
  ]

  /// How hard a seed is pulled back to where it started. Without it the curl
  /// flow eventually walks all six into the same eddy and the composition dies.
  static let seedHoming: Double = 0.045

  /// How much of the target is mixed in per step once the field is primed. The
  /// whole balance between "flows" and "stays on palette" is this number.
  static let relaxation: Double = 0.07

  /// Advection and seed motion both run at three times the raw flow speed.
  static let motionScale: Double = 3

  /// A slow upward bias in the advection lookup, so the field has a direction
  /// as well as a swirl.
  static let upwardDrift: Double = 0.004

  /// Seeds are elliptical, squashed vertically, because the surfaces this ends
  /// up on are wider than they are tall and a circular falloff reads as a row
  /// of dots on one.
  static let seedAspect: Double = 0.62

  /// A seed never fully replaces the wash beneath it.
  static let seedStrength: Double = 0.90

  struct Seed: Equatable {
    var u: Double
    var v: Double
    let radius: Double
    /// `var` since XIA-446: a view switch moves each seed's hue toward the new
    /// role's ground while leaving the seed exactly where it has drifted to.
    /// Rebuilding the seeds would take the composition back to minute zero,
    /// which is a cut in the one surface that may never cut.
    var hue: Double
    let homeU: Double
    let homeV: Double
  }

  let width: Int
  let height: Int

  /// `width * height * 3`, row-major, straight sRGB 0...255.
  private(set) var buffer: [Float]
  /// Seconds of session. Drives the flow *and* the warming — one clock, so the
  /// two can never disagree about how far in we are.
  private(set) var elapsed: TimeInterval = 0
  private(set) var seeds: [Seed]

  /// The ground the field is heading for. Set at init and by `morph(to:push:)`,
  /// which is why it is no longer settable from outside: the old setter
  /// reprimed, and a section change that reprimed would paint the new ground
  /// outright — the one cut this surface may not have. See `GroundMorph`.
  private(set) var palette: GroundPalette

  /// Still re-primes, and should: an appearance flip is a different band
  /// entirely, and advecting a frame built for the other one would show the
  /// old band draining out of the new one for a second.
  var light: Bool { didSet { if light != oldValue { reprime() } } }

  /// Where the value band sits, animated per view (`GroundRole.push`).
  ///
  /// It lost its re-prime with the palette's and for the same reason. Nothing
  /// mutated it at runtime before XIA-446 — it was set at init and never
  /// again — so no behaviour is lost, and a re-prime here would make the one
  /// role that raises it (`transcript`) arrive as a cut.
  private(set) var push: Double

  /// Fixed, and `let` to say so.
  ///
  /// 0.40 is 5.3 points of luminance span on `ink` light against a measured
  /// floor of 5.0, so there is no headroom to spend: every raise (0.45 → 4.8,
  /// 0.50 → 4.3, 0.62 → 3.2) reads as flat paint rather than as a
  /// photograph. Readability that a view needs comes from `push`. See
  /// `GroundRole.push` and `testLuminanceVariationSurvivesAtFlattenForty`.
  let flatten: Double

  /// Where the animated values are heading. Nil until something asks for a
  /// morph, so a simulation nobody switches costs no arithmetic at all.
  private var morphTarget: (palette: GroundPalette, push: Double)?

  private var primed = false

  init(
    width: Int = 64,
    height: Int = 36,
    palette: GroundPalette,
    light: Bool,
    flatten: Double = 0.40,
    push: Double = 0.90
  ) {
    self.width = max(2, width)
    self.height = max(2, height)
    self.palette = palette
    self.light = light
    self.flatten = flatten
    self.push = push
    self.buffer = [Float](repeating: 0, count: self.width * self.height * 3)
    self.seeds = FieldSimulation.makeSeeds(palette: palette)
    self.baseHue = palette.baseHue
  }

  /// The hue of the wash, **animated**.
  ///
  /// Split from `palette.baseHue` by XIA-446: the palette is where the field
  /// is going and this is where it currently is, and during a view switch they
  /// differ for about a second. Everything that paints reads this one.
  private(set) var baseHue: Double

  /// Head for another ground, without cutting to it.
  ///
  /// The three things this deliberately does **not** do are the whole contract:
  /// no `reprime()` (which would paint the target outright), no `makeSeeds()`
  /// (which would snap all six seeds home and restart the composition), and no
  /// touch of `elapsed` (which carries the session's warmth). What moves is the
  /// wash hue, the six seed hues and `push` — nothing spatial, nothing temporal.
  ///
  /// Idempotent: asking for the ground it is already heading for changes
  /// nothing, so a view that re-appears mid-morph does not restart it.
  func morph(to palette: GroundPalette, push: Double) {
    guard morphTarget?.palette != palette || morphTarget?.push != push else { return }
    morphTarget = (palette, push)
  }

  /// Advance the animated values toward `target`.
  ///
  /// Called from `step` rather than from a clock of its own, so a field that is
  /// not being stepped — Reduce Motion, an occluded app — does not creep. The
  /// cost of that is stated plainly: under Reduce Motion a view switch is a
  /// single repaint at the new ground rather than a morph, which is the right
  /// answer for someone who asked for less motion.
  private func advanceMorph(dt: TimeInterval) {
    guard let morphTarget else { return }
    let k = GroundMorph.fraction(dt: dt)
    guard k > 0 else { return }

    baseHue = GroundMorph.hue(baseHue, toward: morphTarget.palette.baseHue, by: k)
    let hues = morphTarget.palette.familyHues
    for i in seeds.indices {
      seeds[i].hue = GroundMorph.hue(
        seeds[i].hue, toward: hues[i % hues.count], by: k)
    }
    self.push = fieldLerp(self.push, morphTarget.push, k)

    // Landing is a real state, not a limit approached forever: an exponential
    // never arrives, and a field still doing per-step hue arithmetic for a
    // switch that finished forty seconds ago is work nobody asked for. The
    // tolerance is a fifth of a degree — a quarter of the smallest hue step
    // any of the sixteen palettes are separated by.
    let landed =
      abs(GroundMorph.hue(baseHue, toward: morphTarget.palette.baseHue, by: 1) - baseHue) < 0.2
      && abs(self.push - morphTarget.push) < 0.001
    if landed {
      baseHue = morphTarget.palette.baseHue
      for i in seeds.indices { seeds[i].hue = hues[i % hues.count] }
      self.push = morphTarget.push
      self.palette = morphTarget.palette
      self.morphTarget = nil
    }
  }

  private static func makeSeeds(palette: GroundPalette) -> [Seed] {
    spots.enumerated().map { i, s in
      Seed(
        u: s.u,
        v: s.v,
        radius: 0.17 + Double((i * 37) % 5) * 0.013,
        hue: palette.familyHues[i % palette.familyHues.count],
        homeU: s.u,
        homeV: s.v)
    }
  }

  /// Paint the target outright on the next step rather than advecting into it.
  func reprime() {
    // A re-prime is a deliberate cut, so it lands the ground it is heading for
    // rather than leaving a half-travelled hue behind: an appearance flip
    // mid-morph would otherwise repaint at whatever colour the switch happened
    // to have reached and then keep crawling from there.
    if let morphTarget {
      palette = morphTarget.palette
      push = morphTarget.push
      self.morphTarget = nil
    }
    seeds = FieldSimulation.makeSeeds(palette: palette)
    baseHue = palette.baseHue
    primed = false
  }

  var theme: FieldTheme { FieldTheme.make(light: light, push: push) }
  var warmth: Double { GroundWarmth.warmth(elapsed: elapsed) }

  // MARK: The target

  /// Everything about the target that is the same for every cell of one frame.
  ///
  /// Hoisted out because it is: the six seed colours depend on the palette, the
  /// theme and the warmth, and on nothing spatial at all — so building them
  /// inside the per-cell loop was six HSV conversions per cell, 2,304 times a
  /// frame, to produce six values.
  struct FrameConstants {
    let theme: FieldTheme
    let baseHue: Double
    let baseSaturation: Double
    let seedColors: [FieldColor.RGB]
    let flatten: Double
  }

  func frameConstants() -> FrameConstants {
    let T = theme
    let w = warmth
    let seedSaturation = T.seedSaturation + w * GroundWarmth.seedSaturationLift
    return FrameConstants(
      theme: T,
      baseHue: GroundWarmth.rotate(
        hue: baseHue, amount: w * GroundWarmth.baseHuePull),
      baseSaturation: T.baseSaturation + w * GroundWarmth.baseSaturationLift,
      seedColors: seeds.map { s in
        FieldColor.rgb(
          hue: GroundWarmth.rotate(hue: s.hue, amount: w * GroundWarmth.seedHuePull),
          saturation: seedSaturation,
          value: T.seedValue)
      },
      flatten: fieldClamp(flatten, 0, 1))
  }

  /// What the field *wants* to be at this point, right now — the base wash with
  /// the six seeds laid into it, warmed, then flattened.
  ///
  /// Flatten is applied last and touches **value only**: hue and saturation come
  /// straight back out of the composite. "Hue may vary, luminance may not" is
  /// the readability principle, and this line is where it is enforced.
  func target(u: Double, v: Double) -> FieldColor.RGB {
    target(u: u, v: v, constants: frameConstants())
  }

  func target(u: Double, v: Double, constants K: FrameConstants) -> FieldColor.RGB {
    let T = K.theme
    var c = FieldColor.rgb(
      hue: K.baseHue,
      saturation: K.baseSaturation,
      value: T.bandTop - (T.bandTop - T.bandBottom) * v + T.tilt * (0.5 - u))

    for (i, s) in seeds.enumerated() {
      let du = u - s.u
      let dv = (v - s.v) * FieldSimulation.seedAspect
      let d = (du * du + dv * dv) / (s.radius * s.radius)
      let weight = exp(-d) * FieldSimulation.seedStrength
      c = FieldColor.mix(c, K.seedColors[i], weight)
    }

    return FieldColor.settingValue(of: c, to: fieldLerp(FieldColor.value(of: c), T.bandMiddle, K.flatten))
  }

  // MARK: Reading the buffer

  /// Bilinear sample of the current buffer in normalised coordinates.
  func sample(u: Double, v: Double) -> FieldColor.RGB {
    let x = fieldClamp(u * Double(width - 1), 0, Double(width - 1))
    let y = fieldClamp(v * Double(height - 1), 0, Double(height - 1))
    let x0 = Int(x), y0 = Int(y)
    let x1 = min(width - 1, x0 + 1), y1 = min(height - 1, y0 + 1)
    let tx = x - Double(x0), ty = y - Double(y0)
    var out = FieldColor.RGB()
    for k in 0..<3 {
      let a = Double(buffer[(y0 * width + x0) * 3 + k])
      let b = Double(buffer[(y0 * width + x1) * 3 + k])
      let c = Double(buffer[(y1 * width + x0) * 3 + k])
      let d = Double(buffer[(y1 * width + x1) * 3 + k])
      out[k] = fieldLerp(fieldLerp(a, b, tx), fieldLerp(c, d, tx), ty)
    }
    return out
  }

  /// The colour of one cell, straight out of the buffer.
  func color(x: Int, y: Int) -> FieldColor.RGB {
    let o = (y * width + x) * 3
    return FieldColor.RGB(Double(buffer[o]), Double(buffer[o + 1]), Double(buffer[o + 2]))
  }

  // MARK: The only mutator

  func step(dt: TimeInterval) {
    // Before anything is measured or advected: the target has to be where it
    // is going to be for *this* frame, or the frame paints one step behind the
    // switch it is showing.
    advanceMorph(dt: dt)
    elapsed += dt
    let t = elapsed
    let advect = dt * FieldSimulation.motionScale

    for i in seeds.indices {
      let s = seeds[i]
      let (vx, vy) = CurlFlow.velocity(u: s.u, v: s.v, t: t)
      seeds[i].u = fieldClamp(
        s.u + (vx + (s.homeU - s.u) * FieldSimulation.seedHoming) * advect, -0.05, 1.05)
      seeds[i].v = fieldClamp(
        s.v + (vy + (s.homeV - s.v) * FieldSimulation.seedHoming) * advect, -0.05, 1.05)
    }

    let mix = primed ? FieldSimulation.relaxation : 1.0
    let lastX = Double(width - 1), lastY = Double(height - 1)
    let K = frameConstants()
    var next = [Float](repeating: 0, count: buffer.count)

    for j in 0..<height {
      let v = Double(j) / lastY
      for i in 0..<width {
        let u = Double(i) / lastX
        let tg = target(u: u, v: v, constants: K)
        var src = tg
        if primed {
          let (vx, vy) = CurlFlow.velocity(u: u, v: v, t: t)
          src = sample(
            u: u - vx * advect,
            v: v - (vy - FieldSimulation.upwardDrift) * advect)
        }
        let o = (j * width + i) * 3
        for k in 0..<3 {
          next[o + k] = Float(fieldLerp(src[k], tg[k], mix))
        }
      }
    }

    buffer = next
    primed = true
  }
}
