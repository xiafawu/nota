import XCTest
@testable import Nota

final class HomeDashboardStateTests: XCTestCase {
  // MARK: - CostCardViewModel: estimated marker

  func testCostCard_estimatedPrefix() {
    let rows = [ModelUsageRow.fixture(costUSD: 0.03, hasEstimated: true)]
    let vm = CostCardViewModel(rows: rows, window: "all")

    XCTAssertTrue(vm.hasEstimated)
    XCTAssertTrue(vm.headlineCost.hasPrefix("~"))
  }

  func testCostCard_noEstimatedPrefix_whenNoneEstimated() {
    let rows = [ModelUsageRow.fixture(costUSD: 0.03, hasEstimated: false)]
    let vm = CostCardViewModel(rows: rows, window: "all")

    XCTAssertFalse(vm.hasEstimated)
    XCTAssertFalse(vm.headlineCost.hasPrefix("~"))
  }

  // MARK: - Unknown footnote

  func testCostCard_unknownFootnote() {
    let rows = [ModelUsageRow.fixture(runs: 3, costUSD: 0.0, hasUnknown: true)]
    let vm = CostCardViewModel(rows: rows, window: "all")

    XCTAssertEqual(vm.unknownNote, "3 runs unknown cost")
  }

  func testCostCard_noUnknownFootnote_whenAllKnown() {
    let rows = [ModelUsageRow.fixture(runs: 2, costUSD: 0.06, hasUnknown: false)]
    let vm = CostCardViewModel(rows: rows, window: "all")

    XCTAssertNil(vm.unknownNote)
  }

  func testCostCard_unknownFootnote_singular() {
    let rows = [ModelUsageRow.fixture(runs: 1, costUSD: 0.0, hasUnknown: true)]
    let vm = CostCardViewModel(rows: rows, window: "all")

    XCTAssertEqual(vm.unknownNote, "1 run unknown cost")
  }

  // MARK: - Top-5 truncation

  func testCostCard_topFiveTruncation() {
    let rows = (1...7).map { i in
      ModelUsageRow.fixture(
        modelId: "model-\(i)",
        calls: 1,
        costUSD: Double(7 - i) * 0.01,
        hasEstimated: false
      )
    }

    let vm = CostCardViewModel(rows: rows, window: "all")

    XCTAssertEqual(vm.topModels.count, 5)
    XCTAssertEqual(vm.totalModelCount, 7)
    // Highest cost first
    XCTAssertEqual(vm.topModels[0].modelId, "model-1")
    XCTAssertEqual(vm.topModels[4].modelId, "model-5")
  }

  func testCostCard_fewerThanFiveRows() {
    let rows = (1...3).map { i in
      ModelUsageRow.fixture(modelId: "m-\(i)", costUSD: Double(i) * 0.01)
    }

    let vm = CostCardViewModel(rows: rows, window: "all")

    XCTAssertEqual(vm.topModels.count, 3)
    XCTAssertEqual(vm.totalModelCount, 3)
  }

  func testCostCard_sortsByCostDescending() {
    let rows = [
      ModelUsageRow.fixture(modelId: "cheap", costUSD: 0.01),
      ModelUsageRow.fixture(modelId: "expensive", costUSD: 0.50),
      ModelUsageRow.fixture(modelId: "mid", costUSD: 0.10),
    ]

    let vm = CostCardViewModel(rows: rows, window: "all")

    XCTAssertEqual(vm.topModels.map(\.modelId), ["expensive", "mid", "cheap"])
  }

  // MARK: - Empty states

  func testCostCard_emptyRows_30d() {
    let vm = CostCardViewModel(rows: [], window: "30d")

    XCTAssertEqual(vm.headlineCost, "$0.00")
    XCTAssertFalse(vm.hasEstimated)
    XCTAssertNil(vm.unknownNote)
    XCTAssertEqual(vm.topModels.count, 0)
    XCTAssertEqual(vm.totalModelCount, 0)
  }

