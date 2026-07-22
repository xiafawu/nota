import Foundation

// Swift reader for the self-updating summary-model catalog. The canonical
// producer is the TypeScript CLI (src/catalog.ts): it fetches models.dev,
// filters through the allowlist, and atomically writes
// ~/.nota/models-catalog.json (schemaVersion 1). The app only reads that cache
// — it never fetches models.dev itself. When the cache is missing or carries an
// unknown schemaVersion, a baked snapshot (mirroring BAKED_SNAPSHOT in
// src/catalog.ts) is served instead.
//
// This file is pure Foundation so it can be compiled into the standalone test
// executable (macos/NotaTests). No SwiftUI here — the observable store and the
// CLI-shelling live in ModelCatalogModel.swift.

// MARK: - Codable schema (mirrors the cache in src/catalog.ts)

struct CatalogCostTier: Codable, Hashable {
  var thresholdTokens: Int
  var input: Double
  var output: Double
  var cacheRead: Double?
}

struct CatalogCost: Codable, Hashable {
  var input: Double
  var output: Double
  var cacheRead: Double?
  var tiers: [CatalogCostTier]

  init(input: Double, output: Double, cacheRead: Double? = nil, tiers: [CatalogCostTier] = []) {
    self.input = input
    self.output = output
    self.cacheRead = cacheRead
    self.tiers = tiers
  }

  // Lenient decode: `cacheRead` is omitted when absent (never null), and while
  // the contract guarantees `tiers` is always present ([] when flat), we still
  // default it to [] so a hand-written or truncated cache decodes gracefully.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    input = try c.decode(Double.self, forKey: .input)
    output = try c.decode(Double.self, forKey: .output)
    cacheRead = try c.decodeIfPresent(Double.self, forKey: .cacheRead)
    tiers = try c.decodeIfPresent([CatalogCostTier].self, forKey: .tiers) ?? []
  }
}

struct CatalogLimit: Codable, Hashable {
  var context: Int
  var output: Int?
  var input: Int?
}

struct CatalogModel: Codable, Hashable, Identifiable {
  var id: String
  var provider: String
  var label: String
  var task: String
  var cost: CatalogCost
  var limit: CatalogLimit
}

struct ModelCatalog: Codable {
  var schemaVersion: Int
  var source: String
  var etag: String
  var fetchedAt: String
  var costUnit: String
  var models: [CatalogModel]
}

// MARK: - Bridge to ModelRegistry (ModelEntry / ModelProvider)

extension ModelProvider {
  /// Map a catalog `provider` string (already Nota-normalized upstream:
  /// openai | gemini | deepseek) to the app's provider enum.
  init?(catalogProvider: String) {
    switch catalogProvider {
    case "openai": self = .openai
    case "gemini": self = .gemini
    case "deepseek": self = .deepseek
    default: return nil
    }
  }
}

extension ModelCatalog {
  /// The catalog's models as `ModelEntry` values for the summary pickers.
  /// Entries whose provider can't be mapped are dropped.
  func summaryModelEntries() -> [ModelEntry] {
    models.compactMap { model in
      guard let provider = ModelProvider(catalogProvider: model.provider) else { return nil }
      return ModelEntry(id: model.id, task: .summary, provider: provider, label: model.label)
    }
  }

  func contains(_ modelID: String) -> Bool {
    models.contains { $0.id == modelID }
  }
}

// MARK: - Load / fallback

enum ModelCatalogSource {
  case cache
  case baked
}

enum ModelCatalogLoader {
  static let supportedSchemaVersion = 1

