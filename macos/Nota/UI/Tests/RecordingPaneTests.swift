import AppKit
import SwiftUI
import XCTest

@testable import Nota

/// The B2 recording pane's promises, asserted against the pure decisions the
/// views read — the split `SessionTimerMetrics` and `HUDPrompterMetrics`
/// already established. The two hosting-view cases at the end are here because
/// "the column is 288pt and the transcript takes the rest" is a claim about
/// layout, and only a layout can answer it.
@MainActor
final class RecordingPaneTests: XCTestCase {
  // MARK: - The fold

  func testTheColumnIsTwoHundredAndEightyEightPointsWide() {
    XCTAssertEqual(RecordingPaneMetrics.columnWidth, 288)
  }

  func testTheColumnFoldsIntoAStripBelowSevenTwenty() {
    XCTAssertEqual(RecordingPaneLayout.form(width: 1440), .column)
    XCTAssertEqual(RecordingPaneLayout.form(width: 720), .column)
    XCTAssertEqual(RecordingPaneLayout.form(width: 719), .strip)
    XCTAssertEqual(RecordingPaneLayout.form(width: 480), .strip)
  }

  /// The marker list is the *only* thing the fold gives up. Everything the
  /// column carries that answers "is this session flowing" survives it, which
  /// is the point of folding rather than hiding.
  func testTheFoldLosesTheMarkerListAndNothingElse() {
    XCTAssertTrue(RecordingPaneLayout.showsMarkerList(.column))
    XCTAssertFalse(RecordingPaneLayout.showsMarkerList(.strip))

    // The timer and the meter both survive, at their own sizes.
    XCTAssertEqual(RecordingPaneLayout.timerBase(.column), 58)
    XCTAssertEqual(RecordingPaneLayout.timerBase(.strip), 26)
    XCTAssertEqual(RecordingPaneLayout.meterVariant(.column), .tall)
    XCTAssertEqual(RecordingPaneLayout.meterVariant(.strip), .compact)
  }

  // MARK: - The timer steps at the hour without reflowing

  /// The acceptance case, restated at *this* pane's base size and against
  /// `SessionTimerMetrics` rather than a second derivation of it: 58 → 42, and
  /// the plate the column reserves does not depend on `elapsed` at all.
  func testTheColumnTimerStepsAtTheHourAndTheReserveDoesNot() {
    let base = RecordingPaneMetrics.columnTimerBase
    XCTAssertEqual(SessionTimerMetrics.fontSize(base: base, elapsed: 3599), 58)
    XCTAssertEqual(SessionTimerMetrics.fontSize(base: base, elapsed: 3600), 42)

    let widths = [0, 3599, 3600, 36_000, 86_399]
      .map { _ in SessionTimerMetrics.plateWidth(base: base) }
    XCTAssertEqual(Set(widths).count, 1)
  }

  /// The ring is derived from the plate it has to contain, not typed in — so
  /// the step at the hour changes the glyphs inside a circle that never moves,
  /// and a future change to the base size cannot silently clip the clock.
  func testTheRingContainsTheWidestTimerFormAndStillFitsTheColumn() {
    let available = RecordingPaneMetrics.columnWidth - 2 * RecordingPaneMetrics.columnPadding
    XCTAssertLessThanOrEqual(
      RecordingPaneMetrics.ringDiameterNeeded,
      available,
      "the ring needed to hold the timer no longer fits the 288pt column"
    )
    XCTAssertEqual(
      RecordingPaneMetrics.ringDiameter,
      RecordingPaneMetrics.ringDiameterNeeded,
      "the ring is being clamped by the column, which means it is clipping the clock"
    )
    XCTAssertGreaterThan(
      RecordingPaneMetrics.ringDiameter,
      SessionTimerMetrics.plateWidth(base: RecordingPaneMetrics.columnTimerBase)
    )
  }

  // MARK: - Kind is a label and nothing else