  func testCostCard_emptyRows_all() {
    let vm = CostCardViewModel(rows: [], window: "all")

    XCTAssertEqual(vm.headlineCost, "$0.00")
    XCTAssertTrue(vm.topModels.isEmpty)
    XCTAssertEqual(vm.totalModelCount, 0)
  }

  // MARK: - Mixed

  func testCostCard_mixedEstimatedAndUnknown() {
    let rows = [
      ModelUsageRow.fixture(modelId: "known", costUSD: 0.10, hasEstimated: false),
      ModelUsageRow.fixture(modelId: "est", costUSD: 0.05, hasEstimated: true),
      ModelUsageRow.fixture(modelId: "unk", runs: 2, costUSD: 0.0, hasUnknown: true),
    ]

    let vm = CostCardViewModel(rows: rows, window: "all")

    XCTAssertTrue(vm.headlineCost.hasPrefix("~"))
    XCTAssertEqual(vm.unknownNote, "2 runs unknown cost")
    // The unknown-$0 row is excluded from the top list (T5: unknown never
    // renders as zero dollars); the footnote above carries its runs.
    XCTAssertEqual(vm.topModels.count, 2)
    XCTAssertFalse(vm.topModels.contains { $0.modelId == "unk" })
  }

  func testCostCard_zeroCostNoRows() {
    let vm = CostCardViewModel(rows: [], window: "all")

    XCTAssertEqual(vm.headlineCost, "$0.00")
    XCTAssertFalse(vm.hasEstimated)
    XCTAssertNil(vm.unknownNote)
  }

  // MARK: - USD formatting (shared semantics with the CLI's formatCost)

  func testFormatUSD_twoDecimalsForNormalValues() {
    XCTAssertEqual(CostCardViewModel.formatUSD(0.40), "$0.40")
    XCTAssertEqual(CostCardViewModel.formatUSD(1.5), "$1.50")
  }

  func testFormatUSD_fourDecimalsForSubCentValues() {
    XCTAssertEqual(CostCardViewModel.formatUSD(0.0042), "$0.0042")
  }

  func testFormatUSD_negativeClampsToZero() {
    XCTAssertEqual(CostCardViewModel.formatUSD(-0.5), "$0.00")
  }

  func testCostCard_unknownZeroRowsStillCountTowardTotalModelCount() {
    let rows = [
      ModelUsageRow.fixture(modelId: "known", costUSD: 0.10),
      ModelUsageRow.fixture(modelId: "unk", costUSD: 0.0, hasUnknown: true),
    ]
    let vm = CostCardViewModel(rows: rows, window: "all")
    XCTAssertEqual(vm.topModels.count, 1)
    XCTAssertEqual(vm.totalModelCount, 2)
  }

  // MARK: - HomeGreeting (B4 header / E3 first run)

  private func dateAt(hour: Int) -> Date {
    Calendar.current.date(
      bySettingHour: hour,
      minute: 0,
      second: 0,
      of: Date()
    )!
  }

  func testGreeting_firstRunSaysWelcomeWithFirstRunEyebrow() {
    XCTAssertEqual(HomeGreeting.eyebrow(isFirstRun: true), "First run")
    XCTAssertEqual(HomeGreeting.prefix(isFirstRun: true), "Welcome")
  }

  func testGreeting_usedStateShowsDateEyebrowAndTimeOfDay() {
    // Non-first-run eyebrow is a formatted date, never the "First run" marker.
    let eyebrow = HomeGreeting.eyebrow(isFirstRun: false, date: dateAt(hour: 9))
    XCTAssertNotEqual(eyebrow, "First run")
    XCTAssertFalse(eyebrow.isEmpty)
    XCTAssertEqual(
      HomeGreeting.prefix(isFirstRun: false, date: dateAt(hour: 9)),
      "Good morning"
    )
  }

