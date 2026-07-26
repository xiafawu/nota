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

  // MARK: - Pure helpers

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
