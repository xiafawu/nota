import Foundation
import os

// MARK: - Schema (v1)

// Shared custom-vocabulary store at `~/.nota/dictionary.json`. The TypeScript
// CLI (`nota dictionary …`, src/cli/dictionary.ts + src/utils/dictionary.ts)
// reads and writes the very same file, so `version`, the field names below,
// and the case-insensitive uniqueness rule must stay in lockstep with
// `DictionaryTerm` in src/utils/dictionary.ts.
//
//   { "version": 1,
//     "terms": [ { "term": "genc2rust", "spokenForms": ["gency to rust"],
//                  "source": "manual", "starred": false, "addedAt": "<ISO>" } ] }

/// Where a term came from. `starred` (not source) decides who survives the
/// downstream 100-term context cap.
enum DictionaryTermSource: String, Codable, CaseIterable, Sendable {
  case manual
  case learned
  case harvested
}

struct DictionaryTerm: Codable, Hashable, Sendable {
  var term: String
  var spokenForms: [String]
  var source: DictionaryTermSource
  var starred: Bool
  var addedAt: String

  init(
    term: String,
    spokenForms: [String] = [],
    source: DictionaryTermSource = .manual,
    starred: Bool = false,
    addedAt: String = DictionaryStore.timestamp()
  ) {
    self.term = term
    self.spokenForms = spokenForms
    self.source = source
    self.starred = starred
    self.addedAt = addedAt
  }

  // Tolerant decode: a file written by a newer version (unknown `source`,
  // missing optionals) must degrade to a usable term rather than fail the
  // whole load. Only `term` is genuinely required.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.term = try container.decode(String.self, forKey: .term)
    self.spokenForms = (try? container.decode([String].self, forKey: .spokenForms)) ?? []
    let rawSource = try? container.decode(String.self, forKey: .source)
    self.source = rawSource.flatMap(DictionaryTermSource.init(rawValue:)) ?? .manual
    self.starred = (try? container.decode(Bool.self, forKey: .starred)) ?? false
    self.addedAt = (try? container.decode(String.self, forKey: .addedAt))
      ?? DictionaryStore.timestamp()
  }

  /// Case-insensitive identity key. Matches `key()` in src/utils/dictionary.ts.
  var key: String { term.lowercased() }
}

struct DictionaryFile: Codable, Sendable {
  var version: Int
  var terms: [DictionaryTerm]

  static let currentVersion = 1
  static let empty = DictionaryFile(version: currentVersion, terms: [])

  init(version: Int, terms: [DictionaryTerm]) {
    self.version = version
    self.terms = terms
  }

  // Tolerant decode, matching `loadDictionary` in src/utils/dictionary.ts: a
  // missing `version` and a single damaged entry each cost only themselves.
  // All-or-nothing decoding would let one hand-edited typo silently disable
  // L1, L2 and L3 in the app while `nota dictionary list` still printed every
  // good term.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.version = (try? container.decode(Int.self, forKey: .version))
      ?? DictionaryFile.currentVersion
    self.terms = ((try? container.decode([LenientTerm].self, forKey: .terms)) ?? [])
      .compactMap(\.term)
  }
}

/// One entry that decodes to nil instead of throwing, so a damaged entry cannot
/// take the rest of the file down with it.
private struct LenientTerm: Decodable {
  let term: DictionaryTerm?

  init(from decoder: Decoder) throws {
    term = try? DictionaryTerm(from: decoder)
  }
}

enum DictionaryStoreError: LocalizedError {
  case invalidTerm(String)
  case unpreservableFile(String, String)

  var errorDescription: String? {
    switch self {
    case .invalidTerm(let term):
      return "Invalid dictionary term \"\(term)\": must be non-empty and free of tabs and newlines."
    case .unpreservableFile(let path, let detail):
      return """
        Refusing to overwrite the unreadable dictionary at \(path): it could not \
        be backed up first (\(detail)). Fix or remove that file, then try again.
        """
    }
  }
}

// MARK: - Store

/// Load/save/add/remove/star over `~/.nota/dictionary.json`.
///
/// Every entry point takes an injectable URL so tests never touch the real
/// `~/.nota`. A missing or corrupt file logs a warning and reads as empty —
/// dictation must never fail to start because of a bad dictionary.
enum DictionaryStore {
  private static let logger = Logger(
    subsystem: "com.xiafawu.nota",
    category: "dictation.dictionary"
  )

