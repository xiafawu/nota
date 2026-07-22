// Swift tests for the summary-model catalog reader (ModelCatalog.swift).
// Compiled and run by macos/NotaTests/run-tests.sh together with the REAL
// production sources (ModelRegistry.swift + ModelCatalog.swift) so the decode,
// fallback, and zombie logic under test is the shipping code — not a re-declared
// copy. No XCTest/SPM dependency; @main provides the entry point since this is a
// multi-file executable.
//
// Hermetic: every catalog is loaded from a temp file (never ~/.nota) and the
// baked fallback is an embedded constant, so tests hit neither the network nor
// user state.

import Foundation

@main
struct CatalogTests {
  static var failures: [(name: String, message: String)] = []
  static var passed = 0

  static func test(_ name: String, _ body: () throws -> Void) {
    do {
      try body()
      passed += 1
      print("  PASS  \(name)")
    } catch {
      failures.append((name, "\(error)"))
      print("  FAIL  \(name): \(error)")
    }
  }

  static func expect(_ condition: Bool, _ message: String = "assertion failed", line: Int = #line) throws {
    if !condition {
      throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(message) (line \(line))"])
    }
  }

  /// Write `json` to a fresh temp file and return its URL. Caller cleans up.
  static func writeTemp(_ json: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("nota-catalog-\(UUID().uuidString).json")
    try json.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  static let expectedBakedIDs: Set<String> = [
    "gpt-5", "gpt-5-mini", "gpt-5.1", "gpt-5.2", "gpt-5.4", "gpt-5.4-mini",
    "gpt-5.5", "gpt-5.6", "gemini-2.5-flash", "gemini-2.5-pro",
    "gemini-3.5-flash", "gemini-3.6-flash", "deepseek-v4-flash", "deepseek-v4-pro",
  ]

  // A cache with a tiered entry, a flat entry with cacheRead, and an entry that
  // omits every optional field (no cacheRead, no tiers key, limit context-only).
  static let fixtureJSON = #"""
  {
    "schemaVersion": 1,
    "source": "https://models.dev/api.json",
    "etag": "\"fixture\"",
    "fetchedAt": "2026-07-22T00:00:00.000Z",
    "costUnit": "usd_per_1m_tokens",
    "models": [
      { "id": "gemini-2.5-pro", "provider": "gemini", "label": "Gemini 2.5 Pro",
        "task": "summary",
        "cost": { "input": 1.25, "output": 10, "cacheRead": 0.125,
          "tiers": [ { "thresholdTokens": 200000, "input": 2.5, "output": 15, "cacheRead": 0.25 } ] },
        "limit": { "context": 1048576, "output": 65536 } },
      { "id": "gpt-5-mini", "provider": "openai", "label": "GPT-5 mini",
        "task": "summary",
        "cost": { "input": 0.25, "output": 2, "cacheRead": 0.025, "tiers": [] },
        "limit": { "context": 1000000, "output": 16384 } },
      { "id": "min-model", "provider": "deepseek", "label": "Minimal",
        "task": "summary",
        "cost": { "input": 0.1, "output": 0.2 },
        "limit": { "context": 128000 } }
    ]
  }
  """#

  static func runDecodeTests() {
    print("\nCatalog decode")

    test("tiered + flat + omitted-optional entries decode from a fixture") {
      let url = try writeTemp(fixtureJSON)
      defer { try? FileManager.default.removeItem(at: url) }

      guard let catalog = ModelCatalogLoader.load(from: url) else {
        throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "load returned nil"])
      }
      try expect(catalog.schemaVersion == 1)
      try expect(catalog.models.count == 3, "expected 3 models, got \(catalog.models.count)")

      guard let pro = catalog.models.first(where: { $0.id == "gemini-2.5-pro" }) else {
        throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "gemini-2.5-pro missing"])
      }
      try expect(pro.cost.input == 1.25, "pro input")
      try expect(pro.cost.cacheRead == 0.125, "pro cacheRead")
      try expect(pro.cost.tiers.count == 1, "pro should have one tier")
      try expect(pro.cost.tiers[0].thresholdTokens == 200000, "pro tier threshold")
      try expect(pro.cost.tiers[0].input == 2.5, "pro tier input")
      try expect(pro.cost.tiers[0].cacheRead == 0.25, "pro tier cacheRead")
      try expect(pro.limit.context == 1048576, "pro context")
      try expect(pro.limit.output == 65536, "pro output limit")

      guard let flat = catalog.models.first(where: { $0.id == "gpt-5-mini" }) else {
        throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "gpt-5-mini missing"])
      }
      try expect(flat.cost.tiers.isEmpty, "flat entry should have no tiers")
      try expect(flat.cost.cacheRead == 0.025, "flat cacheRead")
    }

    test("omitted optional fields decode as nil / empty") {
      let url = try writeTemp(fixtureJSON)
      defer { try? FileManager.default.removeItem(at: url) }
      guard let catalog = ModelCatalogLoader.load(from: url),
            let minModel = catalog.models.first(where: { $0.id == "min-model" }) else {
        throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "min-model missing"])
      }
      try expect(minModel.cost.cacheRead == nil, "omitted cacheRead should be nil")
      try expect(minModel.cost.tiers.isEmpty, "omitted tiers should default to []")
      try expect(minModel.limit.output == nil, "omitted limit.output should be nil")
      try expect(minModel.limit.input == nil, "omitted limit.input should be nil")
    }

    test("decode → encode → decode round-trips the model set") {
      let url = try writeTemp(fixtureJSON)
      defer { try? FileManager.default.removeItem(at: url) }
      guard let first = ModelCatalogLoader.load(from: url) else {
        throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "first load nil"])
      }
      let reEncoded = try JSONEncoder().encode(first)
      let second = try JSONDecoder().decode(ModelCatalog.self, from: reEncoded)
      try expect(Set(first.models.map(\.id)) == Set(second.models.map(\.id)), "id set changed across round-trip")
      // cacheRead nil must stay absent (never serialized as null)
      let json = String(data: reEncoded, encoding: .utf8) ?? ""
      try expect(!json.contains("null"), "encoding must omit absent optionals, not write null")
    }

    test("unknown schemaVersion → load returns nil") {
      let bumped = fixtureJSON.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 2")
      let url = try writeTemp(bumped)
      defer { try? FileManager.default.removeItem(at: url) }
      try expect(ModelCatalogLoader.load(from: url) == nil, "schemaVersion 2 should not load")
    }

    test("unknown schemaVersion → effective falls back to baked") {
      let bumped = fixtureJSON.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 9")
      let url = try writeTemp(bumped)
      defer { try? FileManager.default.removeItem(at: url) }
      let effective = ModelCatalogLoader.effective(cacheURL: url)
      try expect(effective.source == .baked, "expected baked fallback for unknown schemaVersion")
      try expect(Set(effective.catalog.models.map(\.id)) == expectedBakedIDs, "baked ids mismatch")
    }
  }

  static func runFallbackTests() {
    print("\nBaked fallback")

    test("missing cache file → effective serves the baked 14-id list") {
      let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("nota-catalog-missing-\(UUID().uuidString).json")
      let effective = ModelCatalogLoader.effective(cacheURL: missing)
      try expect(effective.source == .baked, "expected baked source")
      try expect(effective.catalog.models.count == 14, "expected 14 baked models, got \(effective.catalog.models.count)")
      try expect(Set(effective.catalog.models.map(\.id)) == expectedBakedIDs, "baked ids mismatch")
    }

    test("baked snapshot decodes and maps to 14 provider-tagged entries") {
      let entries = ModelCatalogLoader.bakedSnapshot.summaryModelEntries()
      try expect(entries.count == 14, "expected 14 entries, got \(entries.count)")
      try expect(entries.allSatisfy { $0.task == .summary }, "all entries should be summary")
      let providers = Set(entries.map(\.provider))
      try expect(providers == [.openai, .gemini, .deepseek], "expected all three providers, got \(providers)")
    }

    test("ModelRegistry summary list matches the baked catalog") {
      let ids = Set(ModelRegistry.models(for: .summary).map(\.id))
      try expect(ids == expectedBakedIDs, "registry summary ids drifted from baked catalog")
      // slam-1 / nano must be gone from transcription.
      let tIDs = Set(ModelRegistry.models(for: .transcription).map(\.id))
      try expect(!tIDs.contains("slam-1"), "slam-1 should be removed")
      try expect(!tIDs.contains("nano"), "nano should be removed")
    }
  }

  static func runZombieTests() {
    print("\nZombie detection")

    let baked = ModelCatalogLoader.bakedSnapshot

    test("stored id absent from catalog → zombie") {
      try expect(ModelCatalogLoader.isZombie(storedID: "gpt-4o", in: baked), "gpt-4o should be a zombie")
      try expect(ModelCatalogLoader.isZombie(storedID: "gpt-4.1", in: baked), "gpt-4.1 should be a zombie")
    }

    test("stored id present in catalog → not a zombie") {
      try expect(!ModelCatalogLoader.isZombie(storedID: "gpt-5-mini", in: baked), "gpt-5-mini is present")
      try expect(!ModelCatalogLoader.isZombie(storedID: "deepseek-v4-flash", in: baked), "deepseek-v4-flash is present")
    }

    test("no stored preference → not a zombie") {
      try expect(!ModelCatalogLoader.isZombie(storedID: nil, in: baked), "nil should not be a zombie")
      try expect(!ModelCatalogLoader.isZombie(storedID: "", in: baked), "empty should not be a zombie")
    }
  }

  static func main() {
    runDecodeTests()
    runFallbackTests()
    runZombieTests()

    print("\n\(passed) passed, \(failures.count) failed")
    if !failures.isEmpty {
      for f in failures {
        print("  FAILED: \(f.name) — \(f.message)")
      }
      exit(1)
    }
    print("All catalog tests passed.")
  }
}
