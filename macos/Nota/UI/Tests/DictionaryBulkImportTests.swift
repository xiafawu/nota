import XCTest

@testable import Nota

/// Line-level parsing of a pasted word list. The merge rules themselves are
/// `DictionaryStore`'s and are covered by DictionaryStoreTests; this only
/// pins down what a line means.
final class DictionaryBulkImportTests: XCTestCase {
  private func parse(_ text: String) -> DictionaryBulkImport.Parsed {
    DictionaryBulkImport.parse(text)
  }

  // MARK: - Plain lines

  func testOneTermPerLine() {
    let parsed = parse("genc2rust\npyannote\nAssemblyAI")
    XCTAssertEqual(parsed.terms.map(\.term), ["genc2rust", "pyannote", "AssemblyAI"])
    XCTAssertEqual(parsed.terms.map(\.spokenForms), [[], [], []])
    XCTAssertEqual(parsed.skippedLines, 0)
  }

  func testBlankLinesAreStructureNotError() {
    let parsed = parse("\n\ngenc2rust\n   \n\npyannote\n\n")
    XCTAssertEqual(parsed.terms.map(\.term), ["genc2rust", "pyannote"])
    XCTAssertEqual(parsed.skippedLines, 0)
  }

  func testSurroundingWhitespaceIsTrimmed() {
    let parsed = parse("   genc2rust  \n\tpyannote\t")
    XCTAssertEqual(parsed.terms.map(\.term), ["genc2rust", "pyannote"])
  }

  func testCarriageReturnsSplitLinesToo() {
    let parsed = parse("genc2rust\r\npyannote")
    XCTAssertEqual(parsed.terms.map(\.term), ["genc2rust", "pyannote"])
  }

  func testEmptyInputImportsNothing() {
    XCTAssertTrue(parse("").terms.isEmpty)
    XCTAssertTrue(parse("\n \n\t\n").terms.isEmpty)
    XCTAssertEqual(parse("\n \n").skippedLines, 0)
  }

  // MARK: - Spoken forms

  func testPipeIntroducesASpokenForm() {
    let parsed = parse("genc2rust | gency to rust")
    XCTAssertEqual(parsed.terms.map(\.term), ["genc2rust"])
    XCTAssertEqual(parsed.terms.first?.spokenForms, ["gency to rust"])
  }

  func testSeveralSpokenFormsOnOneLine() {
    let parsed = parse("package.json | package json | package dot json")
    XCTAssertEqual(parsed.terms.first?.spokenForms, ["package json", "package dot json"])
  }

  func testEmptySpokenFormFieldsAreDropped() {
    let parsed = parse("genc2rust |  | gency to rust |")
    XCTAssertEqual(parsed.terms.first?.spokenForms, ["gency to rust"])
  }

  func testLineThatIsOnlyASpokenFormIsSkipped() {
    let parsed = parse("| gency to rust")
    XCTAssertTrue(parsed.terms.isEmpty)
    XCTAssertEqual(parsed.skippedLines, 1)
  }

  func testTermWithAnInteriorTabIsSkippedNotSmuggledIn() {
    // Tabs would corrupt the CLI's tab-separated `nota dictionary list` rows,
    // and DictionaryStore.add refuses them.
    let parsed = parse("genc2rust\tgency to rust\npyannote")
    XCTAssertEqual(parsed.terms.map(\.term), ["pyannote"])
    XCTAssertEqual(parsed.skippedLines, 1)
  }

  // MARK: - Duplicates

  func testDuplicateLinesCollapseCaseInsensitively() {
    let parsed = parse("Nota\nnota\nNOTA")
    XCTAssertEqual(parsed.terms.count, 1)
    // Last spelling wins, exactly as `nota dictionary add` behaves.
    XCTAssertEqual(parsed.terms.first?.term, "NOTA")
  }

  func testDuplicateLinesUnionTheirSpokenForms() {
    let parsed = parse("package.json | package json\npackage.json | package dot json")
    XCTAssertEqual(parsed.terms.count, 1)
    XCTAssertEqual(parsed.terms.first?.spokenForms, ["package json", "package dot json"])
  }

  func testRepeatedSpokenFormIsNotStoredTwice() {
    let parsed = parse("package.json | package json\npackage.json | Package JSON")
    XCTAssertEqual(parsed.terms.first?.spokenForms, ["package json"])
  }

  // MARK: - Summary text

  func testSummaryReportsWhatHappened() {
    XCTAssertEqual(
      DictionaryImportSummary(added: 3, merged: 1).message,
      "Imported: added 3, merged 1."
    )
    XCTAssertEqual(
      DictionaryImportSummary(added: 2, merged: 0, skipped: 1).message,
      "Imported: added 2, skipped 1."
    )
    XCTAssertEqual(DictionaryImportSummary().message, "Nothing to import.")
  }
}
