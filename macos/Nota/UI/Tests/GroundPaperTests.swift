import SwiftUI
import XCTest

@testable import Nota

/// The light reading surface's paper (`GroundPaper`): what it is worn by, that
/// every surface wearing it wears the *same* one, what it is made of, and that
/// the warm ink clears every bar on it for every one of the sixteen palettes a
/// launch can hand the transcript.
final class GroundPaperTests: XCTestCase {

  /// The truth table, whole. Paper is the light **reading** states' surface —
  /// the live session and the finished document (ADR 0007) — and nothing
  /// else's. The dark side keeps the field on purpose in every role: a dark
  /// multi-hue field is the one coloured ground the measurement found carrying
  /// text. Home keeps its own field in both themes.
  func testTheTwoLightReadingStatesWearPaperAndNothingElseDoes() {
    let expected: [GroundRole: (light: Bool, dark: Bool)] = [
      .home: (light: false, dark: false),
      .recording: (light: true, dark: false),
      .transcript: (light: true, dark: false),
    ]
    // `allCases` rather than the dictionary's keys, so a fourth role fails here
    // instead of silently going untested.
    for role in GroundRole.allCases {
      guard let want = expected[role] else {
        return XCTFail("\(role) is a role with no entry in the paper truth table")
      }
      XCTAssertEqual(GroundPaper.wears(role: role, light: true), want.light, "\(role) light")
      XCTAssertEqual(GroundPaper.wears(role: role, light: false), want.dark, "\(role) dark")
    }
  }

  /// **The half that matters.** A launch's family gives `.recording` and
  /// `.transcript` different palettes, so paper tinted per role would still
  /// change the ground under the owner at Stop — the quiet version of the
  /// event ADR 0007 exists to remove. Every paper surface tints from the
  /// family's transcript palette.
  ///
  /// The signature is the real proof — `palette(in:)` takes no role, so there
  /// is nothing to get wrong — and this pins the answer it gives, on all seven
  /// chords, together with the fact that the two palettes really do differ (a
  /// family that handed both roles one colour would make this pass for the
  /// wrong reason).
  func testEveryPaperSurfaceTintsFromTheTranscriptPalette() {
    for family in GroundFamily.all {
      let recording = family.palette(for: .recording)
      let transcript = family.palette(for: .transcript)
      XCTAssertNotEqual(
        recording.id, transcript.id,
        "\(family.id) gives one palette to both reading roles, so this proves nothing")

      XCTAssertEqual(
        GroundPaper.palette(in: family).id, transcript.id,
        "\(family.id): a paper surface tints from \(GroundPaper.palette(in: family).id)")
      XCTAssertNotEqual(
        GroundPaper.color(for: GroundPaper.palette(in: family)),
        GroundPaper.color(for: recording),
        "\(family.id): the recording paper and the transcript paper are different colours")
    }
  }

  /// Every ink tier clears its bar on every palette's paper, at both contrast
  /// settings — including the two the *recording* surface draws, `.timestamp`
  /// in the gutter and `.speaker` on a turn's first line, which reached paper
  /// for the first time with ADR 0007.
  ///
  /// The bar is `minimumContrast(contrast)`, not the standard one: under
  /// Increase Contrast a tier is promoted one step up its own table and takes
  /// the *promoted* bar with it, which is how `GroundInk`'s own sweep over the
  /// field is written. Value is fixed so this is nearly a constant, but the
  /// sixteen hues are walked anyway: a proof that costs microseconds is
  /// cheaper than the sentence "it cannot vary much".
  func testEveryTierClearsItsBarOnEveryPaper() {
    for palette in GroundPalette.all {
      let paper = GroundPaper.color(for: palette)
      let ink = GroundInk.ink(light: true)
      for tier in GroundInk.Tier.allCases {
        for contrast in [ColorSchemeContrast.standard, .increased] {
          let over = FieldColor.mix(paper, ink, tier.alpha(contrast))
          let ratio = GroundInk.contrast(over, paper)
          XCTAssertGreaterThanOrEqual(
            ratio, tier.minimumContrast(contrast),
            "\(tier) on \(palette.id) paper measures \(ratio) against a bar of "
              + "\(tier.minimumContrast(contrast)) (\(contrast))")
        }
      }
    }
  }

  /// The tiers the live transcript draws are really in that walk. `allCases`
  /// is what the sweep above iterates, so a tier quietly leaving the enum
  /// would narrow the proof without failing anything — and `.timestamp` and
  /// `.speaker` are exactly the two that arrived on paper with ADR 0007.
  func testTheRecordingSurfacesOwnTiersAreCoveredByThatSweep() {
    for tier in [GroundInk.Tier.timestamp, .speaker, .reading] {
      XCTAssertTrue(
        GroundInk.Tier.allCases.contains(tier),
        "\(tier) is drawn on paper by the live transcript but is not in the swept set")
    }
  }

  /// The paper carries the launch: its hue is the transcript palette's base
  /// hue, and two launches with different base hues get different paper. It is
  /// nowhere near the ember by construction — saturation a fortieth of the
  /// accent's — so the ember rule needs no Lab proof here.
  func testThePaperCarriesTheLaunchHueAndStaysFarFromEmber() {
    var seen = Set<String>()
    for palette in GroundPalette.all {
      let paper = GroundPaper.color(for: palette)
      let hsv = FieldColor.hsv(paper)
      let arc = abs((hsv.hue - palette.baseHue + 540).truncatingRemainder(dividingBy: 360) - 180)
      XCTAssertLessThanOrEqual(arc, 1.5, "\(palette.id): paper hue \(hsv.hue) vs base \(palette.baseHue)")
      XCTAssertLessThanOrEqual(hsv.saturation, 0.03, "\(palette.id): paper saturation \(hsv.saturation)")
      XCTAssertGreaterThanOrEqual(hsv.value, 0.97, "\(palette.id): paper value \(hsv.value)")
      seen.insert(String(format: "%.0f,%.0f,%.0f", paper.x, paper.y, paper.z))
    }
    XCTAssertGreaterThan(seen.count, 8, "the sixteen palettes produced only \(seen.count) distinct papers")
  }
}
