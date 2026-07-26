import XCTest

@testable import Nota

/// L2 substitution. The boundary rule is the whole point of this layer, so most
/// of the suite is boundary cases that `\b` would get wrong.
final class WordReplacementsTests: XCTestCase {
  private func term(
    _ name: String,
    spoken: [String],
    starred: Bool = false
  ) -> DictionaryTerm {
    DictionaryTerm(term: name, spokenForms: spoken, starred: starred)
  }

  // MARK: - Passthrough

  func testEmptyDictionaryLeavesTextAlone() {
    XCTAssertEqual(WordReplacements.apply("Hello there.", terms: []), "Hello there.")
  }

  func testEmptyTextStaysEmpty() {
    XCTAssertEqual(
      WordReplacements.apply("", terms: [term("genc2rust", spoken: ["gency to rust"])]),
      ""
    )
  }

  func testTermWithNoSpokenFormsChangesNothing() {
    XCTAssertEqual(
      WordReplacements.apply("Some rust code.", terms: [term("Rust", spoken: [])]),
      "Some rust code."
    )
  }

  // MARK: - Substitution

  func testMultiWordSpokenFormCollapsesIntoTheTerm() {
    let result = WordReplacements.apply(
      "I ran gency to rust on the crate.",
      terms: [term("genc2rust", spoken: ["gency to rust"])]
    )
    XCTAssertEqual(result, "I ran genc2rust on the crate.")
  }

  func testMatchIsCaseInsensitiveAndTheTermSpellingWins() {
    let result = WordReplacements.apply(
      "Gency To Rust is fast.",
      terms: [term("genc2rust", spoken: ["gency to rust"])]
    )
    XCTAssertEqual(result, "genc2rust is fast.")
  }

  func testReplacementRunsAtSentenceStartAndBeforePunctuation() {
    let result = WordReplacements.apply(
      "Package json, and package json.",
      terms: [term("package.json", spoken: ["package json"])]
    )
    XCTAssertEqual(result, "package.json, and package.json.")
  }

  // MARK: - Boundaries `\b` would get wrong

  func testDigitBoundaryProtectsIdentifierInteriors() {
    // `\b` sits between "2" and "rust", so a naive rule would rewrite the tail
    // of genc2rust.
    let result = WordReplacements.apply(
      "genc2rust and rust.",
      terms: [term("Rust", spoken: ["rust"])]
    )
    XCTAssertEqual(result, "genc2rust and Rust.")
  }

  func testPunctuationCountsAsABoundary() {
    let result = WordReplacements.apply(
      "Run --no-history please.",
      terms: [term("--no-history", spoken: ["no history"])]
    )
    XCTAssertEqual(result, "Run --no-history please.")

    let spelledOut = WordReplacements.apply(
      "Run no history please.",
      terms: [term("--no-history", spoken: ["no history"])]
    )
    XCTAssertEqual(spelledOut, "Run --no-history please.")
  }

  func testSubstringOfALongerWordIsNotReplaced() {
    let result = WordReplacements.apply(
      "Trusting rusty crustaceans.",
      terms: [term("Rust", spoken: ["rust"])]
    )
    XCTAssertEqual(result, "Trusting rusty crustaceans.")
  }

  func testDotIsABoundarySoAPrefixInsideAFilenameIsReplaced() {
    // Intentional: punctuation is a boundary in both directions, which is what
    // lets "package json" become "package.json" in the first place.
    let result = WordReplacements.apply(
      "Open package.json now.",
      terms: [term("Package", spoken: ["package"])]
    )
    XCTAssertEqual(result, "Open Package.json now.")
  }

  // MARK: - Rule ordering

  func testLongestSpokenFormWinsOverAnOverlappingShorterOne() {
    let result = WordReplacements.apply(
      "Try gency to rust today.",
      terms: [
        term("Rust", spoken: ["rust"]),
        term("genc2rust", spoken: ["gency to rust"]),
      ]
    )
    XCTAssertEqual(result, "Try genc2rust today.")
  }

  func testRulesAreOrderedLongestFirstAndDeterministically() {
    let rules = WordReplacements.rules(from: [
      term("Rust", spoken: ["rust"]),
      term("genc2rust", spoken: ["gency to rust", "gen c2 rust"]),
    ])
    XCTAssertEqual(rules.map(\.spoken), ["gency to rust", "gen c2 rust", "rust"])
  }

  func testSpokenFormIdenticalToItsOwnTermIsDroppedAsANoop() {
    let rules = WordReplacements.rules(from: [term("Nota", spoken: ["Nota", "note a"])])
    XCTAssertEqual(rules.map(\.spoken), ["note a"])
  }

  func testCaseOnlySpokenFormIsKeptSoCasingGetsNormalized() {
    let result = WordReplacements.apply(
      "I use nota daily.",
      terms: [term("Nota", spoken: ["nota"])]
    )
    XCTAssertEqual(result, "I use Nota daily.")
  }

  // MARK: - Hostile input

  func testRegexMetacharactersInSpokenFormAreLiteral() {
    let result = WordReplacements.apply(
      "Say a.c please.",
      terms: [term("abc", spoken: ["a.c"])]
    )
    XCTAssertEqual(result, "Say abc please.")

    let noWildcardMatch = WordReplacements.apply(
      "Say axc please.",
      terms: [term("abc", spoken: ["a.c"])]
    )
    XCTAssertEqual(noWildcardMatch, "Say axc please.")
  }

  func testDollarSignInTermIsNotATemplateReference() {
    let result = WordReplacements.apply(
      "Use dollar one here.",
      terms: [term("$1", spoken: ["dollar one"])]
    )
    XCTAssertEqual(result, "Use $1 here.")
  }
}
