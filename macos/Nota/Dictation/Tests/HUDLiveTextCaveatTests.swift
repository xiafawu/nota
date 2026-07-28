import XCTest

@testable import Nota

// MARK: - Live-text caveat

/// The Dictation pane's warning that a text-forward style will sit blank.
final class HUDLiveTextCaveatTests: XCTestCase {
  func testNoCaveatWhenTheSessionWillProduceALiveDraft() {
    XCTAssertNil(HUDStyle.liveTextCaveat(mode: .streaming, engine: .apple))
    XCTAssertNil(HUDStyle.liveTextCaveat(mode: .review, engine: .apple))
  }

  func testInsertOnReleaseIsExplainedByItsDeliveryMode() throws {
    let caveat = try XCTUnwrap(HUDStyle.liveTextCaveat(mode: .immediate, engine: .apple))
    XCTAssertTrue(caveat.contains(DeliveryMode.immediate.label))
  }

  /// AssemblyAI realtime reports whole formatted turns, so it delivers no
  /// segments in *any* delivery mode — a prompter on it is permanently blank,
  /// and the pane used to say nothing at all about why.
  func testEveryModeOnAnEngineThatCannotStreamIsExplained() throws {
    for mode in DeliveryMode.allCases {
      let caveat = try XCTUnwrap(
        HUDStyle.liveTextCaveat(mode: mode, engine: .assemblyAIRealtime),
        "no explanation for \(mode) on AssemblyAI"
      )
      if mode != .immediate {
        XCTAssertTrue(caveat.contains(EngineChoice.apple.label), caveat)
      }
    }
  }

  /// One source of truth: the pane explains exactly the configurations the
  /// session plan refuses a live draft to.
  func testTheCaveatAgreesWithTheSessionPlan() {
    for mode in DeliveryMode.allCases {
      for engine in EngineChoice.allCases {
        let plan = DictationSessionPlan.make(mode: mode, engine: engine)
        XCTAssertEqual(
          HUDStyle.liveTextCaveat(mode: mode, engine: engine) == nil,
          plan.wantsLiveDraft,
          "caveat disagreed with the plan for \(mode) on \(engine)"
        )
      }
    }
  }

  /// The pill shows a rough draft too, but it is a meter first and reads as
  /// finished without one — the caveat is for the styles chosen *for* text.
  func testOnlyTheTextForwardStylesCarryTheCaveat() {
    XCTAssertFalse(HUDStyle.pill.isAboutLiveText)
    XCTAssertTrue(HUDStyle.bar.isAboutLiveText)
    XCTAssertTrue(HUDStyle.prompter.isAboutLiveText)
  }
}
