import XCTest

@testable import Nota

/// The Swift half of ADR 0002, and its lockstep with the TypeScript half.
///
/// Two invariants are load-bearing here. Provider comes from the id — the
/// namespace for a namespaced id, the lookup for a flat one — and an id in a
/// namespace this build has no provider for is refused rather than guessed at.
/// And decoding is tolerant *per entry*: a row written by a newer Nota costs
/// only itself, never the whole picker.
final class ModelNamespaceTests: XCTestCase {

  // MARK: - Id grammar (mirror of tests/model-id.test.ts)

  func testNamespaceIsTheFirstPathSegment() {
    XCTAssertEqual(ModelID.namespace(of: "openrouter/anthropic/claude-sonnet-5"), "openrouter")
    XCTAssertNil(ModelID.namespace(of: "gpt-5-mini"))
    // A leading separator has no first segment to name a provider.
    XCTAssertNil(ModelID.namespace(of: "/gpt-5-mini"))
  }

  func testProviderComesFromTheNamespace() {
    XCTAssertEqual(
      ModelID.provider(for: "openrouter/anthropic/claude-sonnet-5", declared: nil),
      .openrouter
    )
    // The id is the single source of truth: a contradicting declared provider
    // is the invalid state ADR 0001 exists to prevent, so the namespace wins.
    XCTAssertEqual(
      ModelID.provider(for: "openrouter/z-ai/glm-5.2", declared: "openai"),
      .openrouter
    )
  }

  func testUnknownNamespaceIsRefusedNotFalledBack() {
    XCTAssertNil(ModelID.provider(for: "bedrock/anthropic/claude", declared: nil))
    XCTAssertNil(ModelID.provider(for: "bedrock/anthropic/claude", declared: "openai"))
  }

  func testFlatIdsKeepTheLookupDerivation() {
    XCTAssertEqual(ModelID.provider(for: "gpt-5-mini", declared: "openai"), .openai)
    XCTAssertNil(ModelID.provider(for: "gpt-5-mini", declared: nil))
    XCTAssertNil(ModelID.provider(for: "gpt-5-mini", declared: "nonesuch"))
  }

  func testWireIDStripsExactlyOneProviderSegment() {
    XCTAssertEqual(
      ModelID.wire("openrouter/anthropic/claude-sonnet-5"),
      "anthropic/claude-sonnet-5"
    )
    XCTAssertEqual(ModelID.wire("openrouter/a/b/c"), "a/b/c")
    XCTAssertEqual(ModelID.wire("gpt-5-mini"), "gpt-5-mini")
    // Not a provider, so nothing is stripped.
    XCTAssertEqual(ModelID.wire("bedrock/anthropic/claude"), "bedrock/anthropic/claude")
  }

  // MARK: - Catalog decode

  private func decode(_ json: String) -> ModelCatalog? {
    try? JSONDecoder().decode(ModelCatalog.self, from: Data(json.utf8))
  }

  private func catalogJSON(models: String) -> String {
    """
    {"schemaVersion":1,"source":"t","etag":"e","fetchedAt":"2026-07-22T00:00:00Z",
     "costUnit":"usd_per_1m_tokens","models":[\(models)]}
    """
  }

  private let flatEntry = """
    {"id":"gpt-5-mini","provider":"openai","label":"GPT-5 mini","task":"summary",
     "cost":{"input":0.25,"output":2,"tiers":[]},"limit":{"context":1000000}}
    """

  func testDecodesANamespacedUnpricedEntry() throws {
    let json = catalogJSON(models: """
      {"id":"openrouter/anthropic/claude-sonnet-5","provider":"openrouter",
       "label":"Claude Sonnet 5 (OpenRouter)","task":"summary",
       "costNote":"refer to OpenRouter","limit":{"context":1000000},
       "execution":"http","origin":"curated"}
      """)
    let catalog = try XCTUnwrap(decode(json))
    let model = try XCTUnwrap(catalog.models.first)
    XCTAssertNil(model.cost)
    XCTAssertEqual(model.execution, .http)
    XCTAssertEqual(model.origin, .curated)

    let entry = try XCTUnwrap(catalog.summaryModelEntries().first)
    XCTAssertEqual(entry.provider, .openrouter)
    XCTAssertEqual(entry.wireID, "anthropic/claude-sonnet-5")
  }

  func testAbsentExecutionAndOriginMeanHttpAndAuto() throws {
    let catalog = try XCTUnwrap(decode(catalogJSON(models: flatEntry)))
    let model = try XCTUnwrap(catalog.models.first)
    XCTAssertEqual(model.execution, .http)
    XCTAssertEqual(model.origin, .auto)
  }

  func testAnUnknownExecutionKindDropsOneEntryNotTheCatalog() throws {
    let json = catalogJSON(models: """
      \(flatEntry),
      {"id":"gpt-5","provider":"openai","label":"GPT-5","task":"summary",
       "cost":{"input":1.25,"output":10,"tiers":[]},"limit":{"context":1000000},
       "execution":"wasm"}
      """)
    let catalog = try XCTUnwrap(decode(json))
    // The whole catalog still decodes; only the entry this build cannot name
    // is gone. Defaulting it to .http would be a build assuming that something
    // it cannot name is safe to run in-process.
    XCTAssertEqual(catalog.models.map(\.id), ["gpt-5-mini"])
  }

