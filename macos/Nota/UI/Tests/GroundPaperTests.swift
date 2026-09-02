import SwiftUI
import XCTest

@testable import Nota

/// The light transcript's paper (`GroundPaper`): what it is worn by, what it
/// is made of, and that the warm ink clears every bar on it for every one of
/// the sixteen palettes a launch can hand the transcript.
final class GroundPaperTests: XCTestCase {

  /// Paper is the light transcript's surface and nothing else's. The dark
  /// transcript keeps the field on purpose — a dark multi-hue field is the one
  /// coloured ground the measurement found carrying text — and home and the
  /// live session keep theirs in both themes.
  func testOnlyTheLightTranscriptWearsPaper() {
    for role in GroundRole.allCases {
      for light in [true, false] {
        XCTAssertEqual(
          GroundPaper.wears(role: role, light: light),
          role == .transcript && light,
          "\(role) \(light ? "light" : "dark")")
      }
    }
  }

  /// Every ink tier clears its bar on every palette's paper, at both contrast
  /// settings. Value is fixed so this is nearly a constant, but the sixteen
  /// hues are walked anyway: a proof that costs microseconds is cheaper than
  /// the sentence "it cannot vary much".
  func testEveryTierClearsItsBarOnEveryPaper() {
    for palette in GroundPalette.all {
      let paper = GroundPaper.color(for: palette)
      let ink = GroundInk.ink(light: true)
      for tier in GroundInk.Tier.allCases {
        for contrast in [ColorSchemeContrast.standard, .increased] {
          let over = FieldColor.mix(paper, ink, tier.alpha(contrast))
          let ratio = GroundInk.contrast(over, paper)
          XCTAssertGreaterThanOrEqual(
            ratio, tier.minimumContrast,
            "\(tier) on \(palette.id) paper measures \(ratio) against a bar of "
              + "\(tier.minimumContrast) (\(contrast))")
        }
      }
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
