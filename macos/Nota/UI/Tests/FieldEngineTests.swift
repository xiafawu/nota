import AppKit
import SwiftUI
import XCTest

@testable import Nota

/// The field engine's promises, asserted against the `[Float]` buffer rather
/// than against anything rendered. That is the point of keeping the simulation
/// free of CoreGraphics and SwiftUI: "the text is readable over every ground at
/// every moment of the flow" is a claim about numbers, and a screenshot cannot
/// answer it — the ground is drawn at random per launch, so nobody can check it
/// by eye even once.
///
/// Constants come from `.claude/design-2026-08-09/` (the prototypes are the
/// spec) and the measurements behind them are in `.claude/checkpoint-2026-08-09.md`.
final class FieldEngineTests: XCTestCase {

  /// Long enough for the advected field to have drifted well off its first
  /// frame — the failure this is looking for is a ground that reads fine when
  /// it is painted and walks somewhere unreadable ten minutes in.
  private static let frames = 600
  private static let frameStep: TimeInterval = 1.0 / 60

  // MARK: - 1. Every tier clears its bar, on every ground, all the way through

  /// **Both contrast settings are swept**, because both are drawn. Increase
  /// contrast promotes each tier one step (`GroundInk.Tier.promoted`) and the
  /// promoted tier answers to the promoted *bar*, so the raised draw is
  /// measured on the same sixteen grounds rather than assumed safe for being
  /// darker — darker is the direction, not the proof.
  func testEveryTierClearsItsBarOnEveryGroundInBothThemes() {
    struct Case: Hashable {
      let tier: GroundInk.Tier
      let contrast: ColorSchemeContrast
    }
    let cases = GroundInk.Tier.allCases.flatMap { tier in
      [ColorSchemeContrast.standard, .increased].map { Case(tier: tier, contrast: $0) }
    }
    var worst: [Case: (ratio: Double, palette: String, light: Bool)] = [:]

    for palette in GroundPalette.all {
      for light in [true, false] {
        let sim = FieldSimulation(palette: palette, light: light)
        let ink = GroundInk.ink(light: light)

        for frame in 0..<Self.frames {
          sim.step(dt: Self.frameStep)
          // Measuring every frame would triple the runtime for a field that
          // moves by a fraction of a cell per frame.
          guard frame % 25 == 0 || frame == Self.frames - 1 else { continue }

          for y in 0..<sim.height {
            for x in 0..<sim.width {
              let ground = sim.color(x: x, y: y)
              for c in cases {
                let over = FieldColor.mix(ground, ink, c.tier.alpha(c.contrast))
                let ratio = GroundInk.contrast(over, ground)
                if ratio < (worst[c]?.ratio ?? .infinity) {
                  worst[c] = (ratio, palette.id, light)
                }
              }
            }
          }
        }
      }
    }

    for c in cases {
      guard let w = worst[c] else { return XCTFail("no measurement for \(c)") }
      let bar = c.tier.minimumContrast(c.contrast)
      print(
        "[field] \(c.tier.rawValue) \(c.contrast) worst \(String(format: "%.2f", w.ratio)):1 "
          + "on \(w.palette) \(w.light ? "light" : "dark") (bar \(bar))")
      XCTAssertGreaterThanOrEqual(
        w.ratio, bar,
        "\(c.tier.rawValue) at alpha \(c.tier.alpha(c.contrast)) (\(c.contrast)) "
          + "fails on \(w.palette) \(w.light ? "light" : "dark")")
    }
  }