  /// Serializes the read-modify-write in `add`/`remove`/`setStarred`.
  ///
  /// Two writers live in this process: the Settings pane and the auto-learn
  /// task detached from `DictationController.learnFromPolish`. Without this,
  /// both could read the same snapshot and the second `save` would drop the
  /// first's term — atomic writes prevent a torn file, not a lost update.
  /// A third writer, the `nota dictionary` CLI, is a separate process and
  /// still outside this lock.
  private static let mutationLock = NSLock()

  /// `~/.nota/dictionary.json`, or whatever `NOTA_DICTIONARY_FILE` points at.
  ///
  /// The env override mirrors `defaultDictionaryPath()` in
  /// src/utils/dictionary.ts. Without it the two halves of the same store
  /// disagree about which file they mean the moment anyone redirects the CLI.
  static var defaultURL: URL {
    let override = ProcessInfo.processInfo.environment["NOTA_DICTIONARY_FILE"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let override, !override.isEmpty {
      return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".nota", isDirectory: true)
      .appendingPathComponent("dictionary.json")
  }

  /// ISO-8601 with fractional seconds, so timestamps written here are
  /// byte-identical in shape to the CLI's `new Date().toISOString()`.
  static func timestamp(_ date: Date = Date()) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  // MARK: Read

  /// Read-only load. A missing or unreadable file is an empty dictionary and
  /// leaves the file untouched — a read must never have side effects, least of
  /// all on the hotkey path.
  static func load(from url: URL = defaultURL) -> [DictionaryTerm] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    do {
      return try parse(at: url)
    } catch {
      logger.warning(
        "Ignoring unreadable dictionary at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      return []
    }
  }

  private static func parse(at url: URL) throws -> [DictionaryTerm] {
    let data = try Data(contentsOf: url)
    let file = try JSONDecoder().decode(DictionaryFile.self, from: data)
    return normalize(file.terms)
  }

  /// The read half of a mutation. Unlike `load`, a file that cannot be parsed
  /// at all is copied aside to `dictionary.json.corrupt-<epoch>` first.
  ///
  /// Reading a corrupt file as empty is right for dictation — it must never
  /// fail to start over a bad dictionary — but destructive for a write: the
  /// `save` that follows replaces every term the decoder could not read with
  /// whatever the caller is adding. Auto-learn reaches this path with no user
  /// interaction at all, so the bytes have to survive somewhere before the
  /// store starts over.
  ///
  /// Per-entry damage never gets here: `DictionaryFile` decodes tolerantly, so
  /// only a wholly unparseable file (truncated, not JSON, not an object) is
  /// quarantined.
  static func loadForMutation(at url: URL = defaultURL) throws -> [DictionaryTerm] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    do {
      return try parse(at: url)
    } catch {
      try quarantine(url, reason: error.localizedDescription)
      return []
    }
  }

  /// Copy an unparseable dictionary to `<name>.corrupt-<epoch>` so the write
  /// that follows cannot be the end of the user's terms.
  ///
  /// Copy, not move: if the write that follows fails, the original is still
  /// exactly where it was. A backup that already exists is left alone — the
  /// same second's second attempt would otherwise overwrite the first rescue.
  private static func quarantine(_ url: URL, reason: String) throws {
    let backup = url.deletingLastPathComponent()
      .appendingPathComponent(
        "\(url.lastPathComponent).corrupt-\(Int(Date().timeIntervalSince1970))"
      )
    do {
      if !FileManager.default.fileExists(atPath: backup.path) {
        try FileManager.default.copyItem(at: url, to: backup)
      }
    } catch {
      throw DictionaryStoreError.unpreservableFile(url.path, error.localizedDescription)
    }
    logger.warning(
      """
      Unreadable dictionary at \(url.path, privacy: .public) (\(reason, privacy: .public)); \
      backed it up to \(backup.lastPathComponent, privacy: .public) and started a new one.
      """
    )
  }

  // MARK: Write

