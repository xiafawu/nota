import XCTest
@testable import Nota

// MARK: - Dictation search predicate (decision 17)

final class DictationSearchTests: XCTestCase {
  private func entry(text: String) -> DictationHistoryEntry {
    DictationHistoryEntry(
      id: UUID(),
      text: text,
      completedAt: Date(),
      status: .delivered,
      statusDetail: nil,
      targetBundleID: "com.example.app",
      targetProcessID: nil,
      updatedAt: Date()
    )
  }

  func testCaseInsensitiveSubstringOverText() {
    let entry = entry(text: "Ship the variant B demo by Friday")
    XCTAssertTrue(DictationSearch.matches(entry, query: "variant"))
    XCTAssertTrue(DictationSearch.matches(entry, query: "VARIANT"))
    XCTAssertTrue(DictationSearch.matches(entry, query: "friday"))
    XCTAssertFalse(DictationSearch.matches(entry, query: "variantx"))
    XCTAssertFalse(DictationSearch.matches(entry, query: "unrelated"))
  }

  func testBlankQueryMatchesEverything() {
    let entry = entry(text: "anything")
    XCTAssertTrue(DictationSearch.matches(entry, query: ""))
    XCTAssertTrue(DictationSearch.matches(entry, query: "   \n "))
  }

  func testMatchCountCountsOnlyMatchingEntries() {
    let entries = [
      entry(text: "Review the PR"),
      entry(text: "Ship the demo"),
      entry(text: "Review the design doc"),
      entry(text: "Book the room"),
    ]
    XCTAssertEqual(DictationSearch.matchCount(entries, query: "review"), 2)
    XCTAssertEqual(DictationSearch.matchCount(entries, query: "REVIEW"), 2)
    XCTAssertEqual(DictationSearch.matchCount(entries, query: "the"), 4)
    XCTAssertEqual(DictationSearch.matchCount(entries, query: "zzz"), 0)
    XCTAssertEqual(DictationSearch.matchCount(entries, query: ""), 4)
  }

  func testInactiveTabBadgeCountIsTheOtherTabTotal() {
    // The badge shows the other tab's matches while the query is live; the
    // drawer computes it from these counts (the count itself is the pure
    // matchCount above).
    let transcripts = [
      HistoryEntry.make(url: URL(fileURLWithPath: "/tmp/a.summary.md"), modifiedAt: Date(), kind: .file),
    ]
    let dictations = [
      entry(text: "Email the team about the review"),
      entry(text: "Order lunch"),
    ]
    // Transcripts tab active, query live: badge = dictation matches.
    let badgeOnTranscriptsTab = DictationSearch.matchCount(dictations, query: "review")
    XCTAssertEqual(badgeOnTranscriptsTab, 1)
    // Dictation tab active, query live: badge = transcript matches.
    let badgeOnDictationTab = transcripts.filter {
      HistoryPresentation.matches($0, query: "review")
    }.count
    XCTAssertEqual(badgeOnDictationTab, 0)
  }

  func testTranscriptMatchingStillUsesHistoryPresentation() {
    // Decision 17: transcript matching stays on the transcript predicate —
    // a title match counts for the badge on the dictation tab.
    let entry = HistoryEntry.make(
      url: URL(fileURLWithPath: "/tmp/Team Sync-20260701-120000.summary.md"),
      modifiedAt: Date(),
      kind: .meeting
    )
    XCTAssertTrue(HistoryPresentation.matches(entry, query: "team sync"))
    XCTAssertTrue(HistoryPresentation.matches(entry, query: "TEAM"))
  }
}