  func testGreeting_timeOfDayPrefixByHour() {
    XCTAssertEqual(HomeGreeting.timeOfDayPrefix(date: dateAt(hour: 5)), "Good morning")
    XCTAssertEqual(HomeGreeting.timeOfDayPrefix(date: dateAt(hour: 11)), "Good morning")
    XCTAssertEqual(HomeGreeting.timeOfDayPrefix(date: dateAt(hour: 12)), "Good afternoon")
    XCTAssertEqual(HomeGreeting.timeOfDayPrefix(date: dateAt(hour: 16)), "Good afternoon")
    XCTAssertEqual(HomeGreeting.timeOfDayPrefix(date: dateAt(hour: 17)), "Good evening")
    XCTAssertEqual(HomeGreeting.timeOfDayPrefix(date: dateAt(hour: 21)), "Good evening")
    XCTAssertEqual(HomeGreeting.timeOfDayPrefix(date: dateAt(hour: 22)), "Good night")
    XCTAssertEqual(HomeGreeting.timeOfDayPrefix(date: dateAt(hour: 4)), "Good night")
  }

  func testGreeting_notFirstRunPrefixMatchesTimeOfDay() {
    XCTAssertEqual(
      HomeGreeting.prefix(isFirstRun: false, date: dateAt(hour: 18)),
      HomeGreeting.timeOfDayPrefix(date: dateAt(hour: 18))
    )
  }

  // MARK: - Stats-strip formatting

  func testMinutesText_underAnHour() {
    XCTAssertEqual(HomeDashboardView.minutesText(0), "0m")
    XCTAssertEqual(HomeDashboardView.minutesText(45), "45m")
  }

  func testMinutesText_overAnHour() {
    XCTAssertEqual(HomeDashboardView.minutesText(60), "1h 00m")
    XCTAssertEqual(HomeDashboardView.minutesText(65), "1h 05m")
    XCTAssertEqual(HomeDashboardView.minutesText(125), "2h 05m")
  }

  // MARK: - Shared history query helpers (home + drawer)

  private func entry(title: String, tags: [String], urlName: String = "x") -> HistoryEntry {
    HistoryEntry(
      url: URL(fileURLWithPath: "/tmp/\(urlName).summary.md"),
      modifiedAt: Date(),
      title: title,
      tags: tags,
      kind: .file
    )
  }

  func testMatches_isCaseInsensitiveOverTitleAndTags() {
    let e = entry(title: "Team Sync", tags: ["Roadmap"])
    XCTAssertTrue(HistoryPresentation.matches(e, query: "team"))
    XCTAssertTrue(HistoryPresentation.matches(e, query: "SYNC"))
    XCTAssertTrue(HistoryPresentation.matches(e, query: "roadmap"))
    XCTAssertTrue(HistoryPresentation.matches(e, query: "ROAD"))
    XCTAssertFalse(HistoryPresentation.matches(e, query: "hiring"))
  }

  func testMatches_emptyQueryMatchesEverything() {
    let e = entry(title: "Anything", tags: [])
    XCTAssertTrue(HistoryPresentation.matches(e, query: ""))
    XCTAssertTrue(HistoryPresentation.matches(e, query: "   "))
  }

  func testMatches_fallsBackToFilename() {
    // Generic "Transcript" title falls back to the filename-derived name.
    let e = entry(title: "Transcript", tags: [], urlName: "team-sync-20260803-101530")
    XCTAssertTrue(HistoryPresentation.matches(e, query: "team-sync"))
  }

  func testGroup_bandsContiguousEntries() {
    let now = Date()
    let today = HistoryEntry(
      url: URL(fileURLWithPath: "/tmp/today.summary.md"),
      modifiedAt: now,
      title: "Today",
      tags: [],
      kind: .file
    )
    let yesterday = HistoryEntry(
      url: URL(fileURLWithPath: "/tmp/y.summary.md"),
      modifiedAt: now.addingTimeInterval(-86400),
      title: "Yesterday",
      tags: [],
      kind: .memo
    )
    let groups = HistoryPresentation.group([today, yesterday], now: now)
    XCTAssertEqual(groups.count, 2)
    XCTAssertEqual(groups[0].band, .today)
    XCTAssertEqual(groups[1].band, .thisWeek)
    XCTAssertEqual(groups[0].entries.map(\.title), ["Today"])
    XCTAssertEqual(groups[1].entries.map(\.title), ["Yesterday"])
  }