  /// **The 55% the volatile tail used to be drawn at was above the floor.**
  ///
  /// Pinned because the comment that replaced it said the opposite — that 55%
  /// landed "just below the 3.0:1 bar" — and the tier table three lines away
  /// says 3.0:1 needs 54% light and 40% dark. The reason to move the tail onto
  /// `.timestamp` is that 55% is an alpha *nobody swept*, sitting between two
  /// that were; it is not that it was unreadable. A reader who believes the
  /// stronger claim goes and "fixes" the HUD prompter's own 55%, which is white
  /// on a glass plate and was never in this measurement at all.
  func testTheOldFiftyFivePercentTailClearedTheFloorItWasSaidToMiss() {
    let legacyAlpha = 0.55
    var worst = Double.infinity
    var where_ = ""

    for palette in GroundPalette.all {
      for light in [true, false] {
        let sim = FieldSimulation(palette: palette, light: light)
        let ink = GroundInk.ink(light: light)
        for frame in 0..<Self.frames {
          sim.step(dt: Self.frameStep)
          guard frame % 25 == 0 || frame == Self.frames - 1 else { continue }
          for y in 0..<sim.height {
            for x in 0..<sim.width {
              let ground = sim.color(x: x, y: y)
              let ratio = GroundInk.contrast(
                FieldColor.mix(ground, ink, legacyAlpha), ground)
              if ratio < worst {
                worst = ratio
                where_ = "\(palette.id) \(light ? "light" : "dark")"
              }
            }
          }
        }
      }
    }

    print("[field] legacy 55% tail worst \(String(format: "%.2f", worst)):1 on \(where_)")
    XCTAssertGreaterThanOrEqual(
      worst, GroundInk.Tier.timestamp.minimumContrast,
      "55% really is under the 3.0:1 floor on \(where_) — the tier table's "
        + "'needs light 54%' is wrong and the sweep has to be redone")
    XCTAssertLessThan(
      legacyAlpha, GroundInk.Tier.timestamp.alpha,
      "the tail's old alpha is no longer below the tier it was folded into")
  }

  // MARK: - 2. Flatten 0.40 leaves the field photographic

  /// The guard against re-flattening this back into paint. Push is what buys
  /// the contrast; flatten is a tax on exactly this number, and the measured
  /// trade is 0.32 of contrast for 15.5 points of luminance variation.
  ///
  /// **Two spans, and confusing them is why the first bar here was wrong.** The
  /// checkpoint's "9.3pt at flatten 40" is the span of all sixteen grounds
  /// *pooled into one sample* (`sweep.mjs` line 37 concatenates every palette
  /// before measuring), so it includes the variation *between* grounds. The
  /// span within any single ground is smaller — 5.9pt on `ink` light in the
  /// reference, which is what this reproduces. A per-ground bar of 8 was the
  /// pooled number applied to a stricter measure, and it failed a faithful
  /// implementation. Both are asserted below, at their own floors.
  func testLuminanceVariationSurvivesAtFlattenForty() {
    var worstSpan = Double.infinity
    var worstID = ""
    var pooledLo = 1.0, pooledHi = 0.0

    for palette in GroundPalette.all {
      for light in [true, false] {
        let sim = FieldSimulation(palette: palette, light: light)
        for _ in 0..<120 { sim.step(dt: Self.frameStep) }

        var lo = 1.0, hi = 0.0
        for y in 0..<sim.height {
          for x in 0..<sim.width {
            let v = FieldColor.hsv(sim.color(x: x, y: y)).value
            lo = min(lo, v)
            hi = max(hi, v)
          }
        }
        // Pooled span is per theme; the two bands barely overlap, so mixing
        // them would measure the theme switch rather than the field.
        if light {
          pooledLo = min(pooledLo, lo)
          pooledHi = max(pooledHi, hi)
        }
        let span = (hi - lo) * 100
        if span < worstSpan {
          worstSpan = span
          worstID = "\(palette.id) \(light ? "light" : "dark")"
        }
      }
    }

    let pooled = (pooledHi - pooledLo) * 100
    print(
      "[field] narrowest single ground \(String(format: "%.1f", worstSpan))pt on \(worstID); "
        + "pooled light \(String(format: "%.1f", pooled))pt")

    // Reference floor is 5.9 (`ink`, light). Bar set below it, not at it — this
    // is a guard against someone raising flatten, not a pin on the arithmetic.
    XCTAssertGreaterThanOrEqual(
      worstSpan, 5.0,
      "flatten has been raised — \(worstID) reads as flat paint, not a photograph")
    // And the number the checkpoint quotes, measured the way it was measured.
    XCTAssertGreaterThanOrEqual(pooled, 8.0)
  }

