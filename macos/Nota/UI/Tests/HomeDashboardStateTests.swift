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
}
