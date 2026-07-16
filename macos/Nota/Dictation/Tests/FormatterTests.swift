import XCTest
@testable import Nota

final class FormatterTests: XCTestCase {
  // MARK: - Whitespace normalization

  func testNormalizeWhitespaceCollapsesSpaces() {
    XCTAssertEqual(Formatter.normalizeWhitespace("hello   world"), "hello world")
  }

  func testNormalizeWhitespaceTrims() {
    XCTAssertEqual(Formatter.normalizeWhitespace("  hi  "), "hi")
  }

  func testNormalizeWhitespaceHandlesNewlines() {
    XCTAssertEqual(Formatter.normalizeWhitespace("a\n\nb\nc"), "a b c")
  }

  func testNormalizeWhitespaceEmptyReturnsEmpty() {
    XCTAssertEqual(Formatter.normalizeWhitespace(""), "")
  }

  // MARK: - Filler word removal

  func testDropFillerUm() {
    XCTAssertEqual(Formatter.dropFillerWords("um I think"), "I think")
  }

  func testDropFillerUh() {
    XCTAssertEqual(Formatter.dropFillerWords("uh maybe"), "maybe")
  }

  func testDropFillerYouKnow() {
    XCTAssertEqual(Formatter.dropFillerWords("you know it works"), "it works")
  }

  func testDropFillerCaseInsensitive() {
    XCTAssertEqual(Formatter.dropFillerWords("UM Yeah"), "Yeah")
  }

  func testDropFillerWithPunctuation() {
    XCTAssertEqual(Formatter.dropFillerWords("um, I think"), "I think")
  }

  func testDropFillerMultiple() {
    XCTAssertEqual(Formatter.dropFillerWords("um uh you know hi"), "hi")
  }

  func testDropFillerNoFillers() {
    XCTAssertEqual(Formatter.dropFillerWords("hello world"), "hello world")
  }

  func testDropFillerEmpty() {
    XCTAssertEqual(Formatter.dropFillerWords(""), "")
  }

  func testDropFillerOnlyFillers() {
    XCTAssertEqual(Formatter.dropFillerWords("um uh"), "")
  }

  // MARK: - False-start cleanup

  func testCleanupFalseStartsRepeatedWord() {
    XCTAssertEqual(Formatter.cleanupFalseStarts("I I think"), "I think")
  }

  func testCleanupFalseStartsTheThe() {
    XCTAssertEqual(Formatter.cleanupFalseStarts("the the cat"), "the cat")
  }

  func testCleanupFalseStartsCaseInsensitive() {
    XCTAssertEqual(Formatter.cleanupFalseStarts("The the cat"), "the cat")
  }

  func testCleanupFalseStartsNoFalseStart() {
    XCTAssertEqual(Formatter.cleanupFalseStarts("I think so"), "I think so")
  }

  func testCleanupFalseStartsSingleWord() {
    XCTAssertEqual(Formatter.cleanupFalseStarts("hello"), "hello")
  }

  func testCleanupFalseStartsEmpty() {
    XCTAssertEqual(Formatter.cleanupFalseStarts(""), "")
  }

  func testCleanupFalseStartsTripleDoesNotOverclean() {
    // Only removes the first repeated pair, leaving the third.
    // "I I I think" → "I I think"
    XCTAssertEqual(Formatter.cleanupFalseStarts("I I I think"), "I I think")
  }

  // MARK: - Capitalization

  func testCapitalizeFirst() {
    XCTAssertEqual(Formatter.capitalizeFirst("hello"), "Hello")
  }

  func testCapitalizeFirstAlreadyCapitalized() {
    XCTAssertEqual(Formatter.capitalizeFirst("Hello"), "Hello")
  }

  func testCapitalizeFirstAfterPunctuation() {
    XCTAssertEqual(Formatter.capitalizeFirst("'hello'"), "'Hello'")
  }

  func testCapitalizeFirstEmpty() {
    XCTAssertEqual(Formatter.capitalizeFirst(""), "")
  }

  func testCapitalizeFirstNumeric() {
    XCTAssertEqual(Formatter.capitalizeFirst("123 go"), "123 Go")
  }

  // MARK: - Terminal punctuation

  func testEnsurePunctuationAddsPeriod() {
    XCTAssertEqual(Formatter.ensureTerminalPunctuation("hello"), "hello.")
  }

  func testEnsurePunctuationAlreadyHasPeriod() {
    XCTAssertEqual(Formatter.ensureTerminalPunctuation("hello."), "hello.")
  }

  func testEnsurePunctuationQuestionMark() {
    XCTAssertEqual(Formatter.ensureTerminalPunctuation("really?"), "really?")
  }

  func testEnsurePunctuationExclamation() {
    XCTAssertEqual(Formatter.ensureTerminalPunctuation("wow!"), "wow!")
  }

  func testEnsurePunctuationEmpty() {
    XCTAssertEqual(Formatter.ensureTerminalPunctuation(""), "")
  }

  // MARK: - Full pipeline

  func testApplyRulesFullPipeline() {
    let result = Formatter.applyRules("um   hello   world")
    XCTAssertEqual(result, "Hello world.")
  }

  func testApplyRulesWithFalseStart() {
    let result = Formatter.applyRules("the the cat sat on the mat")
    XCTAssertEqual(result, "The cat sat on the mat.")
  }

  func testApplyRulesAllFeatures() {
    let result = Formatter.applyRules("  um I I think uh you know it's working  ")
    XCTAssertEqual(result, "I think it's working.")
  }

  func testApplyRulesEmpty() {
    XCTAssertEqual(Formatter.applyRules(""), "")
  }

  func testApplyRulesAlreadyFormatted() {
    let result = Formatter.applyRules("Hello world.")
    XCTAssertEqual(result, "Hello world.")
  }

  func testApplyRulesOnlyFiller() {
    let result = Formatter.applyRules("um uh")
    XCTAssertEqual(result, "")
  }
}