  /// The acceptance item, made mechanical: across every state the pane can be
  /// in, the whole of the difference between a memo and a meeting is one word.
  func testAMemoAndAMeetingDifferByExactlyOneString() {
    for controls in LiveMeetingControls.allCases {
      let meeting = RecordingPaneCopy.all(kind: .meeting, controls: controls)
      let memo = RecordingPaneCopy.all(kind: .memo, controls: controls)
      XCTAssertEqual(meeting.count, memo.count)
      let differing = zip(meeting, memo).filter { $0 != $1 }
      XCTAssertEqual(
        differing.count,
        1,
        "\(controls): \(differing.count) strings differ between memo and meeting"
      )
      XCTAssertEqual(differing.first?.0, RecordingPaneCopy.kindLine(kind: .meeting, controls: controls))
      XCTAssertEqual(differing.first?.1, RecordingPaneCopy.kindLine(kind: .memo, controls: controls))
    }
  }

  /// And the difference inside that one string is the noun alone: the activity
  /// half is kind-independent, so no state can grow a memo-only phrasing.
  func testTheKindLineDiffersOnlyInItsNoun() {
    for controls in LiveMeetingControls.allCases {
      let meeting = RecordingPaneCopy.kindLine(kind: .meeting, controls: controls)
      let memo = RecordingPaneCopy.kindLine(kind: .memo, controls: controls)
      XCTAssertEqual(
        meeting.dropFirst(RecordingPaneCopy.noun(.meeting).count),
        memo.dropFirst(RecordingPaneCopy.noun(.memo).count)
      )
      XCTAssertTrue(meeting.hasPrefix("Meeting"))
      XCTAssertTrue(memo.hasPrefix("Memo"))
    }
  }

  func testTheKindLineNamesWhatTheSessionIsDoing() {
    XCTAssertEqual(RecordingPaneCopy.kindLine(kind: .meeting, controls: .stop), "Meeting · listening")
    XCTAssertEqual(RecordingPaneCopy.kindLine(kind: .memo, controls: .stop), "Memo · listening")
    XCTAssertEqual(RecordingPaneCopy.kindLine(kind: .memo, controls: .finalizing), "Memo · finishing")
  }

  /// `.file` is not a live-session kind; if one ever reaches this surface it
  /// reads as a meeting rather than as a blank.
  func testAnUnexpectedKindReadsAsAMeeting() {
    XCTAssertEqual(RecordingPaneCopy.noun(.file), "Meeting")
  }

  // MARK: - Reduce Motion / Reduce Transparency

  /// Restated at the pane level: the ring the column draws is the one that
  /// stops, and the meter beside it is the one that never does. This is the
  /// asymmetry `RecordingMotion` owns; the pane may not reintroduce a second
  /// opinion about it.
  func testTheRingStopsBreathingAndTheMeterKeepsMoving() {
    XCTAssertNil(RecordingMotion.ringAnimation(reduceMotion: true))
    XCTAssertNotNil(RecordingMotion.meterAnimation(reduceMotion: true))
    XCTAssertFalse(SessionRingMetrics.breathes(reduceMotion: true))
  }

  /// Reduce Transparency may change what the panels are *made of* and nothing
  /// about where anything is: every number the pane lays out with is a
  /// constant, and the ember is a function of the color scheme alone.
  func testNoLayoutNumberAndNoEmberDependsOnReduceTransparency() {
    // Geometry: constants, so there is nothing for an accessibility setting to
    // reach. (A `@Environment` read cannot appear in these expressions.)
    XCTAssertEqual(RecordingPaneMetrics.columnWidth, 288)
    XCTAssertEqual(RecordingPaneMetrics.foldWidth, 720)
    XCTAssertEqual(RecordingPaneMetrics.gutterWidth, 52)
    XCTAssertEqual(RecordingPaneMetrics.stripMinHeight, 64)

    // The accent is untouched by either setting; only the scheme moves it.
    XCTAssertEqual(CraftTokens.ember(.light), CraftTokens.emberLight)
    XCTAssertEqual(CraftTokens.ember(.dark), CraftTokens.emberDark)

    // The hairline and the shadow the glass panel draws are constants, so they
    // survive the material degrading to an opaque one.
    XCTAssertEqual(CraftTokens.panelHairlineWidth, 1)
    XCTAssertGreaterThan(CraftTokens.panelShadowRadius, 0)
  }

  // MARK: - Markers

  func testAMarkerListIsNewestFirst() {
    let log = SessionMarkerLog()
    XCTAssertTrue(log.markers.isEmpty)
    log.mark(at: 10)
    log.mark(at: 40)
    log.mark(at: 95)
    XCTAssertEqual(log.markers.map(\.at), [95, 40, 10])
  }

