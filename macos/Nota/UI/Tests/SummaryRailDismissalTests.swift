import XCTest
@testable import Nota

// MARK: - Editing-dismissal setting (decisions 7/13)

final class SummaryRailDismissalBehaviorTests: XCTestCase {
  private func freshDefaults() -> UserDefaults {
    // A unique suite keeps the test from touching the host app's real
    // preferences (and from bleeding into other tests).
    let suite = "SummaryRailDismissalBehaviorTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }

  func testDefaultIsSaveIt() {
    // A payload written without the key must decode to the default rather
    // than throwing or failing.
    let defaults = freshDefaults()
    XCTAssertEqual(SummaryRailDismissalBehavior.load(from: defaults), .save)
  }

  func testStoredAskValueDecodes() {
    let defaults = freshDefaults()
    defaults.set(SummaryRailDismissalBehavior.ask.rawValue, forKey: SummaryRailDismissalBehavior.defaultsKey)
    XCTAssertEqual(SummaryRailDismissalBehavior.load(from: defaults), .ask)
  }

  func testGarbageValueFallsBackToDefault() {
    let defaults = freshDefaults()
    defaults.set("regenerate-always", forKey: SummaryRailDismissalBehavior.defaultsKey)
    XCTAssertEqual(SummaryRailDismissalBehavior.load(from: defaults), .save)
  }

  func testLabelsMatchSettingOptions() {
    XCTAssertEqual(SummaryRailDismissalBehavior.save.label, "Save it")
    XCTAssertEqual(SummaryRailDismissalBehavior.ask.label, "Ask me")
  }
}

// MARK: - Pure dismissal decision (decision 13)

final class SummaryRailDismissalDecisionTests: XCTestCase {
  func testNoEditing_alwaysCloses() {
    for behavior in SummaryRailDismissalBehavior.allCases {
      XCTAssertEqual(
        summaryRailDismissalDecision(editing: false, behavior: behavior),
        .close
      )
    }
  }

  func testEditingWithSaveIt_commitsAndCloses() {
    XCTAssertEqual(
      summaryRailDismissalDecision(editing: true, behavior: .save),
      .commitAndClose
    )
  }

  func testEditingWithAskMe_defers() {
    XCTAssertEqual(
      summaryRailDismissalDecision(editing: true, behavior: .ask),
      .ask
    )
  }
}

// MARK: - History drawer tab (decision 14)

final class HistoryDrawerTabTests: XCTestCase {
  func testTitlesAreBareLabels() {
    XCTAssertEqual(HistoryDrawerTab.transcripts.title, "Transcripts")
    XCTAssertEqual(HistoryDrawerTab.dictation.title, "Dictation")
  }
}