  // MARK: - F1 card gating (XIA-400)

  private func check(
    _ id: String,
    status: PreflightStatus,
    blocking: Bool = true
  ) -> PreflightCheck {
    PreflightCheck(
      id: id,
      label: id,
      status: status,
      detail: "",
      blocking: blocking,
      httpStatus: nil
    )
  }

  func testGating_missingTranscriptionKeyGatesMeetingAndFileButNotMemo() {
    let result = PreflightResult(
      overall: .blocked,
      checks: [check("transcription", status: .fail)],
      checkedAt: ""
    )
    XCTAssertEqual(HomeGating.reason(result: result, card: .meeting), "Transcription")
    XCTAssertEqual(HomeGating.reason(result: result, card: .file), "Transcription")
    XCTAssertNil(HomeGating.reason(result: result, card: .memo), "memo runs on the Apple engine")
  }

  func testGating_missingSummaryKeyGatesFileAndMemo() {
    let result = PreflightResult(
      overall: .blocked,
      checks: [check("summary", status: .fail)],
      checkedAt: ""
    )
    XCTAssertEqual(HomeGating.reason(result: result, card: .file), "Summary")
    XCTAssertEqual(HomeGating.reason(result: result, card: .memo), "Summary")
    XCTAssertNil(HomeGating.reason(result: result, card: .meeting), "live meetings do not summarize yet")
  }

  func testGating_missingFfmpegGatesFileOnly() {
    let result = PreflightResult(
      overall: .blocked,
      checks: [check("audio-tools", status: .fail)],
      checkedAt: ""
    )
    XCTAssertEqual(HomeGating.reason(result: result, card: .file), "Audio tools")
    XCTAssertNil(HomeGating.reason(result: result, card: .meeting))
    XCTAssertNil(HomeGating.reason(result: result, card: .memo))
  }

  func testGating_unverifiedAndOptionalNeverGate() {
    let result = PreflightResult(
      overall: .unverified,
      checks: [
        check("transcription", status: .unverified),
        check("identity", status: .optional, blocking: false),
      ],
      checkedAt: ""
    )
    XCTAssertNil(HomeGating.reason(result: result, card: .meeting))
    XCTAssertNil(HomeGating.reason(result: result, card: .file))
    XCTAssertNil(HomeGating.reason(result: result, card: .memo))
  }

  func testGating_nilResultNeverGates() {
    XCTAssertNil(HomeGating.reason(result: nil, card: .meeting))
    XCTAssertNil(HomeGating.reason(result: nil, card: .file))
    XCTAssertNil(HomeGating.reason(result: nil, card: .memo))
  }

  // MARK: - Health pill state

  func testHealthPill_readyWhenNoAttention() {
    let result = PreflightResult(
      overall: .ready,
      checks: [
        check("audio-tools", status: .ok),
        check("transcription", status: .ok),
        check("identity", status: .optional, blocking: false),
      ],
      checkedAt: ""
    )
    XCTAssertEqual(HealthPillState.make(result: result), .ready)
  }

  func testHealthPill_issuesWithFailCountsAttention() {
    let result = PreflightResult(
      overall: .blocked,
      checks: [
        check("audio-tools", status: .fail),
        check("summary", status: .unverified),
      ],
      checkedAt: ""
    )
    XCTAssertEqual(HealthPillState.make(result: result), .issues(count: 2, hasFail: true))
  }

  func testHealthPill_unverifiedOnlyIsYellow() {
    let result = PreflightResult(
      overall: .unverified,
      checks: [check("transcription", status: .unverified)],
      checkedAt: ""
    )
    XCTAssertEqual(HealthPillState.make(result: result), .issues(count: 1, hasFail: false))
  }

  func testHealthPill_notCheckedForNilResult() {
    XCTAssertEqual(HealthPillState.make(result: nil), .notChecked)
  }
}
