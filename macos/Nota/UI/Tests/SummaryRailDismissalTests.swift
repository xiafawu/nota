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

// MARK: - ⌘L over an open Details panel (P-C1)

/// The drawer used to open under the rail's full-window invisible backdrop —
/// drawn, and inert to every click — while a second hidden `.cancelAction`
/// made Escape close an arbitrary one of the two surfaces. Opening the drawer
/// is a phase-leave-class event, so it runs the same dismissal policy the
/// record switch and the transcribe verb already run.
final class ChromeDismissalTests: XCTestCase {
  func testWithNoRailOpen_commandLIsThePlainToggle() {
    XCTAssertEqual(ChromeDismissal.onToggleDrawer(railOpen: false), .toggle)
  }

  func testWithTheRailOpen_theRailsPolicyRunsFirst() {
    XCTAssertEqual(ChromeDismissal.onToggleDrawer(railOpen: true), .dismissRailThenOpen)
  }

  /// The composed rule the model applies: with a draft in flight and Ask me
  /// set, the dismissal defers — so the completion that opens the drawer never
  /// runs, and Keep Editing leaves the owner where they were.
  func testAnAskMeDraftDefersTheDrawerRatherThanOpeningIt() {
    XCTAssertEqual(ChromeDismissal.onToggleDrawer(railOpen: true), .dismissRailThenOpen)
    XCTAssertEqual(summaryRailDismissalDecision(editing: true, behavior: .ask), .ask)
  }
}

// MARK: - What the merged Details panel draws below the hairline (2026-08-19)

/// The panel merged the info card into the summary rail, and the two rules
/// below are the ones that merge could get wrong. Both are pure, so they are
/// asserted without a window: SwiftUI publishes no accessibility tree for a
/// hosting view in an unhosted test bundle (`RecordingPaneTests` records the
/// measurement), so a rendered panel could not answer either question anyway.
final class SummaryRailContentTests: XCTestCase {
  /// **A tag run does not take the summary off the screen.**
  ///
  /// The fork that replaces the summary half with the in-flight row branched
  /// on `activity != .idle`, and the tags row that starts a *tag* run now sits
  /// four rows above it in the same panel. One press made the narrative — or
  /// an open editor holding an unsaved draft — vanish behind a progress row
  /// reading "Generating tags", under a heading reading SUMMARY.
  func testOnlyASummaryRunTakesOverTheSummaryHalf() {
    XCTAssertTrue(SummaryRailView.summaryIsInFlight(.summarizing))
    XCTAssertFalse(
      SummaryRailView.summaryIsInFlight(.tagging),
      "a tag run replaced the summary with its own progress row")
    XCTAssertFalse(SummaryRailView.summaryIsInFlight(.idle))
  }

  /// **The panel does not state a document has no record while it is still
  /// looking.**
  ///
  /// `NotaModel.loadChips` clears the record synchronously and reads the real
  /// one off disk in a detached task, so every recorded transcript passes
  /// through `record == nil` on open. Two states would print the notice there
  /// — a positive claim about the document, during a race the owner reaches by
  /// pressing Details right after opening one.
  func testTheNoRecordNoticeWaitsForTheLookup() {
    XCTAssertEqual(
      SummaryRailView.summaryHalf(hasRecord: true, isResolvingRecord: false), .summary)
    XCTAssertEqual(
      SummaryRailView.summaryHalf(hasRecord: false, isResolvingRecord: false),
      .noRecordNotice)
    XCTAssertEqual(
      SummaryRailView.summaryHalf(hasRecord: false, isResolvingRecord: true),
      .waitingForRecord,
      "a recorded transcript was told it had no history record mid-lookup")
    // A record that landed wins over a lookup flag nobody cleared.
    XCTAssertEqual(
      SummaryRailView.summaryHalf(hasRecord: true, isResolvingRecord: true), .summary)
  }

  /// **The notice states an absence, not a provenance.** `record == nil` is
  /// also true of a failure document, whose owner recorded a meeting and would
  /// be told they had opened a file.
  func testTheNoRecordNoticeClaimsNothingAboutWhereTheFileCameFrom() {
    XCTAssertFalse(SummaryRailView.noRecordNotice.lowercased().contains("imported"))
    XCTAssertTrue(
      SummaryRailView.noRecordNotice.lowercased().contains("no history record"))
  }