  static func save(_ terms: [DictionaryTerm], to url: URL = defaultURL) throws {
    let file = DictionaryFile(version: DictionaryFile.currentVersion, terms: normalize(terms))
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(file)

    // Atomic write, mirroring ApiKeyStore.writeFileMap: a crash mid-write must
    // never leave a half-written dictionary where the old one was.
    let tempURL = url.deletingLastPathComponent()
      .appendingPathComponent(".dictionary-\(UUID().uuidString).tmp")
    try data.write(to: tempURL, options: .atomic)
    if fileManager.fileExists(atPath: url.path) {
      _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
    } else {
      try fileManager.moveItem(at: tempURL, to: url)
    }
  }

  // MARK: Mutations

  /// Add a term, or merge into the existing case-insensitive match: spoken
  /// forms are unioned, `starred` is sticky once set, and the original
  /// `addedAt` is kept. Returns the stored term.
  @discardableResult
  static func add(
    _ term: String,
    spokenForms: [String] = [],
    source: DictionaryTermSource = .manual,
    starred: Bool = false,
    at url: URL = defaultURL
  ) throws -> DictionaryTerm {
    let incoming = DictionaryTerm(
      term: try validated(term),
      spokenForms: cleanedForms(spokenForms),
      source: source,
      starred: starred
    )
    return try mutationLock.withLock {
      let merged = merging(incoming, into: try loadForMutation(at: url))
      try save(merged, to: url)
      // `merging` guarantees the key is present.
      return merged.first { $0.key == incoming.key } ?? incoming
    }
  }

  /// Remove a term case-insensitively. Returns false when it was not present.
  @discardableResult
  static func remove(_ term: String, at url: URL = defaultURL) throws -> Bool {
    let key = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return try mutationLock.withLock {
      let terms = try loadForMutation(at: url)
      let remaining = terms.filter { $0.key != key }
      guard remaining.count != terms.count else { return false }
      try save(remaining, to: url)
      return true
    }
  }

  /// Star or unstar an existing term. Returns false when it was not present.
  @discardableResult
  static func setStarred(
    _ starred: Bool,
    for term: String,
    at url: URL = defaultURL
  ) throws -> Bool {
    let key = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return try mutationLock.withLock {
      var terms = try loadForMutation(at: url)
      guard let index = terms.firstIndex(where: { $0.key == key }) else { return false }
      terms[index].starred = starred
      try save(terms, to: url)
      return true
    }
  }

  // MARK: Pure helpers

  /// Merge one term into a list under case-insensitive uniqueness. Kept pure
  /// so callers (and tests) can reason about the rule without touching disk.
  static func merging(_ incoming: DictionaryTerm, into terms: [DictionaryTerm]) -> [DictionaryTerm] {
    var result = terms
    guard let index = result.firstIndex(where: { $0.key == incoming.key }) else {
      result.append(incoming)
      return result
    }
    var existing = result[index]
    // Last spelling wins so `add "Nota"` can fix the casing of "nota".
    existing.term = incoming.term
    existing.spokenForms = unioned(existing.spokenForms, incoming.spokenForms)
    existing.starred = existing.starred || incoming.starred
    if incoming.source != .manual { existing.source = incoming.source }
    result[index] = existing
    return result
  }

  /// Drop blank terms and collapse case-insensitive duplicates (first wins),
  /// so a hand-edited file can never smuggle a duplicate past the store.
  static func normalize(_ terms: [DictionaryTerm]) -> [DictionaryTerm] {
    var seen = Set<String>()
    var result: [DictionaryTerm] = []
    for var term in terms {
      term.term = term.term.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !term.term.isEmpty, seen.insert(term.key).inserted else { continue }
      term.spokenForms = cleanedForms(term.spokenForms)
      result.append(term)
    }
    return result
  }

  private static func validated(_ term: String) throws -> String {
    let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
    // Tabs/newlines would corrupt the CLI's tab-separated `list` rows.
    guard !trimmed.isEmpty, !trimmed.contains("\t"), !trimmed.contains("\n") else {
      throw DictionaryStoreError.invalidTerm(term)
    }
    return trimmed
  }

  private static func cleanedForms(_ forms: [String]) -> [String] {
    unioned([], forms)
  }

  private static func unioned(_ base: [String], _ extra: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for form in base + extra {
      let trimmed = form.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, !trimmed.contains("\t"), !trimmed.contains("\n") else { continue }
      guard seen.insert(trimmed.lowercased()).inserted else { continue }
      result.append(trimmed)
    }
    return result
  }
}
