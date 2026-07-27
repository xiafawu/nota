import XCTest

@testable import Nota

/// Every case drives an injected URL inside a fresh temp directory — the real
/// `~/.nota/dictionary.json` must never be read or written by the suite.
final class DictionaryStoreTests: XCTestCase {
  private var directory: URL!
  private var fileURL: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("nota-dictionary-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    fileURL = directory.appendingPathComponent("dictionary.json")
    // `defaultURL` reads this; a stray value in the test runner's environment
    // would otherwise decide what `testDefaultURLPointsAtNotaHome` sees.
    unsetenv("NOTA_DICTIONARY_FILE")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  // MARK: - Load

  func testMissingFileLoadsEmpty() {
    XCTAssertEqual(DictionaryStore.load(from: fileURL), [])
  }

  func testCorruptFileLoadsEmptyWithoutCrashing() throws {
    try Data("{not json".utf8).write(to: fileURL)
    XCTAssertEqual(DictionaryStore.load(from: fileURL), [])
  }

  func testDefaultURLPointsAtNotaHome() {
    XCTAssertEqual(DictionaryStore.defaultURL.lastPathComponent, "dictionary.json")
    XCTAssertEqual(
      DictionaryStore.defaultURL.deletingLastPathComponent().lastPathComponent,
      ".nota"
    )
  }

  func testDefaultURLHonorsTheEnvironmentOverride() {
    // Same override the CLI honours (`defaultDictionaryPath()` in
    // src/utils/dictionary.ts) — pointing one side elsewhere has to move both.
    let override = directory.appendingPathComponent("elsewhere.json").path
    setenv("NOTA_DICTIONARY_FILE", override, 1)
    defer { unsetenv("NOTA_DICTIONARY_FILE") }

    XCTAssertEqual(DictionaryStore.defaultURL.path, override)
  }

  // MARK: - Round-trip

  func testAddRoundTripsAllFields() throws {
    try DictionaryStore.add(
      "genc2rust",
      spokenForms: ["gency to rust"],
      source: .harvested,
      starred: true,
      at: fileURL
    )

    let terms = DictionaryStore.load(from: fileURL)
    XCTAssertEqual(terms.count, 1)
    XCTAssertEqual(terms[0].term, "genc2rust")
    XCTAssertEqual(terms[0].spokenForms, ["gency to rust"])
    XCTAssertEqual(terms[0].source, .harvested)
    XCTAssertTrue(terms[0].starred)
    XCTAssertFalse(terms[0].addedAt.isEmpty)
  }

  func testSavedFileMatchesTheSharedV1Schema() throws {
    try DictionaryStore.add("genc2rust", spokenForms: ["gency to rust"], at: fileURL)

    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL))
    let object = try XCTUnwrap(raw as? [String: Any])
    XCTAssertEqual(object["version"] as? Int, DictionaryFile.currentVersion)
    let terms = try XCTUnwrap(object["terms"] as? [[String: Any]])
    XCTAssertEqual(terms.count, 1)
    // Field names are the Swift/TS contract — see src/utils/dictionary.ts.
    XCTAssertEqual(
      Set(terms[0].keys),
      ["term", "spokenForms", "source", "starred", "addedAt"]
    )
    XCTAssertEqual(terms[0]["source"] as? String, "manual")
    XCTAssertEqual(terms[0]["starred"] as? Bool, false)
  }

  func testReadsAFileWrittenByTheCLI() throws {
    // Exactly what `nota dictionary add` writes (2-space JSON, trailing \n).
    let json = """
      {
        "version": 1,
        "terms": [
          {
            "term": "genc2rust",
            "spokenForms": [
              "gency to rust"
            ],
            "source": "learned",
            "starred": true,
            "addedAt": "2026-07-26T10:00:00.000Z"
          }
        ]
      }

      """
    try Data(json.utf8).write(to: fileURL)

    let terms = DictionaryStore.load(from: fileURL)
    XCTAssertEqual(
      terms,
      [
        DictionaryTerm(
          term: "genc2rust",
          spokenForms: ["gency to rust"],
          source: .learned,
          starred: true,
          addedAt: "2026-07-26T10:00:00.000Z"
        )
      ]
    )
  }

  func testOneDamagedEntryDoesNotDisableTheWholeDictionary() throws {
    // The TS loader coerces per entry (tests/cli/dictionary.test.ts asserts it),
    // so an all-or-nothing Swift decode would leave `nota dictionary list`
    // printing terms that L1/L2/L3 had silently stopped seeing.
    let json = """
      { "version": 1, "terms": [
        { "term": "genc2rust" },
        { "trem": "typo" },
        "nope",
        { "term": "package.json" }
      ] }
      """
    try Data(json.utf8).write(to: fileURL)

    XCTAssertEqual(
      DictionaryStore.load(from: fileURL).map(\.term),
      ["genc2rust", "package.json"]
    )
  }

  func testAFileWithoutAVersionStillLoads() throws {
    try Data(#"{ "terms": [ { "term": "genc2rust" } ] }"#.utf8).write(to: fileURL)
    XCTAssertEqual(DictionaryStore.load(from: fileURL).map(\.term), ["genc2rust"])
  }

  func testUnknownSourceDegradesToManual() throws {
    let json = """
      { "version": 1, "terms": [ { "term": "keep", "source": "from-the-future" } ] }
      """
    try Data(json.utf8).write(to: fileURL)

    let terms = DictionaryStore.load(from: fileURL)
    XCTAssertEqual(terms.count, 1)
    XCTAssertEqual(terms[0].source, .manual)
    XCTAssertEqual(terms[0].spokenForms, [])
    XCTAssertFalse(terms[0].starred)
  }

  // MARK: - Case-insensitive dedupe

  func testAddDedupesCaseInsensitivelyAndMergesForms() throws {
    try DictionaryStore.add("nota", spokenForms: ["note uh"], at: fileURL)
    let firstAddedAt = DictionaryStore.load(from: fileURL)[0].addedAt

    try DictionaryStore.add("Nota", spokenForms: ["knowta", "NOTE UH"], at: fileURL)

    let terms = DictionaryStore.load(from: fileURL)
    XCTAssertEqual(terms.count, 1)
    // Last spelling wins; forms union case-insensitively; addedAt is kept.
    XCTAssertEqual(terms[0].term, "Nota")
    XCTAssertEqual(terms[0].spokenForms, ["note uh", "knowta"])
    XCTAssertEqual(terms[0].addedAt, firstAddedAt)
  }

  func testStarIsStickyAcrossALaterPlainAdd() throws {
    try DictionaryStore.add("genc2rust", starred: true, at: fileURL)
    try DictionaryStore.add("genc2rust", at: fileURL)
    XCTAssertTrue(DictionaryStore.load(from: fileURL)[0].starred)
  }

  func testDuplicatesInAHandEditedFileCollapseOnLoad() throws {
    let json = """
      { "version": 1, "terms": [
        { "term": "Nota", "addedAt": "a" },
        { "term": "nota", "addedAt": "b" },
        { "term": "   ", "addedAt": "c" }
      ] }
      """
    try Data(json.utf8).write(to: fileURL)
    XCTAssertEqual(DictionaryStore.load(from: fileURL).map(\.term), ["Nota"])
  }

  func testInvalidTermThrows() {
    XCTAssertThrowsError(try DictionaryStore.add("   ", at: fileURL))
    XCTAssertThrowsError(try DictionaryStore.add("a\tb", at: fileURL))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
  }

  // MARK: - Remove / star

  func testRemoveIsCaseInsensitiveAndReportsMisses() throws {
    try DictionaryStore.add("genc2rust", at: fileURL)
    try DictionaryStore.add("Nota", at: fileURL)

    XCTAssertTrue(try DictionaryStore.remove("GENC2RUST", at: fileURL))
    XCTAssertEqual(DictionaryStore.load(from: fileURL).map(\.term), ["Nota"])
    XCTAssertFalse(try DictionaryStore.remove("GENC2RUST", at: fileURL))
  }

  func testSetStarredTogglesAnExistingTermOnly() throws {
    try DictionaryStore.add("Nota", at: fileURL)

    XCTAssertTrue(try DictionaryStore.setStarred(true, for: "nota", at: fileURL))
    XCTAssertTrue(DictionaryStore.load(from: fileURL)[0].starred)

    XCTAssertTrue(try DictionaryStore.setStarred(false, for: "NOTA", at: fileURL))
    XCTAssertFalse(DictionaryStore.load(from: fileURL)[0].starred)

    XCTAssertFalse(try DictionaryStore.setStarred(true, for: "absent", at: fileURL))
  }

  // MARK: - Never destroy what could not be read

  func testMutatingAnUnreadableFileBacksItUpFirst() throws {
    // A truncated file: the user's real terms are in there, just unparseable.
    // Auto-learn reaches this path unattended, so the bytes must survive.
    let corrupt = #"{ "version": 1, "terms": [ { "term": "alpha" }, { "term": "beta" }"#
    try Data(corrupt.utf8).write(to: fileURL)

    try DictionaryStore.add("learned", source: .learned, at: fileURL)

    XCTAssertEqual(DictionaryStore.load(from: fileURL).map(\.term), ["learned"])
    let backups = try FileManager.default
      .contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasPrefix("dictionary.json.corrupt-") }
    XCTAssertEqual(backups.count, 1)
    XCTAssertEqual(
      try String(contentsOf: directory.appendingPathComponent(backups[0]), encoding: .utf8),
      corrupt
    )
  }

  func testReadingAnUnreadableFileDegradesToEmptyAndTouchesNothing() throws {
    // Dictation must not fail to start over a bad dictionary, and a read must
    // not quarantine anything — only a write can lose data.
    try Data("{not json".utf8).write(to: fileURL)

    XCTAssertEqual(DictionaryStore.load(from: fileURL), [])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [
      "dictionary.json"
    ])
  }

  func testASecondMutationDoesNotOverwriteTheFirstBackup() throws {
    let corrupt = #"{ "version": 1, "terms": [ { "term": "alpha" }"#
    try Data(corrupt.utf8).write(to: fileURL)

    // `remove` quarantines but writes nothing (the term is absent), so the
    // corrupt file is still in place for the `add` that follows.
    XCTAssertFalse(try DictionaryStore.remove("alpha", at: fileURL))
    try DictionaryStore.add("learned", at: fileURL)

    let backups = try FileManager.default
      .contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasPrefix("dictionary.json.corrupt-") }
    XCTAssertFalse(backups.isEmpty)
    for backup in backups {
      XCTAssertEqual(
        try String(contentsOf: directory.appendingPathComponent(backup), encoding: .utf8),
        corrupt
      )
    }
  }

  // MARK: - Concurrent writers

  func testConcurrentAddsAllSurvive() {
    // Two writers live in the app: the Settings pane and the detached
    // auto-learn task. An unsynchronized load-modify-save loses whichever
    // term the slower writer's snapshot predates.
    let url = fileURL!
    let count = 16
    DispatchQueue.concurrentPerform(iterations: count) { index in
      _ = try? DictionaryStore.add("term\(index)", at: url)
    }

    XCTAssertEqual(DictionaryStore.load(from: url).count, count)
  }

  // MARK: - Atomic write

  func testSaveLeavesNoTempFileBehind() throws {
    try DictionaryStore.add("Nota", at: fileURL)
    try DictionaryStore.add("genc2rust", at: fileURL)

    let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertEqual(contents, ["dictionary.json"])
  }

  func testSaveCreatesTheParentDirectory() throws {
    let nested = directory
      .appendingPathComponent("missing", isDirectory: true)
      .appendingPathComponent("dictionary.json")
    try DictionaryStore.save([DictionaryTerm(term: "Nota")], to: nested)
    XCTAssertEqual(DictionaryStore.load(from: nested).map(\.term), ["Nota"])
  }

  // MARK: - Bulk add

  func testAddAllStoresEveryTerm() throws {
    try DictionaryStore.addAll(
      [
        DictionaryTerm(term: "genc2rust", spokenForms: ["gency to rust"]),
        DictionaryTerm(term: "pyannote"),
        DictionaryTerm(term: "AssemblyAI")
      ],
      at: fileURL
    )
    XCTAssertEqual(
      DictionaryStore.load(from: fileURL).map(\.term),
      ["genc2rust", "pyannote", "AssemblyAI"]
    )
    XCTAssertEqual(DictionaryStore.load(from: fileURL).first?.spokenForms, ["gency to rust"])
  }

  func testAddAllMergesIntoWhatIsAlreadyThereAndReportsIt() throws {
    try DictionaryStore.add("package.json", spokenForms: ["package json"], at: fileURL)
    _ = try DictionaryStore.setStarred(true, for: "package.json", at: fileURL)

    let known = try DictionaryStore.addAll(
      [
        DictionaryTerm(term: "package.json", spokenForms: ["package dot json"]),
        DictionaryTerm(term: "pyannote")
      ],
      at: fileURL
    )

    XCTAssertEqual(known, ["package.json"])
    let stored = DictionaryStore.load(from: fileURL)
    XCTAssertEqual(stored.map(\.term), ["package.json", "pyannote"])
    XCTAssertEqual(stored[0].spokenForms, ["package json", "package dot json"])
    XCTAssertTrue(stored[0].starred, "a star already set is sticky")
  }

  func testAddAllHandlesAWholePastedList() throws {
    try DictionaryStore.save([DictionaryTerm(term: "Nota")], to: fileURL)
    try DictionaryStore.addAll((0..<500).map { DictionaryTerm(term: "term\($0)") }, at: fileURL)
    XCTAssertEqual(DictionaryStore.load(from: fileURL).count, 501)
  }

  /// One write means all-or-nothing: `add` per term left the terms before the
  /// bad one on disk and the rest of the list lost.
  func testAddAllRefusesTheWholeListWhenATermIsInvalid() throws {
    try DictionaryStore.add("Nota", at: fileURL)
    XCTAssertThrowsError(
      try DictionaryStore.addAll(
        [DictionaryTerm(term: "genc2rust"), DictionaryTerm(term: "bad\tterm")],
        at: fileURL
      )
    )
    XCTAssertEqual(
      DictionaryStore.load(from: fileURL).map(\.term),
      ["Nota"],
      "a refused import must not leave half of itself behind"
    )
  }

  // MARK: - Pure helpers

  func testMergingManyIsTheSameAsFoldingOneAtATime() {
    let existing = [DictionaryTerm(term: "Nota", spokenForms: ["note uh"], starred: true)]
    let incoming = [
      DictionaryTerm(term: "genc2rust", spokenForms: ["gency to rust"]),
      DictionaryTerm(term: "NOTA", spokenForms: ["no tuh"]),
      DictionaryTerm(term: "genc2rust", source: .learned)
    ]
    let folded = incoming.reduce(existing) { DictionaryStore.merging($1, into: $0) }
    XCTAssertEqual(DictionaryStore.merging(incoming, into: existing), folded)
    XCTAssertEqual(folded.map(\.term), ["NOTA", "genc2rust"])
    XCTAssertEqual(folded[0].spokenForms, ["note uh", "no tuh"])
    XCTAssertTrue(folded[0].starred)
  }

  func testMergingAppendsAnUnrelatedTerm() {
    let existing = [DictionaryTerm(term: "Nota")]
    let merged = DictionaryStore.merging(DictionaryTerm(term: "genc2rust"), into: existing)
    XCTAssertEqual(merged.map(\.term), ["Nota", "genc2rust"])
  }

  func testMergingPromotesALearnedSourceOverManual() {
    let existing = [DictionaryTerm(term: "Nota")]
    let merged = DictionaryStore.merging(
      DictionaryTerm(term: "Nota", source: .learned),
      into: existing
    )
    XCTAssertEqual(merged.count, 1)
    XCTAssertEqual(merged[0].source, .learned)
  }

  func testNormalizeTrimsAndDedupesSpokenForms() {
    let normalized = DictionaryStore.normalize([
      DictionaryTerm(term: " Nota ", spokenForms: [" note uh ", "NOTE UH", ""])
    ])
    XCTAssertEqual(normalized.map(\.term), ["Nota"])
    XCTAssertEqual(normalized[0].spokenForms, ["note uh"])
  }

  func testTimestampIsISO8601WithFractionalSeconds() {
    let stamp = DictionaryStore.timestamp(Date(timeIntervalSince1970: 0))
    XCTAssertEqual(stamp, "1970-01-01T00:00:00.000Z")
  }
}
