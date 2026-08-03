import XCTest
@testable import Nota

final class UsageStatsProviderTests: XCTestCase {
  // MARK: - ModelUsageRow decoding

  func testDecodeModelUsageRow_allFields() throws {
    let json = """
    {
      "modelId": "gpt-4o",
      "provider": "assemblyai",
      "runs": 5,
      "calls": 12,
      "tokensIn": 1000,
      "tokensOut": 500,
      "costUSD": 0.15,
      "hasUnknown": false,
      "hasEstimated": false
    }
    """

    let data = try XCTUnwrap(json.data(using: .utf8))
    let row = try JSONDecoder().decode(ModelUsageRow.self, from: data)

    XCTAssertEqual(row.modelId, "gpt-4o")
    XCTAssertEqual(row.provider, "assemblyai")
    XCTAssertEqual(row.runs, 5)
    XCTAssertEqual(row.calls, 12)
    XCTAssertEqual(row.tokensIn, 1000)
    XCTAssertEqual(row.tokensOut, 500)
    XCTAssertEqual(row.costUSD, 0.15, accuracy: 0.001)
    XCTAssertFalse(row.hasUnknown)
    XCTAssertFalse(row.hasEstimated)
  }

  func testDecodeModelUsageRow_withFlags() throws {
    let json = """
    {
      "modelId": "whisper-1",
      "provider": "assemblyai",
      "runs": 1,
      "calls": 1,
      "tokensIn": 0,
      "tokensOut": 0,
      "costUSD": 0.0,
      "hasUnknown": true,
      "hasEstimated": true
    }
    """

    let data = try XCTUnwrap(json.data(using: .utf8))
    let row = try JSONDecoder().decode(ModelUsageRow.self, from: data)

    XCTAssertTrue(row.hasUnknown)
    XCTAssertTrue(row.hasEstimated)
    XCTAssertEqual(row.costUSD, 0.0, accuracy: 0.001)
  }

  func testDecodeModelUsageRow_costNoteReplacesTheFigure() throws {
    let json = """
    {
      "modelId": "openrouter/anthropic/claude-sonnet-5",
      "provider": "assemblyai",
      "runs": 1,
      "calls": 1,
      "tokensIn": 1000,
      "tokensOut": 500,
      "costUSD": 0.0,
      "hasUnknown": true,
      "hasEstimated": false,
      "costNote": "refer to OpenRouter"
    }
    """

    let data = try XCTUnwrap(json.data(using: .utf8))
    let row = try JSONDecoder().decode(ModelUsageRow.self, from: data)

    // A price that lives on someone else's dashboard is not a gap in Nota's
    // data: it must never read as "$0.00", and it must not read as "—" either.
    XCTAssertEqual(row.costDisplay, "refer to OpenRouter")

    let viewModel = CostCardViewModel(rows: [row], window: "all")
    XCTAssertNil(viewModel.unknownNote, "an unpriced row is not an unknown-cost run")
    XCTAssertEqual(viewModel.topModels.map(\.modelId), [row.modelId])
  }

  func testDecodeModelUsageRow_rowWithoutACostNoteStillDecodes() throws {
    // Rows written by a CLI predating the field carry no `costNote`.
    let row = try JSONDecoder().decode(
      ModelUsageRow.self,
      from: Data(
        """
        {"modelId":"gpt-5-mini","provider":"assemblyai","runs":1,"calls":1,
         "tokensIn":10,"tokensOut":5,"costUSD":0.25,"hasUnknown":false,
         "hasEstimated":false}
        """.utf8
      )
    )
    XCTAssertNil(row.costNote)
    XCTAssertEqual(row.costDisplay, "$0.25")
  }

  func testDecodeModelUsageRow_smallCost() throws {
    let json = """
    {
      "modelId": "claude-3-opus",
      "provider": "assemblyai",
      "runs": 1,
      "calls": 1,
      "tokensIn": 50,
      "tokensOut": 30,
      "costUSD": 0.0032,
      "hasUnknown": false,
      "hasEstimated": false
    }
    """

    let data = try XCTUnwrap(json.data(using: .utf8))
    let row = try JSONDecoder().decode(ModelUsageRow.self, from: data)

    XCTAssertEqual(row.modelId, "claude-3-opus")
    XCTAssertEqual(row.costUSD, 0.0032, accuracy: 0.0001)
  }

  // MARK: - UsageSummaryResponse decoding

  func testDecodeUsageSummaryResponse_emptyRows() throws {
    let json = """
    {
      "window": "all",
      "rows": []
    }
    """

    let data = try XCTUnwrap(json.data(using: .utf8))
    let response = try JSONDecoder().decode(UsageSummaryResponse.self, from: data)

    XCTAssertEqual(response.window, "all")
    XCTAssertTrue(response.rows.isEmpty)
  }