  func testAnUnknownNamespaceDropsOneEntryFromThePickers() throws {
    let json = catalogJSON(models: """
      \(flatEntry),
      {"id":"bedrock/anthropic/claude","provider":"openai","label":"Claude",
       "task":"summary","cost":{"input":1,"output":1,"tiers":[]},
       "limit":{"context":200000}}
      """)
    let catalog = try XCTUnwrap(decode(json))
    // It decodes (the shape is fine) but no provider can be derived, so it
    // never reaches a picker.
    XCTAssertEqual(catalog.models.count, 2)
    XCTAssertEqual(catalog.summaryModelEntries().map(\.id), ["gpt-5-mini"])
  }

  // MARK: - Sanitizing (mirror of sanitizeCatalog in src/catalog.ts)

  private let unknownNamespaceEntry = """
    {"id":"bedrock/anthropic/claude","provider":"openai","label":"Claude",
     "task":"summary","cost":{"input":1,"output":1,"tiers":[]},
     "limit":{"context":200000}}
    """

  func testSanitizingRemovesAnUnknownNamespaceFromTheWholeCatalog() throws {
    let catalog = try XCTUnwrap(decode(catalogJSON(models: """
      \(flatEntry),
      \(unknownNamespaceEntry)
      """)))
    XCTAssertEqual(catalog.sanitized().models.map(\.id), ["gpt-5-mini"])
    // Idempotent, and it does not disturb a clean catalog.
    XCTAssertEqual(catalog.sanitized().sanitized().models.map(\.id), ["gpt-5-mini"])
  }