  /// And the trade itself, so the next person to reach for the flatten slider
  /// sees what it costs before they move it.
  func testFlattenBuysAlmostNoContrastAndSpendsTheWholeBand() {
    func measure(flatten: Double) -> (contrast: Double, span: Double) {
      var worst = Double.infinity, lo = 1.0, hi = 0.0
      for palette in GroundPalette.all {
        let sim = FieldSimulation(palette: palette, light: true, flatten: flatten)
        for _ in 0..<60 { sim.step(dt: Self.frameStep) }
        for y in 0..<sim.height {
          for x in 0..<sim.width {
            let ground = sim.color(x: x, y: y)
            let v = FieldColor.hsv(ground).value
            lo = min(lo, v)
            hi = max(hi, v)
            worst = min(worst, GroundInk.contrast(of: .body, over: ground, light: true))
          }
        }
      }
      return (worst, (hi - lo) * 100)
    }

    let flat = measure(flatten: 1.0)
    let soft = measure(flatten: 0.0)
    print(
      "[field] flatten 0 -> \(String(format: "%.2f", soft.contrast)):1, "
        + "\(String(format: "%.1f", soft.span))pt | flatten 1 -> "
        + "\(String(format: "%.2f", flat.contrast)):1, \(String(format: "%.1f", flat.span))pt")

    XCTAssertLessThan(
      abs(flat.contrast - soft.contrast), 1.0,
      "flatten moved contrast by more than a point — the measured trade has changed")
    XCTAssertGreaterThan(
      soft.span - flat.span, 8.0,
      "flatten no longer costs the band — check whether push is still doing the work")
  }

  // MARK: - 3. Warming

  func testWarmthIsMonotonicAndBounded() {
    XCTAssertEqual(GroundWarmth.warmth(elapsed: 0), 0, accuracy: 1e-12)
    XCTAssertEqual(GroundWarmth.warmth(elapsed: -10), 0, accuracy: 1e-12)

    var previous = -1.0
    for second in stride(from: 0.0, through: 7200, by: 5) {
      let w = GroundWarmth.warmth(elapsed: second)
      XCTAssertGreaterThan(w, previous, "warmth went backwards at \(second)s")
      XCTAssertLessThanOrEqual(w, 1.0)
      previous = w
    }
    // The nine-minute time constant, spelled out so a change to it is visible.
    XCTAssertEqual(GroundWarmth.warmth(elapsed: 540), 1 - 1 / M_E, accuracy: 1e-9)
  }

  /// Rotation takes the short way round. A hue that travels the long arc
  /// crosses the far side of the wheel and every intermediate is mud.
  func testWarmingRotatesTheShortWayRound() {
    // 350 deg is 50 deg *below* the 40 deg anchor going forwards, not 310 back.
    XCTAssertEqual(GroundWarmth.rotate(hue: 350, amount: 1.0), 400, accuracy: 1e-9)
    XCTAssertEqual(GroundWarmth.rotate(hue: 350, amount: 0.5), 375, accuracy: 1e-9)
    // 250 deg is 150 deg *forward* to the anchor, not 210 back — so it lands on
    // 400, which is 40 on the wheel. The value is deliberately left unwrapped:
    // the direction of travel is the thing being asserted, and wrapping it away
    // would make "the short way round" untestable.
    XCTAssertEqual(GroundWarmth.rotate(hue: 250, amount: 1.0), 400, accuracy: 1e-9)
    // 100 deg is 60 deg back.
    XCTAssertEqual(GroundWarmth.rotate(hue: 100, amount: 1.0), 40, accuracy: 1e-9)
    // Never more than a half turn, whichever way it goes.
    for h in stride(from: 0.0, to: 360, by: 3) {
      XCTAssertLessThanOrEqual(abs(GroundWarmth.rotate(hue: h, amount: 1.0) - h), 180)
    }
    // Full warmth always lands on the anchor, whatever the starting hue.
    for h in stride(from: 0.0, to: 360, by: 7) {
      let landed = GroundWarmth.rotate(hue: h, amount: 1.0)
      let onWheel = (landed.truncatingRemainder(dividingBy: 360) + 360)
        .truncatingRemainder(dividingBy: 360)
      XCTAssertEqual(onWheel, GroundWarmth.anchorHue, accuracy: 1e-9)
    }
  }