  func testAMarkerNeverCarriesANegativeTime() {
    let log = SessionMarkerLog()
    log.mark(at: -3)
    XCTAssertEqual(log.markers.first?.at, 0)
  }

  func testResetEmptiesTheLog() {
    let log = SessionMarkerLog()
    log.mark(at: 5)
    log.reset()
    XCTAssertTrue(log.markers.isEmpty)
  }

  /// A marker's timestamp is the same clock the timer runs, so "12:04" on the
  /// marker and "12:04" in the gutter name the same instant.
  func testMarkerAndGutterTimestampsShareTheTimersClock() {
    XCTAssertEqual(LiveTranscript.timestamp(724), SessionTimerMetrics.text(elapsed: 724))
    XCTAssertEqual(LiveTranscript.timestamp(3600), "1:00:00")
  }

  // MARK: - Transcript blocks and the speaker column

  private func segment(_ text: String, at end: TimeInterval) -> LiveMeetingSession.LiveSegment {
    LiveMeetingSession.LiveSegment(id: UUID(), text: text, endTime: end)
  }

  func testWithNoSpeakerLabelsTheTranscriptIsOneContinuousBlock() {
    let lines = LiveTranscript.lines(
      segments: [segment("one", at: 3), segment("two", at: 7)],
      partial: nil,
      elapsed: 7
    )
    let blocks = LiveTranscript.blocks(lines)
    XCTAssertEqual(blocks.count, 1)
    XCTAssertNil(blocks[0].speaker)
    XCTAssertEqual(blocks[0].lines.map(\.text), ["one", "two"])
    XCTAssertEqual(blocks[0].startedAt, 3, "a turn's gutter timestamp is where it started")
  }

  /// The layout does not have to change when the labels arrive: the grouping is
  /// already written and already correct, it is only waiting to be fed.
  func testSpeakerLabelsGroupIntoTurnsWithoutAnyLayoutChange() {
    let a1 = LiveTranscriptLine(id: UUID(), text: "one", endTime: 3, speaker: "Amara")
    let a2 = LiveTranscriptLine(id: UUID(), text: "two", endTime: 7, speaker: "Amara")
    let k1 = LiveTranscriptLine(id: UUID(), text: "three", endTime: 11, speaker: "Kenny")
    let a3 = LiveTranscriptLine(id: UUID(), text: "four", endTime: 15, speaker: "Amara")

    let blocks = LiveTranscript.blocks([a1, a2, k1, a3])
    XCTAssertEqual(blocks.map(\.speaker), ["Amara", "Kenny", "Amara"])
    XCTAssertEqual(blocks.map { $0.lines.count }, [2, 1, 1])
    XCTAssertEqual(blocks[0].id, a1.id, "a block anchors on its first line, so it is a stable scroll target")
    XCTAssertEqual(blocks[2].startedAt, 15)
  }

  func testTheVolatileTailIsALineLikeAnyOtherAndIsMarkedVolatile() {
    let lines = LiveTranscript.lines(
      segments: [segment("said", at: 4)],
      partial: "still saying",
      elapsed: 9
    )
    XCTAssertEqual(lines.count, 2)
    XCTAssertFalse(lines[0].isVolatile)
    XCTAssertTrue(lines[1].isVolatile)
    XCTAssertEqual(lines[1].id, LiveTranscript.volatileLineID, "the tail needs one id the scroll can chase")
    XCTAssertEqual(lines[1].endTime, 9, "the in-flight tail is timestamped now, not at the last final")

    // It continues the turn rather than starting one.
    XCTAssertEqual(LiveTranscript.blocks(lines).count, 1)
  }

  func testAnEmptyPartialProducesNoVolatileLine() {
    XCTAssertEqual(
      LiveTranscript.lines(segments: [segment("said", at: 4)], partial: "", elapsed: 9).count,
      1
    )
    XCTAssertEqual(
      LiveTranscript.lines(segments: [segment("said", at: 4)], partial: nil, elapsed: 9).count,
      1
    )
  }

  func testASilentSessionHasNoBlocksAtAll() {
    XCTAssertTrue(LiveTranscript.blocks(LiveTranscript.lines(segments: [], partial: nil, elapsed: 0)).isEmpty)
  }

  // MARK: - Laid out