  static var defaultCacheURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".nota", isDirectory: true)
      .appendingPathComponent("models-catalog.json")
  }

  /// Decode a catalog from a file. Returns nil when the file is missing,
  /// unparseable, or carries an unsupported schemaVersion (→ caller falls back
  /// to the baked snapshot).
  static func load(from url: URL) -> ModelCatalog? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    guard let catalog = try? JSONDecoder().decode(ModelCatalog.self, from: data) else { return nil }
    guard catalog.schemaVersion == supportedSchemaVersion else { return nil }
    return catalog
  }

  /// Effective catalog: on-disk cache first, then the baked snapshot.
  static func effective(cacheURL: URL = defaultCacheURL) -> (catalog: ModelCatalog, source: ModelCatalogSource) {
    if let cached = load(from: cacheURL) {
      return (cached, .cache)
    }
    return (bakedSnapshot, .baked)
  }

  /// True when `storedID` is a non-empty summary preference that is absent from
  /// `catalog` (a "zombie": a retired model that the user still has pinned).
  static func isZombie(storedID: String?, in catalog: ModelCatalog) -> Bool {
    guard let storedID, !storedID.isEmpty else { return false }
    return !catalog.contains(storedID)
  }

  // MARK: Baked snapshot

  /// Verbatim mirror of BAKED_SNAPSHOT in src/catalog.ts. Embedded as JSON (raw
  /// string literal so the escaped quotes stay intact) and decoded once. A unit
  /// test asserts this decodes to the 14 expected ids, so a bad edit fails loud.
  static let bakedSnapshot: ModelCatalog = {
    guard let data = bakedSnapshotJSON.data(using: .utf8),
          let catalog = try? JSONDecoder().decode(ModelCatalog.self, from: data) else {
      fatalError("baked model catalog snapshot is invalid")
    }
    return catalog
  }()

  private static let bakedSnapshotJSON = #"{"schemaVersion":1,"source":"https://models.dev/api.json","etag":"\"baked-snapshot\"","fetchedAt":"2026-07-22T00:00:00Z","costUnit":"usd_per_1m_tokens","models":[{"id":"deepseek-v4-flash","provider":"deepseek","label":"DeepSeek V4 Flash","task":"summary","cost":{"input":0.14,"output":0.28,"cacheRead":0.0028,"tiers":[]},"limit":{"context":1000000,"output":384000}},{"id":"deepseek-v4-pro","provider":"deepseek","label":"DeepSeek V4 Pro","task":"summary","cost":{"input":0.435,"output":0.87,"cacheRead":0.003625,"tiers":[]},"limit":{"context":1000000,"output":384000}},{"id":"gemini-2.5-flash","provider":"gemini","label":"Gemini 2.5 Flash","task":"summary","cost":{"input":0.3,"output":2.5,"cacheRead":0.03,"tiers":[]},"limit":{"context":1048576,"output":65536}},{"id":"gemini-2.5-pro","provider":"gemini","label":"Gemini 2.5 Pro","task":"summary","cost":{"input":1.25,"output":10,"cacheRead":0.125,"tiers":[{"thresholdTokens":200000,"input":2.5,"output":15,"cacheRead":0.25}]},"limit":{"context":1048576,"output":65536}},{"id":"gemini-3.5-flash","provider":"gemini","label":"Gemini 3.5 Flash","task":"summary","cost":{"input":0.15,"output":0.6,"cacheRead":0.015,"tiers":[]},"limit":{"context":1048576,"output":65536}},{"id":"gemini-3.6-flash","provider":"gemini","label":"Gemini 3.6 Flash","task":"summary","cost":{"input":0.1,"output":0.4,"cacheRead":0.01,"tiers":[]},"limit":{"context":1048576,"output":65536}},{"id":"gpt-5","provider":"openai","label":"GPT-5","task":"summary","cost":{"input":1.25,"output":10,"cacheRead":0.125,"tiers":[]},"limit":{"context":1000000,"output":16384}},{"id":"gpt-5-mini","provider":"openai","label":"GPT-5 mini","task":"summary","cost":{"input":0.25,"output":2,"cacheRead":0.025,"tiers":[]},"limit":{"context":1000000,"output":16384}},{"id":"gpt-5.1","provider":"openai","label":"GPT-5.1","task":"summary","cost":{"input":2,"output":8,"cacheRead":0.5,"tiers":[]},"limit":{"context":1000000,"output":16384}},{"id":"gpt-5.2","provider":"openai","label":"GPT-5.2","task":"summary","cost":{"input":2.5,"output":10,"cacheRead":1.25,"tiers":[]},"limit":{"context":1000000,"output":16384}},{"id":"gpt-5.4","provider":"openai","label":"GPT-5.4","task":"summary","cost":{"input":1.25,"output":10,"cacheRead":0.125,"tiers":[]},"limit":{"context":1000000,"output":16384}},{"id":"gpt-5.4-mini","provider":"openai","label":"GPT-5.4 mini","task":"summary","cost":{"input":0.25,"output":2,"cacheRead":0.025,"tiers":[]},"limit":{"context":1000000,"output":16384}},{"id":"gpt-5.5","provider":"openai","label":"GPT-5.5","task":"summary","cost":{"input":1,"output":8,"cacheRead":0.1,"tiers":[]},"limit":{"context":1000000,"output":16384}},{"id":"gpt-5.6","provider":"openai","label":"GPT-5.6","task":"summary","cost":{"input":2.5,"output":10,"cacheRead":1.25,"tiers":[]},"limit":{"context":1000000,"output":16384}}]}"#
}
