import XCTest

@testable import Nota

/// The filter is the feature: a loose auto-learn would fill the dictionary with
/// ordinary English within a day, and every stored term then biases future
/// recognition. Most of this suite pins down what must NOT be learned.
final class AutoLearnTests: XCTestCase {
  // MARK: - Learns

  func testLearnsAnIdentifierCollapsedFromSeveralWords() {
    let candidates = AutoLearn.candidates(
      before: "I ran gency to rust on the crate.",
      after: "I ran genc2rust on the crate."
    )
    XCTAssertEqual(
      candidates,
      [AutoLearn.Candidate(term: "genc2rust", spokenForm: "gency to rust")]
    )
  }

  func testLearnsAOneWordSpellingFix() {
    let candidates = AutoLearn.candidates(
      before: "Open packagejson now.",
      after: "Open package.json now."
    )
    XCTAssertEqual(
      candidates,
      [AutoLearn.Candidate(term: "package.json", spokenForm: "packagejson")]
    )
  }

  func testTerminalPeriodIsStrippedFromALearnedTerm() {
    let candidates = AutoLearn.candidates(
      before: "Try gency to rust.",
      after: "Try genc2rust."
    )
    XCTAssertEqual(candidates.map(\.term), ["genc2rust"])
  }

  func testDuplicatePairsAreReportedOnce() {
    let candidates = AutoLearn.candidates(
      before: "gency to rust and gency to rust.",
      after: "genc2rust and genc2rust."
    )
    XCTAssertEqual(candidates.count, 1)
  }

  // MARK: - Refuses

  func testIdenticalTextLearnsNothing() {
    XCTAssertEqual(AutoLearn.candidates(before: "Hello there.", after: "Hello there."), [])
  }

  func testCapitalizationOnlyChangeLearnsNothing() {
    XCTAssertEqual(AutoLearn.candidates(before: "i think so.", after: "I think so."), [])
  }

  func testPunctuationOnlyChangeLearnsNothing() {
    XCTAssertEqual(
      AutoLearn.candidates(before: "hello there", after: "Hello, there."),
      []
    )
  }

  func testOrdinaryWordSwapLearnsNothing() {
    XCTAssertEqual(AutoLearn.candidates(before: "The cat sat.", after: "The dog sat."), [])
  }

  func testFillerRemovalLearnsNothing() {
    XCTAssertEqual(AutoLearn.candidates(before: "um hello there.", after: "Hello there."), [])
  }

  func testAWordThePolishModelAddedIsNotLearned() {
    // No misheard run to pair the identifier with — a pure insertion.
    XCTAssertEqual(
      AutoLearn.candidates(before: "Ship it.", after: "Ship it genc2rust."),
      []
    )
  }

  func testProseRewriteIntoACapitalizedWordLearnsNothing() {
    // "Tuesday" is a plain word: no digits, no interior case-mix, no code
    // punctuation, so it never qualifies as an identifier.
    XCTAssertEqual(
      AutoLearn.candidates(before: "Meet on chews day.", after: "Meet on Tuesday."),
      []
    )
  }

  func testAnOverlongMishearingIsNotLearned() {
    // Plain words on the left so the run reads as a mishearing, not identifiers.
    let filler = Array(repeating: "blah", count: AutoLearn.maxSpokenWords + 2)
      .joined(separator: " ")
    XCTAssertEqual(
      AutoLearn.candidates(before: "start \(filler) end", after: "start genc2rust end"),
      []
    )
  }

  func testOneIdentifierRewrittenIntoAnotherIsNotLearned() {
    // Both sides are already code-ish, so this is the polish model reshaping an
    // identifier, not the recognizer mishearing one. Learning it would let L2
    // rewrite correct text on the next session.
    XCTAssertEqual(
      AutoLearn.candidates(before: "Ship genc2rust today.", after: "Ship genc3rust today."),
      []
    )
  }

  func testHyphenationOfAModelIdIsLearned() {
    // "mini" on its own is not identifier-shaped, so this is a real mishearing
    // of a term the user actually said.
    XCTAssertEqual(
      AutoLearn.candidates(before: "Use gpt-5 mini.", after: "Use gpt-5-mini."),
      [AutoLearn.Candidate(term: "gpt-5-mini", spokenForm: "gpt-5 mini")]
    )
  }

  func testAStylisticHyphenationOfACommonWordIsNotLearned() {
    // "e-mail" is identifier-shaped by punctuation alone. Learning it makes L2
    // hyphenate the user's "email" in every later session — one polish call's
    // house style, made permanent.
    XCTAssertEqual(
      AutoLearn.candidates(before: "Send me an email today.", after: "Send me an e-mail today."),
      []
    )
  }

  func testASingleLetterDottedAbbreviationIsNotLearned() {
    // Every alphanumeric run is one character long: no identifier signal, just
    // punctuation the polish model added.
    XCTAssertEqual(
      AutoLearn.candidates(before: "For example the parser.", after: "For e.g. the parser."),
      []
    )
  }

  func testAnOrdinalRewriteIsNotLearned() {
    XCTAssertEqual(
      AutoLearn.candidates(before: "The second pass.", after: "The 2nd pass."),
      []
    )
  }

  func testInteriorCaseMixIsStillLearnable() {
    XCTAssertTrue(AutoLearn.isLearnable("camelCase"))
    XCTAssertTrue(AutoLearn.isLearnable("NSWorkspace"))
    XCTAssertFalse(AutoLearn.isLearnable("U.S."))
    XCTAssertFalse(AutoLearn.isLearnable("Rust"))
    XCTAssertTrue(AutoLearn.isLearnable("package.json"))
    XCTAssertTrue(AutoLearn.isLearnable("--no-history"))
  }

  func testAtMostThreeTermsAreLearnedFromOneSession() {
    // Five collapses in one dictation is a rewrite, not a spelling fix run.
    let before = "x packagejson x tsconfigjson x cargotoml x gency to rust x gpt-5 mini x"
    let after = "x package.json x tsconfig.json x cargo.toml x genc2rust x gpt-5-mini x"
    XCTAssertEqual(
      AutoLearn.candidates(before: before, after: after).count,
      AutoLearn.maxCandidatesPerSession
    )
  }

  func testEmptyInputsLearnNothing() {
    XCTAssertEqual(AutoLearn.candidates(before: "", after: "genc2rust."), [])
    XCTAssertEqual(AutoLearn.candidates(before: "gency to rust.", after: ""), [])
  }

  func testOversizedTranscriptsAreSkipped() {
    let long = Array(repeating: "word", count: AutoLearn.maxTokens + 1).joined(separator: " ")
    XCTAssertEqual(AutoLearn.candidates(before: long + " gency to rust", after: long + " genc2rust"), [])
  }
}