  func testAnUnservableIdIsNotAValidPin() throws {
    // `contains` decides whether a stored summary preference is live or a
    // zombie. Filtering only `summaryModelEntries()` left an id that no picker
    // offers and no request can be built for still answering "valid" — so the
    // app and the CLI disagreed about the user's own settings.json.
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("nota-sanitize-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cacheURL = dir.appendingPathComponent("models-catalog.json")
    try Data(catalogJSON(models: "\(flatEntry),\(unknownNamespaceEntry)").utf8)
      .write(to: cacheURL)

    let (catalog, source) = ModelCatalogLoader.effective(cacheURL: cacheURL)
    XCTAssertEqual(source, .cache)
    XCTAssertFalse(catalog.contains("bedrock/anthropic/claude"))
    XCTAssertTrue(ModelCatalogLoader.isZombie(storedID: "bedrock/anthropic/claude", in: catalog))
    // The servable half of the same cache, and the curated merge, both survive.
    XCTAssertTrue(catalog.contains("gpt-5-mini"))
    XCTAssertTrue(catalog.contains("openrouter/anthropic/claude-sonnet-5"))
  }

  func testAnUnknownOriginDegradesRatherThanDroppingTheEntry() throws {
    // Origin is provenance for a label, not a safety property: an unfamiliar
    // value must not cost the model its place in the picker the way an
    // unfamiliar execution kind does.
    let json = catalogJSON(models: """
      {"id":"gpt-5-mini","provider":"openai","label":"GPT-5 mini","task":"summary",
       "cost":{"input":0.25,"output":2,"tiers":[]},"limit":{"context":1000000},
       "origin":"handwritten"}
      """)
    let catalog = try XCTUnwrap(decode(json))
    XCTAssertEqual(catalog.models.map(\.id), ["gpt-5-mini"])
    XCTAssertEqual(catalog.models.first?.origin, .auto)
  }

  func testAMalformedEntryDoesNotTakeItsNeighboursWithIt() throws {
    let json = catalogJSON(models: """
      \(flatEntry),
      {"id":"broken"}
      """)
    let catalog = try XCTUnwrap(decode(json))
    XCTAssertEqual(catalog.models.map(\.id), ["gpt-5-mini"])
  }

  // MARK: - Curated shortlist

  func testShortlistIsInLockstepWithTheTypeScriptSource() {
    // src/openrouter.ts is the source of truth; this asserts the copy has not
    // drifted from the six slugs verified against the live model list.
    XCTAssertEqual(
      ModelRegistry.openRouterModels.map(\.id),
      [
        "openrouter/anthropic/claude-sonnet-5",
        "openrouter/anthropic/claude-haiku-4.5",
        "openrouter/moonshotai/kimi-k2.6",
        "openrouter/qwen/qwen3.7-max",
        "openrouter/z-ai/glm-5.2",
        "openrouter/meta-llama/llama-4-maverick",
      ]
    )
    for model in ModelRegistry.openRouterModels {
      XCTAssertEqual(model.provider, "openrouter")
      XCTAssertEqual(model.execution, .http)
      XCTAssertEqual(model.origin, .curated)
      XCTAssertNil(model.cost, "\(model.id) must store no pricing")
      XCTAssertEqual(model.costNote, "refer to OpenRouter")
    }
  }

  func testTheShortlistIsMergedIntoTheEffectiveCatalog() throws {
    let catalog = try XCTUnwrap(decode(catalogJSON(models: flatEntry))).mergingCurated()
    for model in ModelRegistry.openRouterModels {
      XCTAssertTrue(catalog.contains(model.id), "\(model.id) missing after merge")
    }
    XCTAssertTrue(catalog.contains("gpt-5-mini"))
  }

  func testACacheEntryWinsOverTheHandWrittenStub() throws {
    let json = catalogJSON(models: """
      {"id":"openrouter/z-ai/glm-5.2","provider":"openrouter","label":"from upstream",
       "task":"summary","cost":{"input":1,"output":1,"tiers":[]},"limit":{"context":10}}
      """)
    let merged = try XCTUnwrap(decode(json)).mergingCurated()
    let matches = merged.models.filter { $0.id == "openrouter/z-ai/glm-5.2" }
    XCTAssertEqual(matches.count, 1)
    XCTAssertEqual(matches.first?.label, "from upstream")
  }

  func testCostNoteReplacesADollarFigureOnlyForUnpricedEntries() throws {
    let catalog = try XCTUnwrap(decode(catalogJSON(models: flatEntry))).mergingCurated()
    XCTAssertEqual(
      catalog.costNote(for: "openrouter/anthropic/claude-sonnet-5"),
      "refer to OpenRouter"
    )
    XCTAssertNil(catalog.costNote(for: "gpt-5-mini"))
    // An unknown model is an unknown cost, which is a different thing.
    XCTAssertNil(catalog.costNote(for: "no-such-model"))
  }

  // MARK: - The polish picker's filter

  func testPolishPickerListsOnlyHttpModels() {
    let entries = ModelRegistry.httpModels(for: .summary)
    XCTAssertTrue(entries.allSatisfy { $0.execution == .http })
    // The OpenRouter entries are http, so a *structural* filter keeps them.
    // An id-prefix filter of the kind ADR 0002 forbids would not.
    XCTAssertTrue(entries.contains { $0.id == "openrouter/anthropic/claude-sonnet-5" })
    XCTAssertTrue(entries.contains { $0.id == "gpt-5-mini" })
  }

  func testACliEntryIsExcludedByItsKindNotByItsId() throws {
    // `cli` has no members yet (ADR 0003 / plan 12). The catalog keeps such an
    // entry — it is a kind this build knows — and the http filter is what
    // withholds it from a per-sentence network path.
    let json = catalogJSON(models: """
      {"id":"gpt-5","provider":"openai","label":"GPT-5","task":"summary",
       "cost":{"input":1.25,"output":10,"tiers":[]},"limit":{"context":1000000},
       "execution":"cli"}
      """)
    let catalog = try XCTUnwrap(decode(json))
    XCTAssertEqual(catalog.models.count, 1)
    let entries = catalog.summaryModelEntries()
    XCTAssertEqual(entries.map(\.execution), [.cli])
    XCTAssertTrue(entries.filter { $0.execution == .http }.isEmpty)
  }

  // MARK: - Provider key rows

  func testEveryProviderHasAKeyRowInSettings() {
    for provider in ModelProvider.allCases {
      XCTAssertTrue(
        ApiKeyStore.keys.contains(provider.apiKeyEnv),
        "\(provider.rawValue) has no API Keys row"
      )
    }
    XCTAssertEqual(ModelProvider.openrouter.apiKeyEnv, "OPENROUTER_API_KEY")
    XCTAssertEqual(ModelProvider.openrouter.displayName, "OpenRouter")
  }

  // MARK: - CLI-engine pins are valid, not zombies

  func testCliEnginePinIsNotAZombie() {
    // A `claude-code/*` or `codex/*` pin in the shared settings.json is valid
    // for the CLI pipeline even though the app's catalog never lists it —
    // the Models pane must not call it "no longer available".
    let catalog = ModelCatalogLoader.bakedSnapshot.sanitized().mergingCurated()
    for id in ModelRegistry.cliEngineModelIDs {
      XCTAssertFalse(
        ModelCatalogLoader.isZombie(storedID: id, in: catalog),
        "\(id) wrongly classified as a retired model"
      )
      // And still structurally absent from every app surface: not in the
      // catalog itself, so no picker can offer it (ADR 0003).
      XCTAssertFalse(catalog.contains(id))
    }
    // The check stays a real check: junk is still a zombie.
    XCTAssertTrue(ModelCatalogLoader.isZombie(storedID: "gpt-2", in: catalog))
  }

  func testCliEngineMirrorIsInLockstepWithTheTypeScriptSource() {
    // Mirrors src/cli-engines.ts (source of truth). A one-sided edit to either
    // file must fail this test.
    XCTAssertEqual(ModelRegistry.cliEngineModelIDs, [
      "claude-code/sonnet", "claude-code/opus", "claude-code/haiku",
      "codex/gpt-5.6-sol", "codex/gpt-5.6-terra", "codex/gpt-5.6-luna",
      "codex/gpt-5.4-mini",
    ])
  }
}
