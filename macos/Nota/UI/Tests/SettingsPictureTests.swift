import XCTest

@testable import Nota

/// Settings with pictures: every pick-one setting draws a tile per option.
final class SettingsPictureTests: XCTestCase {
  /// A new case on any of these enums must arrive with a tile, a name and a
  /// picture of its own — never a blank square or a picture borrowed from a
  /// sibling.
  func testEveryOptionOfEveryPictureRowHasItsOwnTile() {
    let rows: [(String, Int, [String], [SettingsPicture])] = [
      ("appearance", AppearanceSetting.allCases.count, SettingsPictureRows.appearance.map(\.label), SettingsPictureRows.appearance.map(\.picture)),
      ("close summary", SummaryRailDismissalBehavior.allCases.count, SettingsPictureRows.closeSummary.map(\.label), SettingsPictureRows.closeSummary.map(\.picture)),
      ("activation", ActivationMode.allCases.count, SettingsPictureRows.activation.map(\.label), SettingsPictureRows.activation.map(\.picture)),
      ("trigger", TriggerKey.Kind.allCases.count, SettingsPictureRows.trigger.map(\.label), SettingsPictureRows.trigger.map(\.picture)),
      ("engine", EngineChoice.allCases.count, SettingsPictureRows.engine.map(\.label), SettingsPictureRows.engine.map(\.picture)),
      ("delivery", DeliveryMode.allCases.count, SettingsPictureRows.delivery.map(\.label), SettingsPictureRows.delivery.map(\.picture)),
      ("HUD style", HUDStyle.allCases.count, SettingsPictureRows.hudStyle.map(\.label), SettingsPictureRows.hudStyle.map(\.picture)),
      ("cursor position", CursorMarkPosition.allCases.count, SettingsPictureRows.cursorPosition.map(\.label), SettingsPictureRows.cursorPosition.map(\.picture)),
    ]
    for (name, cases, labels, pictures) in rows {
      XCTAssertEqual(labels.count, cases, "\(name): one tile per case")
      XCTAssertEqual(Set(labels).count, cases, "\(name): names are distinct")
      XCTAssertFalse(labels.contains(""), "\(name): every tile is named")
      XCTAssertEqual(Set(pictures).count, cases, "\(name): pictures are distinct")
    }
  }

  /// The tile is Apple's Appearance tile, measured off System Settings.
  func testTheTileIsAppleAppearanceTile() {
    XCTAssertEqual(SettingsPictureMetrics.tileSize, CGSize(width: 68, height: 44))
    XCTAssertEqual(SettingsPictureMetrics.tileCornerRadius, 6)
    XCTAssertEqual(SettingsPictureMetrics.ringWidth, 2.5)
    XCTAssertEqual(SettingsPictureMetrics.ringGap, 1.5)
    XCTAssertEqual(SettingsPictureMetrics.labelSize, 11)
  }

  /// A picture holds one frame, and that frame must say what the option does
  /// — and the three delivery frames must differ, or the row is three
  /// pictures of one thing. Release: microphone off, every line in. While
  /// Speaking: microphone on, two lines typed and the third not yet. Review:
  /// microphone on, nothing in the field.
  func testEachDeliveryModeHoldsAFrameOfItsOwn() {
    let release = SettingsPicture.delivery(.immediate).restingPhase
    XCTAssertLessThan(SettingsPictureMotion.mic(release, until: 0.55), 1)
    XCTAssertEqual(SettingsPictureMotion.appear(release, at: 0.60), 1)

    let streaming = SettingsPicture.delivery(.streaming).restingPhase
    XCTAssertEqual(SettingsPictureMotion.mic(streaming, until: 0.70), 1)
    XCTAssertEqual(SettingsPictureMotion.appear(streaming, at: 0.20), 1)
    XCTAssertEqual(SettingsPictureMotion.appear(streaming, at: 0.38), 1)
    XCTAssertEqual(SettingsPictureMotion.appear(streaming, at: 0.56), 0)

    let review = SettingsPicture.delivery(.review).restingPhase
    XCTAssertEqual(SettingsPictureMotion.mic(review, until: 0.44), 1)
    XCTAssertEqual(SettingsPictureMotion.appear(review, at: 0.68), 0)
  }
}
