import XCTest

@testable import Nota

/// Pure coverage for window-title harvesting and hint ranking. `ContextSnapshot
/// .capture()` itself touches NSWorkspace/AX and is exercised manually.
final class ContextHintsTests: XCTestCase {
  // MARK: - Identifier shape

  func testIdentifierShapeAcceptsCodeishTokens() {
    for token in [
      "genc2rust",         // digit
      "camelCase",         // interior capital
      "NSWorkspace",       // interior capital after a capital
      "package.json",      // interior dot
      "--no-history",      // leading flag dashes
      "src/lower.rs",      // path separator
      "snake_case",        // underscore
      "gpt-5.4-mini",      // digits + dashes
    ] {
      XCTAssertTrue(ContextSnapshot.isIdentifierShaped(token), "expected identifier: \(token)")
    }
  }

  func testIdentifierShapeRejectsProse() {
    for token in ["the", "Rust", "Meeting", "notes", "a", "TODO"] {
      XCTAssertFalse(ContextSnapshot.isIdentifierShaped(token), "expected prose: \(token)")
    }
  }

  // MARK: - Harvesting

  func testHarvestKeepsOnlyIdentifierTokens() {
    let harvested = ContextSnapshot.harvestIdentifiers(
      from: "genc2rust — src/lower.rs — Visual Studio Code"
    )
    XCTAssertEqual(harvested, ["genc2rust", "src/lower.rs"])
  }

  func testHarvestStripsWrappingPunctuationButKeepsCodePunctuation() {
    let harvested = ContextSnapshot.harvestIdentifiers(from: "(package.json), \"--force\"")
    XCTAssertEqual(harvested, ["package.json", "--force"])
  }

  func testHarvestDedupesCaseInsensitively() {
    let harvested = ContextSnapshot.harvestIdentifiers(from: "genc2rust GENC2RUST genc2rust")
    XCTAssertEqual(harvested, ["genc2rust"])
  }

  func testHarvestOfEmptySnapshotIsEmpty() {
    XCTAssertEqual(ContextSnapshot.empty.harvestIdentifiers(), [])
    XCTAssertTrue(ContextSnapshot.empty.isEmpty)
  }

  func testSnapshotHarvestUsesItsWindowTitle() {
    let snapshot = ContextSnapshot(
      appName: "Ghostty",
      bundleID: "com.mitchellh.ghostty",
      windowTitle: "nota — npm run build:mac"
    )
    XCTAssertEqual(snapshot.harvestIdentifiers(), ["build:mac"])
    XCTAssertFalse(snapshot.isEmpty)
  }

  func testCleanupContextRequiresExplicitOptIn() {
    let snapshot = ContextSnapshot(
      appName: "Xcode",
      bundleID: "com.apple.dt.Xcode",
      windowTitle: "Nota — ContextSnapshot.swift",
      focusedText: "let visibleText = focusedValue"
    )
    XCTAssertNil(snapshot.cleanupContext(enabled: false))
    XCTAssertEqual(snapshot.cleanupContext(enabled: true), snapshot)
    XCTAssertNil(ContextSnapshot.empty.cleanupContext(enabled: true))
  }

  func testFocusedTextIsFlattenedAndBoundedBeforePromptAssembly() {
    let bounded = ContextSnapshot.boundedFocusedText(
      "line one\n\tline two" + String(repeating: "x", count: 2_100)
    )
    XCTAssertEqual(bounded?.last, "…")
    XCTAssertEqual(bounded?.count, 2_000)
    XCTAssertNil(ContextSnapshot.boundedFocusedText("\n\t\u{0}"))
  }

  // MARK: - Hint ranking

  private func term(
    _ name: String,
    source: DictionaryTermSource = .manual,
    starred: Bool = false
  ) -> DictionaryTerm {
    DictionaryTerm(term: name, source: source, starred: starred)
  }

  func testEmptyDictionaryAndNoContextYieldsNoHints() {
    XCTAssertEqual(ContextHints.build(terms: []), [])
  }

  func testStarredTermsRankAheadOfEverythingElse() {
    let hints = ContextHints.build(
      terms: [
        term("alpha"),
        term("beta", source: .harvested),
        term("gamma", starred: true),
      ],
      harvested: ["delta1"]
    )
    XCTAssertEqual(hints, ["gamma", "alpha", "beta", "delta1"])
  }

  func testLearnedTermsRankWithManualAheadOfHarvested() {
    let hints = ContextHints.build(
      terms: [term("harvested1", source: .harvested), term("learned1", source: .learned)]
    )
    XCTAssertEqual(hints, ["learned1", "harvested1"])
  }

  func testCapKeepsStarredTermsAndDropsTheTail() {
    let manual = (0..<120).map { term("manual\($0)") }
    let hints = ContextHints.build(terms: manual + [term("keepme", starred: true)])
    XCTAssertEqual(hints.count, ContextHints.maxHints)
    XCTAssertEqual(hints.first, "keepme")
    XCTAssertFalse(hints.contains("manual119"))
  }

  func testLongPhrasesAreDroppedFromHints() {
    let hints = ContextHints.build(
      terms: [term("two words"), term("three word phrase"), term("solo")]
    )
    XCTAssertEqual(hints, ["two words", "solo"])
  }

  func testHintsDedupeAcrossDictionaryAndHarvest() {
    let hints = ContextHints.build(terms: [term("genc2rust")], harvested: ["GENC2RUST", "lower.rs"])
    XCTAssertEqual(hints, ["genc2rust", "lower.rs"])
  }
}
