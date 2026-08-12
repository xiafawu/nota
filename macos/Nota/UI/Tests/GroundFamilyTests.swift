import XCTest

@testable import Nota

/// XIA-446: the launch draws a family, each view wears one of its three
/// grounds, and switching view morphs rather than cuts.
///
/// Everything here runs on the simulation directly — no engine clock, no
/// window server, no `dispatchMain`. That is the same bargain the rest of the
/// field suite makes and the reason these are assertions about numbers rather
/// than screenshots.
final class GroundFamilyTests: XCTestCase {

  private static let frameStep: TimeInterval = 0.05

  // MARK: - 1. The table

  /// Every id in every family resolves. `palette(for:)` falls back rather than
  /// trapping, so without this a typo in the table would ship as one silently
  /// wrong colour.
  func testEveryFamilyNamesThreeRealPalettes() {
    for family in GroundFamily.all {
      XCTAssertEqual(
        family.paletteIDs.count, GroundRole.allCases.count,
        "\(family.id) does not name one palette per role")
      for id in family.paletteIDs {
        XCTAssertNotNil(
          GroundPalette.palette(id: id),
          "\(family.id) names '\(id)', which is not a palette")
      }
    }
  }

  func testFamilyIDsAreUnique() {
    let ids = GroundFamily.all.map(\.id)
    XCTAssertEqual(Set(ids).count, ids.count, "two families share an id")
  }

  /// The three grounds of one family must be three *different* grounds. A
  /// family that repeated a palette would give two views the same colour and
  /// the morph between them would be a no-op that looks like a bug.
  func testNoFamilyRepeatsAGround() {
    for family in GroundFamily.all {
      XCTAssertEqual(
        Set(family.paletteIDs).count, 3,
        "\(family.id) uses the same ground for two views")
    }
  }

  // MARK: - 2. The constraints the seven were chosen under

  /// The separation measure the selection used: 65% base-hue arc, 35% the mean
  /// arc between the two palettes' seed hues. The seed term is what stops
  /// `tidepool` and `quarry` — same 190° base, very different families — from
  /// being scored as one colour.
  private static func separation(_ a: GroundPalette, _ b: GroundPalette) -> Double {
    func arc(_ x: Double, _ y: Double) -> Double {
      let d = abs(x - y).truncatingRemainder(dividingBy: 360)
      return min(d, 360 - d)
    }
    let base = arc(a.baseHue, b.baseHue)
    var famSum = 0.0
    for u in a.familyHues {
      for v in b.familyHues { famSum += arc(u, v) }
    }
    let fam = famSum / Double(a.familyHues.count * b.familyHues.count)
    return 0.65 * base + 0.35 * fam
  }

  /// Both ends of the window, which is the whole design of a "family".
  ///
  /// The floor is what makes the three views actually look different — below
  /// it the change buys nothing. The ceiling is what keeps them a chord: the
  /// highest-scoring triple in the entire set (`lichen`/`harbour`/`bloom` at
  /// 108.6) is three unrelated colours that happen to be far apart, and a
  /// family of those would read as three different apps.
  func testEveryFamilyIsRelatedButDistinguishable() {
    var tightest = (Double.infinity, "")
    var loosest = (0.0, "")

    for family in GroundFamily.all {
      let palettes = GroundRole.allCases.map { family.palette(for: $0) }
      for i in 0..<palettes.count {
        for j in (i + 1)..<palettes.count {
          let d = Self.separation(palettes[i], palettes[j])
          let where_ = "\(family.id): \(palettes[i].id)/\(palettes[j].id)"
          if d < tightest.0 { tightest = (d, where_) }
          if d > loosest.0 { loosest = (d, where_) }
        }
      }
    }

    print(
      "[family] tightest \(String(format: "%.1f", tightest.0)) on \(tightest.1); "
        + "loosest \(String(format: "%.1f", loosest.0)) on \(loosest.1)")

    XCTAssertGreaterThanOrEqual(
      tightest.0, 45,
      "\(tightest.1) is too close — those two views will read as the same room")
    XCTAssertLessThanOrEqual(
      loosest.0, 98,
      "\(loosest.1) is too far apart — that is three colours, not a family")
  }

