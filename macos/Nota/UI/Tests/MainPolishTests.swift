import XCTest
@testable import Nota

/// Covers the Lane-MAIN polish helpers: staged run progress mapping (A1-R1),
/// Recent-list recency bands and fallback titles (A1-H4/H6), and the
/// per-speaker transcript colors (A1-D3).
final class MainPolishTests: XCTestCase {
  // MARK: - RunStages (A1-R1)

  func testRunStages_mapsEachPhaseLabelToItsStage() {
    XCTAssertEqual(RunStages.index(forPhase: "Validating…"), 0)
    XCTAssertEqual(RunStages.index(forPhase: "Transcribing…"), 1)
    XCTAssertEqual(RunStages.index(forPhase: "Summarizing…"), 2)
    XCTAssertEqual(RunStages.index(forPhase: "Writing…"), 3)
  }

  func testRunStages_preparingAndUnknownHaveNoStage() {
    XCTAssertNil(RunStages.index(forPhase: "Preparing…"))
    XCTAssertNil(RunStages.index(forPhase: ""))
    XCTAssertNil(RunStages.index(forPhase: "Uploading…"))
  }

  func testRunStages_namesAndPhasesStayPaired() {
    XCTAssertEqual(RunStages.names.count, RunStages.phaseLabels.count)
  }

  // MARK: - HistoryPresentation bands (A1-H4)

  private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
    utcCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
  }

  func testBand_sameDayIsToday() {
    let now = date(2026, 7, 18, hour: 20)
    let morning = date(2026, 7, 18, hour: 6)
    XCTAssertEqual(HistoryPresentation.band(for: morning, now: now, calendar: utcCalendar), .today)
  }

  func testBand_threeDaysAgoIsThisWeek() {
    let now = date(2026, 7, 18)
    let entry = date(2026, 7, 15)
    XCTAssertEqual(HistoryPresentation.band(for: entry, now: now, calendar: utcCalendar), .thisWeek)
  }

  func testBand_twentyDaysAgoIsThisMonth() {
    let now = date(2026, 7, 18)
    let entry = date(2026, 6, 28)
    XCTAssertEqual(HistoryPresentation.band(for: entry, now: now, calendar: utcCalendar), .thisMonth)
  }

  func testBand_twoMonthsAgoIsEarlier() {
    let now = date(2026, 7, 18)
    let entry = date(2026, 5, 18)
    XCTAssertEqual(HistoryPresentation.band(for: entry, now: now, calendar: utcCalendar), .earlier)
  }

  func testShortDate_carriesYearOnlyWhenItDiffers() {
    let now = date(2026, 7, 18)
    let sameYear = HistoryPresentation.shortDate(for: date(2026, 6, 12), now: now, calendar: utcCalendar)
    let otherYear = HistoryPresentation.shortDate(for: date(2023, 6, 12), now: now, calendar: utcCalendar)
    XCTAssertFalse(sameYear.contains("2026"))
    XCTAssertTrue(otherYear.contains("2023"))
  }

  // MARK: - Fallback titles (A1-H6)

  func testFallbackTitle_stripsSummarySuffixAndTimestamp() {
    let url = URL(fileURLWithPath: "/tmp/voice-memo-20260521-101530.summary.md")
    XCTAssertEqual(HistoryPresentation.fallbackTitle(for: url), "voice-memo")
  }

  func testFallbackTitle_keepsInteriorDashes() {
    let url = URL(fileURLWithPath: "/tmp/team-sync-notes-20260521-101530.summary.md")
    XCTAssertEqual(HistoryPresentation.fallbackTitle(for: url), "team-sync-notes")
  }

  func testFallbackTitle_plainNameWithoutTimestampSurvives() {
    let url = URL(fileURLWithPath: "/tmp/standup.summary.md")
    XCTAssertEqual(HistoryPresentation.fallbackTitle(for: url), "standup")
  }

  // MARK: - Speaker colors echoed in the transcript (A1-D3)

  func testApplySpeakerColors_colorsSpeakerRunsByChipIndex() {
    let markdown = """
    [00:14] **Speaker 1:** hello there
    [00:20] **Speaker 2:** hi
    """
    let body = renderMarkdownAsRichText(markdown)
    let chips = [
      SpeakerChip(label: "Speaker 1", name: "", indicator: .none),
      SpeakerChip(label: "Speaker 2", name: "", indicator: .none),
    ]

    let colored = MainPaneView.applySpeakerColors(to: body, chips: chips)
    let text = colored.string as NSString

    let firstRange = text.range(of: "Speaker 1: ")
    XCTAssertNotEqual(firstRange.location, NSNotFound)
    let firstColor = colored.attribute(.foregroundColor, at: firstRange.location, effectiveRange: nil) as? NSColor
    XCTAssertEqual(firstColor, SpeakerColors.nsColor(at: 0))

    let secondRange = text.range(of: "Speaker 2: ")
    XCTAssertNotEqual(secondRange.location, NSNotFound)
    let secondColor = colored.attribute(.foregroundColor, at: secondRange.location, effectiveRange: nil) as? NSColor
    XCTAssertEqual(secondColor, SpeakerColors.nsColor(at: 1))
    XCTAssertNotEqual(firstColor, secondColor)
  }

  func testApplySpeakerColors_matchesRenamedSpeakers() {
    let markdown = "[00:14] **Speaker 1:** hello"
    let body = renderMarkdownAsRichText(markdown, overrides: ["Speaker 1": "Kenny"])
    let chips = [SpeakerChip(label: "Speaker 1", name: "Kenny", indicator: .enrolled)]

    let colored = MainPaneView.applySpeakerColors(to: body, chips: chips)
    let range = (colored.string as NSString).range(of: "Kenny: ")
    XCTAssertNotEqual(range.location, NSNotFound)
    let color = colored.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    XCTAssertEqual(color, SpeakerColors.nsColor(at: 0))
  }

  func testApplySpeakerColors_leavesBodyTextAndGenericBoldAlone() {
    let markdown = """
    [00:14] **Speaker 1:** hello **there** friend
    Plain **bold** paragraph.
    """
    let body = renderMarkdownAsRichText(markdown)
    let chips = [SpeakerChip(label: "Speaker 1", name: "", indicator: .none)]

    let colored = MainPaneView.applySpeakerColors(to: body, chips: chips)
    let text = colored.string as NSString

    // The spoken text after the speaker prefix keeps the label color.
    let spoken = text.range(of: "hello")
    let spokenColor = colored.attribute(.foregroundColor, at: spoken.location, effectiveRange: nil) as? NSColor
    XCTAssertEqual(spokenColor, .labelColor)

    // Generic bold outside a transcript line is untouched.
    let bold = text.range(of: "bold")
    let boldColor = colored.attribute(.foregroundColor, at: bold.location, effectiveRange: nil) as? NSColor
    XCTAssertEqual(boldColor, .labelColor)
  }

  func testApplySpeakerColors_noChipsReturnsBodyUnchanged() {
    let body = renderMarkdownAsRichText("[00:14] **Speaker 1:** hello")
    let colored = MainPaneView.applySpeakerColors(to: body, chips: [])
    XCTAssertTrue(colored.isEqual(to: body))
  }
}