  /// **The ember rule, measured rather than asserted as a hue window.**
  ///
  /// The plan asked for "never inside 12-34 degrees" and that was never true of
  /// the shipping palettes: `kiln` has a base hue of 30 and sits inside that
  /// band from the first frame at warmth zero. Hue is the wrong axis. What
  /// actually separates the ground from the recording accent is **saturation** —
  /// the ground tops out around 38% (light) / 50% (dark), ember is at 80% — so
  /// the honest test is the perceptual distance, in Lab, at every warmth.
  func testTheGroundNeverComesNearEmber() {
    let embers: [Bool: FieldColor.RGB] = [
      true: FieldColor.RGB(0xD1, 0x66, 0x2A),  // CraftTokens.ember, light
      false: FieldColor.RGB(0xE8, 0x82, 0x3A),  // CraftTokens.ember, dark
    ]
    var closest = Double.infinity
    var where_ = ""

    for palette in GroundPalette.all {
      for light in [true, false] {
        let sim = FieldSimulation(palette: palette, light: light)
        // Warmth zero, ten minutes, half an hour, two hours.
        for warmSeconds in [0.0, 600, 1800, 7200] {
          sim.step(dt: warmSeconds - sim.elapsed)
          let K = sim.frameConstants()
          for j in 0..<24 {
            for i in 0..<24 {
              let c = sim.target(
                u: Double(i) / 23, v: Double(j) / 23, constants: K)
              let d = Self.deltaE(c, embers[light]!)
              if d < closest {
                closest = d
                where_ = "\(palette.id) \(light ? "light" : "dark") @\(Int(warmSeconds))s"
              }
            }
          }
        }
      }
    }

    print("[field] closest approach to ember: dE \(String(format: "%.1f", closest)) on \(where_)")
    XCTAssertGreaterThan(
      closest, 20.0,
      "the ground got within dE \(closest) of ember on \(where_) — ember means the "
        + "microphone is open and the ground may not spend that signal")
  }

  // MARK: - 4. The draw

  func testPickNeverReturnsTheExcludedGround() {
    for excluded in GroundPalette.all {
      var rng = SplitMix64(seed: 0xF1E1_D000 &+ UInt64(abs(excluded.id.hashValue % 9973)))
      for _ in 0..<200 {
        let drawn = GroundPalette.pick(excluding: excluded.id, using: &rng)
        XCTAssertNotEqual(drawn.id, excluded.id)
      }
    }
  }

  /// An unknown id excludes nothing and still returns a ground, so a palette
  /// retired between launches cannot wedge the draw.
  func testPickSurvivesAnUnknownExclusion() {
    var rng = SplitMix64(seed: 7)
    let drawn = GroundPalette.pick(excluding: "a-ground-that-was-retired", using: &rng)
    XCTAssertTrue(GroundPalette.all.contains(drawn))
  }

  func testPickIsReproducibleForASeed() {
    var a = SplitMix64(seed: 424_242)
    var b = SplitMix64(seed: 424_242)
    let first = (0..<40).map { _ in GroundPalette.pick(excluding: nil, using: &a).id }
    let second = (0..<40).map { _ in GroundPalette.pick(excluding: nil, using: &b).id }
    XCTAssertEqual(first, second)
    // And it is actually drawing, not returning the same entry every time.
    XCTAssertGreaterThan(Set(first).count, 5)
  }

  func testEveryGroundHasThreeFamiliesAndAUniqueID() {
    XCTAssertEqual(GroundPalette.all.count, 16)
    XCTAssertEqual(Set(GroundPalette.all.map(\.id)).count, 16)
    for p in GroundPalette.all {
      XCTAssertEqual(p.familyHues.count, 3, "\(p.id)")
      XCTAssertTrue((0..<360).contains(Int(p.baseHue)), "\(p.id)")
    }
  }

  // MARK: - 5. Cost

  /// 115 µs measured on an M1 Pro with `swiftc -O`, which is 0.35% of a 33 ms
  /// frame and the whole reason there is no Metal in this feature.
  ///
  /// **The 400 µs bar only means anything in an optimized build.** Unoptimized
  /// Swift runs this loop about seventy times slower — bounds checks, no
  /// inlining of `CurlFlow.velocity`, `SIMD3` arithmetic going through generic
  /// witnesses — so a Debug measurement of ~8.7 ms says nothing about the
  /// shipping cost, and asserting 400 against it would just be a red test that
  /// everyone learns to ignore. Debug gets a loose bar that still catches an
  /// actual algorithmic regression (something quadratic in the cell count), and
  /// the real claim is checked whenever the suite runs against Release.
  func testStepStaysWithinItsFrameBudget() {
    let sim = FieldSimulation(palette: GroundPalette.all[0], light: true)
    sim.step(dt: Self.frameStep)  // prime, so the measured steps all advect

    let iterations = 120
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations { sim.step(dt: Self.frameStep) }
    let each = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(iterations) / 1000

    #if DEBUG
      let bar = 25_000.0
      let build = "debug"
    #else
      let bar = 400.0
      let build = "release"
    #endif
    print("[field] step \(String(format: "%.0f", each)) us at \(sim.width)x\(sim.height) (\(build))")
    XCTAssertLessThan(each, bar, "step is \(each) us at 64x36 in a \(build) build")
  }