  /// The acceptance case: the column takes exactly 288pt and the transcript
  /// takes the rest, at full height.
  func testTheColumnTakesItsWidthAndTheTranscriptTakesTheRest() {
    let width: CGFloat = 1000
    let height: CGFloat = 600
    let host = NSHostingView(
      rootView: HStack(spacing: 0) {
        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        SessionColumnView(
          elapsed: 61,
          level: 0.4,
          kind: .meeting,
          controls: .stop,
          markers: [],
          onMark: {},
          onStop: {}
        )
      }
      .frame(width: width, height: height)
    )
    host.layoutSubtreeIfNeeded()
    XCTAssertEqual(host.fittingSize.width, width, accuracy: 0.5)

    let column = NSHostingView(
      rootView: SessionColumnContent(
        elapsed: 61,
        level: 0.4,
        kind: .meeting,
        controls: .stop,
        markers: [],
        onMark: {},
        onStop: {}
      )
    )
    column.layoutSubtreeIfNeeded()
    XCTAssertEqual(
      column.fittingSize.width,
      RecordingPaneMetrics.columnWidth,
      accuracy: 0.5,
      "the session column is not 288pt wide"
    )
  }

  /// Why `SessionColumnView` wraps its content in a scroll view rather than
  /// being a plain stack: the column at full size is **taller than the smallest
  /// window this app allows**, and the alternative to scrolling was shrinking
  /// the timer — which is the one thing the column exists to make large.
  ///
  /// If a future change makes the content fit 560pt, this test is the one that
  /// says the wrapper can go.
  func testTheColumnIsTallerThanTheSmallestWindowWhichIsWhyItScrolls() {
    let host = NSHostingView(
      rootView: SessionColumnContent(
        elapsed: 3600,
        level: 0.4,
        kind: .meeting,
        controls: .stop,
        markers: [SessionMarker(at: 1), SessionMarker(at: 2)],
        onMark: {},
        onStop: {}
      )
    )
    host.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(host.fittingSize.height, Metrics.windowMinHeight)
    XCTAssertEqual(host.fittingSize.width, RecordingPaneMetrics.columnWidth, accuracy: 0.5)
  }

  /// The folded form really is a strip: one row tall, not a column laid
  /// sideways. It is checked against the *column's* height so the assertion
  /// cannot pass by the strip merely being short in absolute terms.
  func testTheFoldedFormIsOneRowTall() {
    let strip = NSHostingView(
      rootView: SessionStripView(
        elapsed: 61,
        level: 0.4,
        kind: .memo,
        controls: .stop,
        onMark: {},
        onStop: {}
      )
      .frame(width: 640)
    )
    strip.layoutSubtreeIfNeeded()
    let height = strip.fittingSize.height
    XCTAssertGreaterThanOrEqual(height, RecordingPaneMetrics.stripMinHeight)
    XCTAssertLessThan(
      height,
      RecordingPaneMetrics.ringDiameter,
      "the folded form is taller than the column's ring — it did not fold, it wrapped"
    )
  }

  /// Crossing the hour re-sizes the glyphs and moves nothing around them —
  /// including the column they sit in. Measured on the *content* rather than on
  /// `SessionColumnView`, whose width is a fixed frame and would answer 288
  /// even if the timer inside it had reflowed.
  func testTheColumnDoesNotReflowWhenTheTimerCrossesTheHour() {
    func columnSize(elapsed: TimeInterval) -> CGSize {
      let host = NSHostingView(
        rootView: SessionColumnContent(
          elapsed: elapsed,
          level: 0.4,
          kind: .meeting,
          controls: .stop,
          markers: [],
          onMark: {},
          onStop: {}
        )
      )
      host.layoutSubtreeIfNeeded()
      return host.fittingSize
    }
    let before = columnSize(elapsed: 3599)
    let after = columnSize(elapsed: 3600)
    XCTAssertGreaterThan(before.height, 0, "hosting view produced no layout")
    XCTAssertEqual(before.width, after.width, accuracy: 0.5, "the column reflowed at the hour")
    XCTAssertEqual(before.height, after.height, accuracy: 0.5, "the column changed height at the hour")
    XCTAssertNotEqual(
      SessionTimerMetrics.fontSize(base: RecordingPaneMetrics.columnTimerBase, elapsed: 3599),
      SessionTimerMetrics.fontSize(base: RecordingPaneMetrics.columnTimerBase, elapsed: 3600),
      "the size did not step, so 'no reflow' proves nothing"
    )
  }
}