  /// Without this the search returns four near-copies of the same violet
  /// family, all built around `dusk` and `nocturne`, and a launch would feel
  /// like it kept drawing the same ground.
  func testNoTwoFamiliesShareMoreThanOneGround() {
    for i in 0..<GroundFamily.all.count {
      for j in (i + 1)..<GroundFamily.all.count {
        let a = Set(GroundFamily.all[i].paletteIDs)
        let b = Set(GroundFamily.all[j].paletteIDs)
        XCTAssertLessThanOrEqual(
          a.intersection(b).count, 1,
          "\(GroundFamily.all[i].id) and \(GroundFamily.all[j].id) are near-copies")
      }
    }
  }

  // MARK: - 3. The draw

  func testPickNeverReturnsTheExcludedFamily() {
    for excluded in GroundFamily.all {
      var rng = SystemRandomNumberGenerator()
      for _ in 0..<200 {
        let drawn = GroundFamily.pick(excluding: excluded.id, using: &rng)
        XCTAssertNotEqual(drawn.id, excluded.id)
      }
    }
  }

  func testPickSurvivesAnUnknownExclusion() {
    var rng = SystemRandomNumberGenerator()
    let drawn = GroundFamily.pick(excluding: "a-family-that-was-retired", using: &rng)
    XCTAssertTrue(GroundFamily.all.contains(drawn))
  }

  // MARK: - 4. The morph

  /// The whole point, and the assertion that would have failed on the obvious
  /// implementation: a view switch must not paint the new ground outright.
  ///
  /// `reprime()` is what produces a cut, and calling the old `palette` setter
  /// was the way to get one for free. So this measures the *size of the jump*
  /// in the first frame after the switch and requires it to be small, then
  /// requires the field to have actually arrived later.
  func testAViewSwitchMorphsAndDoesNotCut() {
    let family = GroundFamily.family(id: "deepwater")!
    let sim = FieldSimulation(
      palette: family.palette(for: .home), light: true, push: GroundRole.home.push)
    for _ in 0..<120 { sim.step(dt: Self.frameStep) }

    let before = Self.snapshot(sim)
    sim.morph(to: family.palette(for: .transcript), push: GroundRole.transcript.push)
    sim.step(dt: Self.frameStep)
    let firstFrame = Self.snapshot(sim)

    for _ in 0..<200 { sim.step(dt: Self.frameStep) }
    let after = Self.snapshot(sim)

    let jump = Self.meanDistance(before, firstFrame)
    let travelled = Self.meanDistance(before, after)

    print(
      "[family] first frame moved \(String(format: "%.2f", jump)), "
        + "whole morph moved \(String(format: "%.2f", travelled))")

    XCTAssertLessThan(
      jump, travelled * 0.25,
      "the first frame after a view switch jumped most of the way — something "
        + "re-primed, and the ground cut instead of morphing")
    XCTAssertGreaterThan(
      travelled, 6,
      "the ground never actually changed colour — the morph moved nothing")
  }

  /// A morph leaves the composition alone. Rebuilding the seeds is the other
  /// way to cut, and it is invisible in a colour measurement because the
  /// colours end up right — it is the *positions* that snap back to minute
  /// zero.
  func testAViewSwitchDoesNotMoveTheSeedsHome() {
    let family = GroundFamily.all[0]
    let sim = FieldSimulation(
      palette: family.palette(for: .home), light: true, push: GroundRole.home.push)
    for _ in 0..<200 { sim.step(dt: Self.frameStep) }

    let drifted = sim.seeds.map { ($0.u, $0.v) }
    sim.morph(to: family.palette(for: .recording), push: GroundRole.recording.push)
    sim.step(dt: Self.frameStep)

    for (i, seed) in sim.seeds.enumerated() {
      // One step of ordinary drift is allowed; a rebuild is not.
      XCTAssertEqual(seed.u, drifted[i].0, accuracy: 0.02, "seed \(i) jumped in u")
      XCTAssertEqual(seed.v, drifted[i].1, accuracy: 0.02, "seed \(i) jumped in v")
    }
  }

