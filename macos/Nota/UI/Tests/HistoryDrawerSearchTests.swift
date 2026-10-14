import SwiftUI
import XCTest
@testable import Nota

// MARK: - One empty-state grammar (P-D4)

/// Six empty states used to draw at six scales (72 / 28 / no icon; `.title` /
/// `.callout` / 13pt medium / no title; centered and leading). They are one
/// view now, so what is worth pinning is that neither of the two axes it does
/// expose — alignment and ink — can move the type scale: a Settings pane and a
/// glass panel must lay the same content out at the same height.
final class EmptyStateGrammarTests: XCTestCase {
  private func height(_ view: some View) -> CGFloat {
    let host = NSHostingView(rootView: view.frame(width: 260))
    host.layoutSubtreeIfNeeded()
    return host.fittingSize.height
  }

  func testAlignmentAndInkDoNotChangeTheEmptyStateScale() {
    // One icon in both: SF Symbols do not all draw at the same height, and
    // this is a test about the grammar rather than about a glyph.
    let settings = height(
      EmptyStateView(
        icon: "tray",
        title: "No enrolled speakers",
        helpers: ["A helper line that says what is missing."]
      )
    )
    let panel = height(
      EmptyStateView(
        icon: "tray",
        title: "No enrolled speakers",
        helpers: ["A helper line that says what is missing."],
        alignment: .leading,
        ink: .field
      )
    )

    XCTAssertGreaterThan(settings, 0)
    XCTAssertEqual(settings, panel, accuracy: 0.5)
  }

  /// The trio the view draws is the one the token table declared for exactly
  /// this and nothing read: if someone retires a token, this goes red beside
  /// the view that needs it.
  func testTheEmptyStateGrammarIsTheDeclaredTrio() {
    XCTAssertEqual(Tokens.emptyHistoryIconFont, .system(size: 26, weight: .regular))
    XCTAssertEqual(Tokens.emptyHistoryLabelFont, .callout)
    XCTAssertEqual(Tokens.emptyHistoryHelperFont, .caption)
    XCTAssertEqual(Metrics.emptyHistoryStackSpacing, 8)
  }
}

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

// MARK: - A busy row says what is off (P-C8)

/// While a file transcription runs the whole row used to be `.disabled`, which
/// killed pin, Reveal in Finder and the deletion verbs — none of which touch
/// anything a run owns — and explained nothing, because `.help` does not fire
/// on a disabled control. Only opening is refused now, and the row says so.
final class HistoryRowAvailabilityTests: XCTestCase {
  func testOnlyOpeningIsRefusedWhileARunIsInFlight() {
    XCTAssertTrue(HistoryRowAvailability.canOpen(isRunning: false))
    XCTAssertFalse(HistoryRowAvailability.canOpen(isRunning: true))
  }

  func testTheRowSaysWhyItIsBusy() {
    XCTAssertEqual(
      HistoryRowAvailability.help(isRunning: true),
      "Busy \u{2014} a transcription is running"
    )
    XCTAssertEqual(
      HistoryRowAvailability.help(isRunning: false),
      "Open this transcript"
    )
  }

  /// **Pin is reachable with VoiceOver or Switch Control** (KB-7). On an
  /// unpinned row the pin button is drawn only under the pointer, so the row's
  /// own element carries the verb by name, in the word its tooltip already
  /// uses. A named action does not reach Full Keyboard Access on its own.
  func testPinIsANamedActionOnTheRow() throws {
    XCTAssertEqual(HistoryRowAvailability.pinActionName(isPinned: false), "Pin")
    XCTAssertEqual(HistoryRowAvailability.pinActionName(isPinned: true), "Unpin")
    let source = drawerUISource("HistoryDrawerView.swift")
    let start = try XCTUnwrap(source.range(of: "private struct HistoryDrawerRow: View {"))
    let end = try XCTUnwrap(source.range(of: "\n}\n", range: start.upperBound..<source.endIndex))
    let row = String(source[start.lowerBound..<end.upperBound])
    XCTAssertTrue(
      row.contains(
        ".accessibilityAction(named: HistoryRowAvailability.pinActionName(isPinned: isPinned))"),
      "pinning a transcript is a pointer-only verb again")
  }
}

// MARK: - Dictation rows (PT-6, FB-6)

/// **A dictation row opens from the keyboard, and a failed copy says so.**
///
/// The row's expand-and-copy was an `.onTapGesture` on a plain stack: not
/// focusable, not a button to VoiceOver, so the copy, the expansion and the
/// Insert Again / Delete buttons that only exist inside it were unreachable
/// without a pointer. And the expansion — decision 16's receipt of the copy —
/// appeared whether or not the copy landed.
final class DictationRowTests: XCTestCase {
  /// Success adds no words (the expansion is the receipt); failure does.
  func testOnlyAFailedCopyIsSaidOutLoud() {
    XCTAssertNil(DictationRowCopy.failure(copied: true))
    XCTAssertEqual(DictationRowCopy.failure(copied: false), "Could not copy")
  }

  /// A press on an open row collapses it and copies nothing; the hint may not
  /// promise a copy there.
  func testTheHintSaysWhatAPressWillDo() {
    XCTAssertTrue(DictationRowCopy.hint(isExpanded: false).contains("Copies"))
    XCTAssertFalse(DictationRowCopy.hint(isExpanded: true).contains("Copies"))
  }

  /// Focus and the button trait need a window server, and SwiftUI publishes no
  /// accessibility tree for an unhosted hosting view, so the row's shape is
  /// read from the source: a plain Button whose label is the inner stack, no
  /// tap gesture left anywhere in the row, and Insert Again outside it.
  func testTheRowIsAButtonAndNotATapGesture() throws {
    let source = drawerUISource("HistoryDrawerView.swift")
    let start = try XCTUnwrap(source.range(of: "private func dictationRow("))
    let end = try XCTUnwrap(
      source.range(
        of: "// MARK: - Drawer row (transcripts)", range: start.upperBound..<source.endIndex))
    let row = String(source[start.lowerBound..<end.lowerBound])
    XCTAssertFalse(
      row.contains(".onTapGesture"),
      "the dictation row is back on a tap gesture a keyboard cannot reach")
    let button = try XCTUnwrap(row.range(of: "Button {"), "the row's expansion is not a Button")
    let label = try XCTUnwrap(
      row.range(of: "} label: {", range: button.upperBound..<row.endIndex))
    let plain = try XCTUnwrap(
      row.range(of: ".buttonStyle(.plain)", range: label.upperBound..<row.endIndex))
    let insertAgain = try XCTUnwrap(row.range(of: "Button(\"Insert Again\")"))
    XCTAssertLessThan(
      plain.lowerBound, insertAgain.lowerBound,
      "Insert Again is inside the expanding Button — a button may not hold buttons")
  }
}

/// A UI source file, found relative to this test's own path. The test target
/// copies no resources, so a bundle lookup would silently resolve to nil.
private func drawerUISource(_ name: String) -> String {
  let url = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent(name)
  let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
  XCTAssertFalse(text.isEmpty, "could not read \(name) beside this test")
  return text
}