  /// **The caption under the editor names the whole keyboard** (P-C12).
  ///
  /// ⌘↩ is bound to Save and was named nowhere — the caption explained Escape
  /// and stopped there, so the one shortcut that commits an edit was the one
  /// nothing on screen said. Both dismissal behaviours owe it: the key does the
  /// same thing under either.
  func testTheEditorCaptionNamesBothKeys() {
    for behavior in [SummaryRailDismissalBehavior.save, .ask] {
      let caption = SummaryRailView.escapeCaption(behavior)
      XCTAssertTrue(
        caption.contains("⌘↩"),
        "\(behavior) caption does not name the key that saves: \(caption)")
      XCTAssertTrue(
        caption.contains("Esc"),
        "\(behavior) caption stopped naming Escape: \(caption)")
    }
  }

  /// **A menu row that binds a key names it** (P-C12). The cluster keeps that
  /// contract for ⌘K; the menu-bar popover bound the same key with no tooltip
  /// and no hint, while the string it needed already existed one type away.
  func testEveryMenuRowWithAShortcutSaysWhatTheKeyIs() {
    for action in MiniIslandAction.allCases where action.shortcut != nil {
      XCTAssertFalse(
        action.shortcutHint.isEmpty,
        "\(action) binds a key and its accessibility hint names none")
      XCTAssertTrue(
        action.help.contains("⌘"),
        "\(action) binds a key and its tooltip does not name it: \(action.help)")
    }
  }
}

// MARK: - The panel's ink

/// **The Details panel reads one ink, top to bottom.**
///
/// The four detail blocks were moved into this panel wholesale (ADR 0006) and
/// only the two `SummaryRailView` draws itself — the subtitle and the tags —
/// were converted, so in one `VStack` at one spacing it read ground ink, label
/// colours, label colours, ground ink. This is not the ground-contrast argument
/// (the panel is a `craftGlassPanel`); it is that a surface may not disagree
/// with itself about which system its own rows come from.
///
/// The three files are **read** rather than rendered: these are plain modifiers
/// with no function to ask, SwiftUI publishes no accessibility tree for an
/// unhosted hosting view, and an *adoption gap* is invisible to a test that
/// only checks the values that are there. Semantic **meaning** colours are not
/// in scope and are deliberately not banned — `CraftTokens.failure`, the
/// outdated banner's warning, and the system tint on a link all still say what
/// they mean.
final class SummaryRailInkTests: XCTestCase {
  func testEveryRowOfTheDetailsPanelComesFromTheGroundInkTiers() {
    let banned = [
      ".foregroundStyle(.primary)", ".foregroundStyle(.secondary)",
      ".foregroundStyle(.tertiary)",
    ]
    var offenders: [String] = []
    for name in ["SummaryRailView.swift", "RecordFacts.swift", "DocumentHeaderView.swift"] {
      for (index, line) in Self.uiSource(name).split(
        separator: "\n", omittingEmptySubsequences: false
      ).enumerated() {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.hasPrefix("//") else { continue }
        if banned.contains(where: { text.contains($0) }) {
          offenders.append("\(name):\(index + 1) \(text)")
        }
      }
    }
    XCTAssertEqual(
      offenders, [],
      "the Details panel is back on macOS label colours in one of its rows: \(offenders)")
  }

  /// A UI source file, found relative to this test's own path. The test target
  /// copies no resources, so a bundle lookup would silently resolve to nil.
  private static func uiSource(_ name: String) -> String {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent(name)
    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    XCTAssertFalse(text.isEmpty, "could not read \(name) beside this test")
    return text
  }
}

// MARK: - History drawer tab (decision 14)

final class HistoryDrawerTabTests: XCTestCase {
  func testTitlesAreBareLabels() {
    XCTAssertEqual(HistoryDrawerTab.transcripts.title, "Transcripts")
    XCTAssertEqual(HistoryDrawerTab.dictation.title, "Dictation")
  }
}