  func testDecodeUsageSummaryResponse_multipleRows() throws {
    let json = """
    {
      "window": "30d",
      "rows": [
        {
          "modelId": "gpt-4o",
          "provider": "assemblyai",
          "runs": 3,
          "calls": 6,
          "tokensIn": 500,
          "tokensOut": 250,
          "costUSD": 0.09,
          "hasUnknown": false,
          "hasEstimated": false
        },
        {
          "modelId": "universal",
          "provider": "assemblyai",
          "runs": 1,
          "calls": 1,
          "tokensIn": 0,
          "tokensOut": 0,
          "costUSD": 0.05,
          "hasUnknown": false,
          "hasEstimated": true
        }
      ]
    }
    """

    let data = try XCTUnwrap(json.data(using: .utf8))
    let response = try JSONDecoder().decode(UsageSummaryResponse.self, from: data)

    XCTAssertEqual(response.window, "30d")
    XCTAssertEqual(response.rows.count, 2)
    XCTAssertFalse(response.rows[0].hasEstimated)
    XCTAssertTrue(response.rows[1].hasEstimated)
    XCTAssertEqual(response.rows[0].costUSD, 0.09, accuracy: 0.001)
    XCTAssertEqual(response.rows[1].costUSD, 0.05, accuracy: 0.001)
  }

  func testDecodeUsageSummaryResponse_30dWindow() throws {
    let json = """
    {
      "window": "30d",
      "rows": []
    }
    """

    let data = try XCTUnwrap(json.data(using: .utf8))
    let response = try JSONDecoder().decode(UsageSummaryResponse.self, from: data)

    XCTAssertEqual(response.window, "30d")
  }

  // MARK: - Malformed JSON → error state (decoder throws)

  func testMalformedJSON_throws() throws {
    let invalidJSONs = [
      "not json at all",
      "",
      "{}",
      #"{"window": "all"}"#,
      #"{"rows": []}"#,
      #"{"window": "all", "rows": "not-an-array"}"#,
      #"{"window": "all", "rows": [{"modelId": "gpt-4o"}]}"#, // missing fields
    ]

    for json in invalidJSONs {
      let data = try XCTUnwrap(json.data(using: .utf8))
      XCTAssertThrowsError(try JSONDecoder().decode(UsageSummaryResponse.self, from: data)) { error in
        // Should always throw a DecodingError
        XCTAssertTrue(error is DecodingError, "Expected DecodingError for input: \(json.prefix(40))")
      }
    }
  }

  // MARK: - CostCardViewModel tests

  func testCostCardViewModel_totalCost_noEstimated() {
    let rows = [
      ModelUsageRow.fixture(costUSD: 0.03, hasEstimated: false),
      ModelUsageRow.fixture(modelId: "whisper-1", runs: 1, calls: 1, costUSD: 0.01, hasEstimated: false),
    ]

    let vm = CostCardViewModel(rows: rows, window: "all")

    XCTAssertEqual(vm.headlineCost, "$0.04")
    XCTAssertFalse(vm.hasEstimated)
    XCTAssertNil(vm.unknownNote)
  }

  func testCostCardViewModel_estimatedPrefix() {
    let rows = [
      ModelUsageRow.fixture(costUSD: 0.03, hasEstimated: true),
    ]

    let vm = CostCardViewModel(rows: rows, window: "all")

    XCTAssertTrue(vm.headlineCost.hasPrefix("~"))
    XCTAssertEqual(vm.headlineCost, "~$0.03")
    XCTAssertTrue(vm.hasEstimated)
  }

  func testCostCardViewModel_unknownFootnote() {
    let rows = [
      ModelUsageRow.fixture(runs: 3, costUSD: 0.03, hasUnknown: true),
    ]

    let vm = CostCardViewModel(rows: rows, window: "all")

    XCTAssertEqual(vm.unknownNote, "3 runs unknown cost")
  }

  func testCostCardViewModel_unknownFootnote_singular() {
    let rows = [
      ModelUsageRow.fixture(runs: 1, costUSD: 0.0, hasUnknown: true),
    ]

    let vm = CostCardViewModel(rows: rows, window: "all")

    XCTAssertEqual(vm.unknownNote, "1 run unknown cost")
  }

  func testCostCardViewModel_topFiveTruncation() {
    let rows = (1...7).map { i in
      ModelUsageRow.fixture(
        modelId: "model-\(i)",
        calls: 1,
        costUSD: Double(7 - i) * 0.01, // 0.06, 0.05, ..., 0.00
        hasEstimated: false
      )
    }

    let vm = CostCardViewModel(rows: rows, window: "all")

    XCTAssertEqual(vm.topModels.count, 5)
    XCTAssertEqual(vm.totalModelCount, 7)
    // Top 5 by cost — highest first
    XCTAssertEqual(vm.topModels[0].modelId, "model-1")  // costUSD 0.06
    XCTAssertEqual(vm.topModels[4].modelId, "model-5")  // costUSD 0.02
  }