  // MARK: - Shape

  func testStepIsTheOnlyThingThatMovesTheField() {
    let sim = FieldSimulation(palette: GroundPalette.all[3], light: false)
    sim.step(dt: Self.frameStep)
    let before = sim.buffer
    _ = sim.target(u: 0.5, v: 0.5)
    _ = sim.sample(u: 0.5, v: 0.5)
    _ = FieldImage.makeImage(from: sim)
    XCTAssertEqual(before, sim.buffer)
    sim.step(dt: Self.frameStep)
    XCTAssertNotEqual(before, sim.buffer)
  }

  func testChangingTheThemeRepaintsRatherThanAdvectsAcross() {
    let sim = FieldSimulation(palette: GroundPalette.all[5], light: true)
    for _ in 0..<30 { sim.step(dt: Self.frameStep) }
    let lightMean = Self.meanValue(sim)
    sim.light = false
    sim.step(dt: Self.frameStep)
    let darkMean = Self.meanValue(sim)
    // One step, not fifty: a re-prime paints the target outright, so the band
    // has already moved. Relaxing across at 7% a frame would leave it light.
    XCTAssertLessThan(darkMean, lightMean - 0.2)
  }

  func testFieldImageIsBuiltAtTheSimulationSize() {
    let sim = FieldSimulation(palette: GroundPalette.all[9], light: true)
    sim.step(dt: Self.frameStep)
    let image = FieldImage.makeImage(from: sim)
    XCTAssertEqual(image?.width, 64)
    XCTAssertEqual(image?.height, 36)
    XCTAssertNil(FieldImage.makeImage(from: [0, 0, 0], width: 64, height: 36))
  }

  func testColorRoundTripsThroughHSV() {
    for h in stride(from: 0.0, to: 360, by: 11) {
      for s in [0.0, 0.28, 0.55, 1.0] {
        for v in [0.12, 0.5, 0.94] {
          let rgb = FieldColor.rgb(hue: h, saturation: s, value: v)
          let back = FieldColor.hsv(rgb)
          XCTAssertEqual(back.value, v, accuracy: 1e-9)
          XCTAssertEqual(back.saturation, s, accuracy: 1e-9)
          if s > 0 { XCTAssertEqual(back.hue, h, accuracy: 1e-6) }
        }
      }
    }
  }

  // MARK: - Helpers

  private static func meanValue(_ sim: FieldSimulation) -> Double {
    var total = 0.0
    for y in 0..<sim.height {
      for x in 0..<sim.width { total += FieldColor.hsv(sim.color(x: x, y: y)).value }
    }
    return total / Double(sim.width * sim.height)
  }