  /// Warmth is the session's, not the view's. A switch that reset `elapsed`
  /// would hand a forty-minute meeting a ground that had just started warming.
  func testAViewSwitchKeepsTheSessionsWarmth() {
    let family = GroundFamily.all[0]
    let sim = FieldSimulation(
      palette: family.palette(for: .home), light: true, push: GroundRole.home.push)
    sim.step(dt: 1800)
    let warm = sim.warmth

    sim.morph(to: family.palette(for: .transcript), push: GroundRole.transcript.push)
    sim.step(dt: Self.frameStep)

    XCTAssertEqual(sim.warmth, warm, accuracy: 0.001, "the switch cost the session its warmth")
  }

  /// It arrives, rather than approaching forever. An exponential never lands on
  /// its own, and a field still doing hue arithmetic for a switch that finished
  /// a minute ago is work nobody asked for.
  func testTheMorphLands() {
    let family = GroundFamily.family(id: "nightfall")!
    let sim = FieldSimulation(
      palette: family.palette(for: .home), light: true, push: GroundRole.home.push)
    sim.step(dt: Self.frameStep)

    let destination = family.palette(for: .transcript)
    sim.morph(to: destination, push: GroundRole.transcript.push)
    for _ in 0..<200 { sim.step(dt: Self.frameStep) }

    XCTAssertEqual(sim.palette, destination, "the morph never landed on its destination")
    XCTAssertEqual(sim.push, GroundRole.transcript.push, accuracy: 0.0001)
  }

  // MARK: - 5. Readability is push's job, and flatten's floor is why

  /// The measurement that decided the design, kept as a test so the next person
  /// to reach for a per-view `flatten` finds the answer instead of the slider.
  ///
  /// 0.40 already sits at ~5.3 points of span against a floor of 5.0. Every
  /// raise measured below it (0.45 → 4.8, 0.50 → 4.3, 0.62 → 3.2), so the
  /// transcript's calm has to come from `push`, which moves the band away from
  /// the ink, and not from `flatten`, which collapses the band itself.
  func testNoRoleRaisesFlatten() {
    // There is deliberately no `GroundRole.flatten`. If one is ever added, this
    // is the test that has to be argued with first.
    let sim = FieldSimulation(palette: GroundPalette.all[0], light: true)
    XCTAssertEqual(sim.flatten, 0.40, accuracy: 0.0001)
  }

  /// The transcript is the only role that pushes harder, and 0.97 is the last
  /// value with margin: at 1.00 the span measures exactly the 5.0 floor.
  func testOnlyTheTranscriptPushesHarder() {
    XCTAssertEqual(GroundRole.home.push, GroundRole.recording.push)
    XCTAssertGreaterThan(GroundRole.transcript.push, GroundRole.home.push)
    XCTAssertLessThan(
      GroundRole.transcript.push, 1.0,
      "push 1.00 measured exactly at the luminance floor — leave it margin")
  }

  /// And the reason it is worth having at all: a harder push really does move
  /// the ground further from the ink, in both appearances.
  func testTheTranscriptGroundSitsFurtherFromTheInk() {
    for light in [true, false] {
      let home = FieldTheme.make(light: light, push: GroundRole.home.push)
      let text = FieldTheme.make(light: light, push: GroundRole.transcript.push)
      if light {
        XCTAssertGreaterThan(
          text.bandMiddle, home.bandMiddle,
          "the transcript ground is not lighter than home's under dark ink")
      } else {
        XCTAssertLessThan(
          text.bandMiddle, home.bandMiddle,
          "the transcript ground is not darker than home's under light ink")
      }
    }
  }

  // MARK: - Helpers

  private static func snapshot(_ sim: FieldSimulation) -> [FieldColor.RGB] {
    var out: [FieldColor.RGB] = []
    for y in stride(from: 0, to: sim.height, by: 3) {
      for x in stride(from: 0, to: sim.width, by: 3) {
        out.append(sim.color(x: x, y: y))
      }
    }
    return out
  }

  private static func meanDistance(_ a: [FieldColor.RGB], _ b: [FieldColor.RGB]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return .infinity }
    var total = 0.0
    for (p, q) in zip(a, b) {
      let d = p - q
      total += (d * d).sum().squareRoot()
    }
    return total / Double(a.count)
  }
}