  func testCostCardViewModel_fewerThanFiveRows() {
    let rows = (1...3).map { i in
      ModelUsageRow.fixture(
        modelId: "model-\(i)",
        costUSD: Double(i) * 0.01,
        hasEstimated: false
      )
    }

    let vm = CostCardViewModel(rows: rows, window: "all")

    XCTAssertEqual(vm.topModels.count, 3)
    XCTAssertEqual(vm.totalModelCount, 3)
  }

  func testCostCardViewModel_emptyRows() {
    let vm = CostCardViewModel(rows: [], window: "30d")

    XCTAssertEqual(vm.headlineCost, "$0.00")
    XCTAssertFalse(vm.hasEstimated)
    XCTAssertNil(vm.unknownNote)
    XCTAssertTrue(vm.topModels.isEmpty)
    XCTAssertEqual(vm.totalModelCount, 0)
  }

  func testCostCardViewModel_emptyRows_allWindow() {
    let vm = CostCardViewModel(rows: [], window: "all")

    XCTAssertEqual(vm.headlineCost, "$0.00")
    XCTAssertTrue(vm.topModels.isEmpty)
    XCTAssertEqual(vm.totalModelCount, 0)
  }

  func testCostCardViewModel_mixedEstimatedAndUnknown() {
    let rows = [
      ModelUsageRow.fixture(modelId: "known", costUSD: 0.10, hasEstimated: false, hasUnknown: false),
      ModelUsageRow.fixture(modelId: "estimated", costUSD: 0.05, hasEstimated: true, hasUnknown: false),
      ModelUsageRow.fixture(modelId: "unknown", runs: 2, costUSD: 0.0, hasEstimated: false, hasUnknown: true),
    ]

    let vm = CostCardViewModel(rows: rows, window: "all")

    XCTAssertTrue(vm.headlineCost.hasPrefix("~")) // estimated present → ~ prefix
    XCTAssertEqual(vm.unknownNote, "2 runs unknown cost")
    // Unknown-$0 rows are excluded from the top list (T5: unknown never
    // renders as zero dollars); the footnote carries their runs.
    XCTAssertEqual(vm.topModels.count, 2)
    XCTAssertFalse(vm.topModels.contains { $0.modelId == "unknown" })
  }

  // MARK: - ModelUsageRow Equatable conformance

  func testModelUsageRow_equality() {
    let a = ModelUsageRow.fixture(modelId: "gpt-4o", costUSD: 0.03)
    let b = ModelUsageRow.fixture(modelId: "gpt-4o", costUSD: 0.03)
    let c = ModelUsageRow.fixture(modelId: "whisper", costUSD: 0.01)

    XCTAssertEqual(a, b)
    XCTAssertNotEqual(a, c)
  }

  // MARK: - UsageSheetViewModel (mirrors `nota usage` totals)

  func testUsageSheet_totalSumsCostWithEstimatePrefix() {
    let rows = [
      ModelUsageRow.fixture(modelId: "a", costUSD: 0.10, hasEstimated: true),
      ModelUsageRow.fixture(modelId: "b", costUSD: 0.02),
    ]
    let vm = UsageSheetViewModel(rows: rows)
    XCTAssertEqual(vm.headlineCost, "~$0.12")
    XCTAssertNil(vm.notInTotalNote)
    XCTAssertNil(vm.unknownCostNote)
  }

  func testUsageSheet_plusSuffixAndNoteForUnpricedRows() {
    let rows = [
      ModelUsageRow.fixture(modelId: "openrouter/x", runs: 3, costUSD: 0.0, costNote: "refer to OpenRouter"),
    ]
    let vm = UsageSheetViewModel(rows: rows)
    XCTAssertEqual(vm.headlineCost, "$0.00+", "unpriced runs make the total a floor")
    XCTAssertEqual(vm.notInTotalNote, "3 runs not in total (refer to OpenRouter)")
    XCTAssertNil(vm.unknownCostNote, "a noted row is not an unknown-cost row")
  }

  func testUsageSheet_unknownCostFootnote() {
    let rows = [
      ModelUsageRow.fixture(modelId: "a", runs: 2, costUSD: 0.0, hasUnknown: true),
      ModelUsageRow.fixture(modelId: "b", costUSD: 0.05),
    ]
    let vm = UsageSheetViewModel(rows: rows)
    XCTAssertEqual(vm.headlineCost, "$0.05")
    XCTAssertEqual(vm.unknownCostNote, "2 runs have unknown cost")
    XCTAssertNil(vm.notInTotalNote)
  }

  func testUsageSheet_sortsRowsByCostDescending() {
    let rows = [
      ModelUsageRow.fixture(modelId: "cheap", costUSD: 0.01),
      ModelUsageRow.fixture(modelId: "pricey", costUSD: 0.50),
    ]
    let vm = UsageSheetViewModel(rows: rows)
    XCTAssertEqual(vm.rows.map(\.modelId), ["pricey", "cheap"])
  }
}