  /// CIE76. Enough for "is this anywhere near ember" — the threshold in play is
  /// twenty times the just-noticeable difference, not one.
  private static func deltaE(_ a: FieldColor.RGB, _ b: FieldColor.RGB) -> Double {
    let la = lab(a), lb = lab(b)
    let d = la - lb
    return (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
  }

  private static func lab(_ c: FieldColor.RGB) -> SIMD3<Double> {
    func linear(_ u: Double) -> Double {
      let x = u / 255
      return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }
    let r = linear(c.x), g = linear(c.y), b = linear(c.z)
    // sRGB D65
    var xyz = SIMD3<Double>(
      0.4124 * r + 0.3576 * g + 0.1805 * b,
      0.2126 * r + 0.7152 * g + 0.0722 * b,
      0.0193 * r + 0.1192 * g + 0.9505 * b)
    xyz /= SIMD3<Double>(0.95047, 1.0, 1.08883)
    func f(_ t: Double) -> Double {
      t > 0.008856 ? pow(t, 1.0 / 3) : (7.787 * t + 16.0 / 116)
    }
    let fx = f(xyz.x), fy = f(xyz.y), fz = f(xyz.z)
    return SIMD3<Double>(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
  }
}

// MARK: - The ink, on the screen

/// The other half of the solve: `GroundInk`'s four tiers were measured against
/// every ground in both themes, and until XIA-443 not one of them reached a
/// pixel — the surfaces that sit on the field drew at SwiftUI's `.primary` /
/// `.secondary` / `.tertiary`, which are contrasts nobody measured against a
/// ground that moves.
///
/// Rendered rather than asserted about constants wherever the claim is about
/// what is on the screen, for the reason `testTheIdlePaneDrawsNoEmber` is: a
/// call site that quietly went back to `.primary` would pass every assertion
/// that only asked the type what it thinks its colours are.
@MainActor
final class GroundInkTests: XCTestCase {

  /// A real ground, not a made-up grey: the tiers were solved on these cells and
  /// a mid-band one is what the transcript is actually read over.
  private func ground(light: Bool) -> FieldColor.RGB {
    let sim = FieldSimulation(palette: GroundPalette.all[0], light: light)
    for _ in 0..<30 { sim.step(dt: 1.0 / 60) }
    return sim.color(x: sim.width / 2, y: sim.height / 2)
  }

  private func swiftUIColor(_ rgb: FieldColor.RGB) -> Color {
    Color(.sRGB, red: rgb.x / 255, green: rgb.y / 255, blue: rgb.z / 255)
  }

  // MARK: 1. Every tier resolves to the solved alpha, in both themes

  /// The whole point of one accessor: the alpha a view draws with is the alpha
  /// the sweep measured, not a plausible-looking number typed beside it. (A
  /// plausible 52% timestamp measured 2.81:1 against a 3.0 bar — see
  /// `GroundInk`'s table.)
  func testEveryTierResolvesToTheInkAtItsSolvedAlpha() {
    for scheme in [ColorScheme.light, .dark] {
      var environment = EnvironmentValues()
      environment.colorScheme = scheme
      let expected = GroundInk.ink(light: scheme == .light)

      for tier in GroundInk.Tier.allCases {
        let resolved = GroundInkStyle(tier: tier).resolve(in: environment)
        guard let ns = NSColor(resolved).usingColorSpace(.sRGB) else {
          return XCTFail("\(tier) did not resolve to an sRGB colour")
        }
        XCTAssertEqual(Double(ns.redComponent) * 255, expected.x, accuracy: 0.6, "\(tier)")
        XCTAssertEqual(Double(ns.greenComponent) * 255, expected.y, accuracy: 0.6, "\(tier)")
        XCTAssertEqual(Double(ns.blueComponent) * 255, expected.z, accuracy: 0.6, "\(tier)")
        XCTAssertEqual(
          Double(ns.alphaComponent), tier.alpha, accuracy: 1e-6,
          "\(tier) is drawn at an alpha the sweep never measured")
      }
    }
  }

  /// **Increase contrast reaches the ink.**
  ///
  /// Fixed alphas silently took a system setting away: `.secondary` and
  /// `.tertiary` resolve through `NSColor`'s label colours, which macOS
  /// substitutes with higher-contrast variants under System Settings →
  /// Accessibility → Display → Increase contrast, and a constant cannot. So
  /// every tier promotes (`Tier.promoted`) and the two dimmest — the gutter
  /// timestamps and the volatile in-flight line, the ones that were pinned at
  /// 3.0:1 while the owner asked for more — get strictly more ink.
  ///
  /// Asserted through `GroundInk.color(_:_:_:)` rather than through
  /// `resolve(in:)`: `EnvironmentValues.colorSchemeContrast` is get-only, so
  /// there is no way to hand the style the increased case. The style's own
  /// wiring is one line and is covered by the standard-case test above.
  func testIncreasedContrastPromotesEveryTierAndDarkensTheDimOnes() {
    for scheme in [ColorScheme.light, .dark] {
      for tier in GroundInk.Tier.allCases {
        let standard = NSColor(GroundInk.color(tier, scheme, .standard))
        let increased = NSColor(GroundInk.color(tier, scheme, .increased))
        XCTAssertEqual(
          Double(increased.alphaComponent), tier.promoted.alpha, accuracy: 1e-6,
          "\(tier) does not draw at its promoted tier under increased contrast")
        XCTAssertGreaterThanOrEqual(
          Double(increased.alphaComponent), Double(standard.alphaComponent),
          "\(tier) got *less* ink when the owner asked for more contrast")
        XCTAssertGreaterThanOrEqual(
          tier.minimumContrast(.increased), tier.minimumContrast,
          "\(tier)'s increased bar is lower than its ordinary one")
      }

      // The two the finding was actually about: below AA's 4.5:1 for body text
      // at the ordinary setting, and they may not stay there.
      for tier in [GroundInk.Tier.timestamp, .rail] {
        XCTAssertGreaterThan(
          tier.alpha(.increased), tier.alpha,
          "\(tier) is unchanged by increased contrast")
      }
    }
  }

  /// **The surface composites a tier by lerping to the ink at exactly that
  /// tier's alpha** — which is the assumption every bar in `GroundInk`'s table
  /// rests on. `composite(_:over:light:)` is `FieldColor.mix`, a straight
  /// per-channel lerp; if the compositor were working in linear light instead,
  /// every partial-alpha tier would land lighter than it was measured and the
  /// 3.0:1 timestamp would be the first to fall through its floor.
  ///
  /// Asserted against **rendered swatches** of the two endpoints rather than
  /// against the numbers that were asked for, and in the bitmap's **own**
  /// components rather than converted to sRGB. Both are the same correction: the
  /// probe's rep is Generic RGB (gamma 1.8), so an sRGB reading of a 50%
  /// composite comes back 145 where the compositor wrote 127 — a difference that
  /// looks exactly like linear-light blending and is nothing but the round trip.
  /// Endpoints measured the same way, the lerp is a claim about the compositor
  /// and not about anybody's colour space.
  func testTheSurfaceCompositesEachTierAtExactlyItsAlpha() {
    for light in [true, false] {
      let scheme: ColorScheme = light ? .light : .dark
      let g = ground(light: light)
      guard
        let groundEnd = Self.swatch(over: g, ink: nil, scheme: scheme),
        // The body tier is the ink at alpha 1, so it *is* the far endpoint.
        let inkEnd = Self.swatch(over: g, ink: .body, scheme: scheme)
      else { return XCTFail("the hosting view produced no bitmap") }

      for tier in GroundInk.Tier.allCases {
        guard let drawn = Self.swatch(over: g, ink: tier, scheme: scheme) else {
          return XCTFail("the hosting view produced no bitmap")
        }
        let expected = groundEnd + (inkEnd - groundEnd) * tier.alpha
        XCTAssertEqual(drawn.x, expected.x, accuracy: 1.5, "\(tier) \(scheme)")
        XCTAssertEqual(drawn.y, expected.y, accuracy: 1.5, "\(tier) \(scheme)")
        XCTAssertEqual(drawn.z, expected.z, accuracy: 1.5, "\(tier) \(scheme)")
      }
    }
  }

  // MARK: 2. The surface that sits on the ground draws with it

  /// **The live transcript is inked, not labelled.**
  ///
  /// The discriminating measurement, and it took two false starts to find one.
  /// "No glyph is darker than the ink" was the first, and it cannot fail:
  /// `.primary` resolves to `labelColor`, which is black at 85% — *lighter* than
  /// `#1C1A16` at full strength — so the surface this ticket found was already
  /// inside that bound. An equality against the composite is no good either: no
  /// glyph reaches full coverage at 14pt, so the extreme pixel is always some
  /// way short of the tier's own colour.
  ///
  /// What does separate them is which colour the extreme pixel is reaching
  /// *for*. The body tier is the ink at alpha 1, so the darkest thing the
  /// transcript can draw is the ink swatch, and `labelColor` bottoms out a long
  /// way short of it. Both are rendered here, in the same probe, at the same
  /// font and over the same ground — so the bar cannot rot as fonts, smoothing
  /// or the rep's colour space change. Only the ratio between two things
  /// measured together is asserted.
  func testTheTranscriptIsInkedAndNotLabelled() {
    for scheme in [ColorScheme.light, .dark] {
      let light = scheme == .light
      let g = ground(light: light)
      guard
        let inkEnd = Self.swatch(over: g, ink: .body, scheme: scheme),
        let transcript = renderTranscript(over: g, scheme: scheme),
        let labelled = RenderProbe.bitmap(
          ZStack {
            swiftUIColor(g)
            Text("Right, so the migration lands next Tuesday.")
              .font(RecordingPaneMetrics.transcriptFont)
              .foregroundStyle(.primary)
          }
          .environment(\.colorScheme, scheme),
          size: CGSize(width: 420, height: 60))
      else { return XCTFail("the hosting view produced no bitmap") }

      let ink = Self.tone(inkEnd)
      let drawn = Self.extremeTone(transcript, darkest: light)
      let system = Self.extremeTone(labelled, darkest: light)
      print("[ink] \(scheme): transcript \(drawn), ink \(ink), labelColor \(system)")

      XCTAssertLessThan(
        abs(drawn - ink), abs(system - ink) / 3,
        "the transcript's extreme glyph is nearer the system label colour than "
          + "the measured ink — a call site is back on .primary/.secondary")
    }
  }

  // MARK: Helpers

  /// One tier drawn over one ground, read back in the bitmap's **own**
  /// components (×255) and never converted. `ink: nil` is the bare ground, which
  /// is the near endpoint of the lerp.
  private static func swatch(
    over g: FieldColor.RGB, ink tier: GroundInk.Tier?, scheme: ColorScheme
  ) -> FieldColor.RGB? {
    guard
      let rep = RenderProbe.bitmap(
        ZStack {
          Color(.sRGB, red: g.x / 255, green: g.y / 255, blue: g.z / 255)
          if let tier { Rectangle().fill(.ground(tier)) }
        }
        .environment(\.colorScheme, scheme),
        size: CGSize(width: 24, height: 24)),
      let pixel = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)
    else { return nil }
    return FieldColor.RGB(
      Double(pixel.redComponent) * 255,
      Double(pixel.greenComponent) * 255,
      Double(pixel.blueComponent) * 255)
  }

  /// A one-number stand-in for "how dark this is", in the rep's own components.
  /// Deliberately **not** WCAG luminance: that weights the channels for human
  /// vision, and what is compared here is two renders of the same glyphs in two
  /// near-neutral colours, on a surface whose bars were already measured
  /// properly by the sweep at the top of this file.
  private static func tone(_ c: FieldColor.RGB) -> Double { (c.x + c.y + c.z) / 3 }

  private static func extremeTone(_ rep: NSBitmapImageRep, darkest: Bool) -> Double {
    var extreme = darkest ? Double.infinity : -.infinity
    for x in 0..<rep.pixelsWide {
      for y in 0..<rep.pixelsHigh {
        guard let pixel = rep.colorAt(x: x, y: y) else { continue }
        let t = tone(
          FieldColor.RGB(
            Double(pixel.redComponent) * 255,
            Double(pixel.greenComponent) * 255,
            Double(pixel.blueComponent) * 255))
        extreme = darkest ? min(extreme, t) : max(extreme, t)
      }
    }
    return extreme
  }

  private func renderTranscript(
    over g: FieldColor.RGB, scheme: ColorScheme
  ) -> NSBitmapImageRep? {
    let lines = [
      LiveTranscriptLine(
        id: UUID(), text: "Right, so the migration lands next Tuesday.", endTime: 12,
        speaker: "Amara"),
      LiveTranscriptLine(
        id: UUID(), text: "We still owe the rollback note.", endTime: 19, speaker: "Amara"),
      LiveTranscriptLine(
        id: UUID(), text: "I can write that this afternoon.", endTime: 27, speaker: "Kenny"),
      LiveTranscriptLine(
        id: LiveTranscript.volatileLineID, text: "and I'll ping the on-call", endTime: 31,
        speaker: "Kenny", isVolatile: true),
    ]
    let rows = LiveTranscript.rows(LiveTranscript.blocks(lines))
    return RenderProbe.bitmap(
      ZStack {
        swiftUIColor(g)
        LiveTranscriptView(rows: rows, volatileID: LiveTranscript.volatileLineID)
      }
      .environment(\.colorScheme, scheme),
      size: CGSize(width: 620, height: 300))
  }
}

/// A seeded generator, so "the draw is reproducible" is a fact rather than a
/// hope. `SystemRandomNumberGenerator` cannot be pinned, which is exactly why
/// `GroundPalette.pick` takes one instead of reaching for it.
struct SplitMix64: RandomNumberGenerator {
  private var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
