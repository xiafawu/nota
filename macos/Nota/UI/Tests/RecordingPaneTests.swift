import AppKit
import SwiftUI
import XCTest

@testable import Nota

/// The recording bar's promises, asserted against the pure decisions the views
/// read — the split `SessionTimerMetrics` and `HUDPrompterMetrics` already
/// established. The hosting-view cases are here because "the bloom makes the
/// bar taller and nothing else" is a claim about layout, and only a layout can
/// answer it.
@MainActor
final class RecordingPaneTests: XCTestCase {
  // MARK: - The bloom

  /// The two states of the clock, and that they really are two sizes on screen
  /// rather than two names for one number. The **views** read these: a metric
  /// only a test consults is a metric the views are free to disagree with.
  func testTheClockHasARestingSizeAndABloomedOne() {
    XCTAssertEqual(RecordingPaneLayout.timerBase(bloomed: false), 22)
    XCTAssertEqual(RecordingPaneLayout.timerBase(bloomed: true), 58)
    XCTAssertEqual(RecordingPaneLayout.meterVariant(bloomed: false), .compact)
    XCTAssertEqual(RecordingPaneLayout.meterVariant(bloomed: true), .tall)

    XCTAssertGreaterThan(
      SessionTimerMetrics.plateWidth(base: RecordingPaneLayout.timerBase(bloomed: true)),
      SessionTimerMetrics.plateWidth(base: RecordingPaneLayout.timerBase(bloomed: false))
    )
    XCTAssertEqual(
      RecordingPaneLayout.timerBase(bloomed: true),
      58,
      "the bloom no longer restores the size the session column made the clock"
    )
  }

  /// The bloom's geometry, which is the whole of what it does: the **card**
  /// grows, and it grows by exactly what the bigger clock needs.
  func testTheBloomGrowsTheCardAndDerivesItsHeightFromTheClock() {
    let rest = RecordingPaneMetrics.barHeight(bloomed: false)
    let bloom = RecordingPaneMetrics.barHeight(bloomed: true)
    XCTAssertGreaterThan(bloom, rest, "the bloom does not make the bar any taller")

    // Derived, not typed in: each height is its state's content plus the bar's
    // own padding, and the bloomed content is the 58pt clock's reserved plate.
    for bloomed in [false, true] {
      XCTAssertEqual(
        RecordingPaneMetrics.barHeight(bloomed: bloomed),
        RecordingPaneMetrics.barContentHeight(bloomed: bloomed)
          + 2 * RecordingPaneMetrics.barPaddingV
      )
    }
    XCTAssertEqual(
      RecordingPaneMetrics.barContentHeight(bloomed: true),
      SessionTimerMetrics.plateHeight(base: RecordingPaneMetrics.bloomTimerBase),
      "the bloomed bar is no longer as tall as the clock it exists to show"
    )
    // At rest the buttons are the tallest thing on the row, which is why the
    // resting height does not move when the 22pt clock does.
    XCTAssertEqual(
      RecordingPaneMetrics.barContentHeight(bloomed: false),
      RecordingPaneMetrics.controlRowHeight
    )
  }

  /// The trap this ticket came with: the plate is reserved **per state** and is
  /// independent of `elapsed` in both, so the animation has a fixed start and a
  /// fixed end and the digits are never re-measured while it is in flight.
  func testNeitherStateOfTheClockRemeasuresItselfAsTimePasses() {
    for base in [RecordingPaneMetrics.restTimerBase, RecordingPaneMetrics.bloomTimerBase] {
      // `plateWidth`/`plateHeight` take no `elapsed` at all — that is the
      // construction — so what is asserted here is the *drawn* clock, which is
      // where a dropped `.frame(width:)` would show up.
      func drawn(_ elapsed: TimeInterval) -> CGSize {
        let host = NSHostingView(rootView: SessionTimer(elapsed: elapsed, base: base))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
      }
      let sizes = [TimeInterval(0), 3599, 3600, 86_399].map(drawn)
      XCTAssertGreaterThan(sizes[0].width, 0, "the hosting view produced no layout")
      for size in sizes {
        XCTAssertEqual(
          size.width,
          sizes[0].width,
          accuracy: 0.5,
          "the drawn clock changed width at base \(base) — the plate is not reserved"
        )
      }
    }
  }

  /// Reduce Motion makes the bloom **snap**, and that decision lives in
  /// `RecordingMotion` beside the other two rather than in an `if` in the view.
  /// Nil is a snap and not a freeze: `withAnimation(nil)` still assigns the
  /// state, so both cards are drawn — only the travel is gone.
  func testUnderReduceMotionTheBloomSnapsRatherThanAnimating() {
    XCTAssertNil(RecordingMotion.bloomAnimation(reduceMotion: true))
    XCTAssertNotNil(RecordingMotion.bloomAnimation(reduceMotion: false))
    // …and the two states are unchanged by the setting: what Reduce Motion
    // takes is the animation, never the size the bar arrives at.
    XCTAssertGreaterThan(
      RecordingPaneMetrics.barHeight(bloomed: true),
      RecordingPaneMetrics.barHeight(bloomed: false)
    )
  }

  // MARK: - The timer steps at the hour without reflowing

  /// The acceptance case, restated at the bloomed base size and against
  /// `SessionTimerMetrics` rather than a second derivation of it: 58 → 42, and
  /// the clock the bar **draws** keeps one width across the step.
  ///
  /// The second half used to map five elapsed values through a closure that
  /// discarded its element (`.map { _ in plateWidth(base:) }`) and assert the
  /// resulting set had one member — true by construction, since `plateWidth`
  /// takes no `elapsed`. It is now measured off the rendered `SessionTimer`, so
  /// it fails if the `.frame(width: plateWidth)` that reserves the plate is
  /// ever dropped.
  func testTheBloomedTimerStepsAtTheHourAndTheDrawnClockKeepsItsWidth() {
    let base = RecordingPaneMetrics.bloomTimerBase
    XCTAssertEqual(SessionTimerMetrics.fontSize(base: base, elapsed: 3599), 58)
    XCTAssertEqual(SessionTimerMetrics.fontSize(base: base, elapsed: 3600), 42)

    func drawnWidth(_ elapsed: TimeInterval) -> CGFloat {
      let host = NSHostingView(rootView: SessionTimer(elapsed: elapsed, base: base))
      host.layoutSubtreeIfNeeded()
      return host.fittingSize.width
    }

    let widths = [TimeInterval(0), 3599, 3600, 36_000, 86_399].map(drawnWidth)
    for (elapsed, width) in zip([TimeInterval(0), 3599, 3600, 36_000, 86_399], widths) {
      XCTAssertEqual(
        width,
        widths[0],
        accuracy: 0.5,
        "the drawn clock changed width at \(elapsed) — the plate is not reserved"
      )
    }
    // …and the text really did change across those values, or "one width"
    // would be a fact about a string that never moved.
    XCTAssertNotEqual(SessionTimerMetrics.text(elapsed: 3599), SessionTimerMetrics.text(elapsed: 3600))
    XCTAssertGreaterThan(widths[0], 0, "the hosting view produced no layout")
  }

  /// The plate reserves a **line box**, not the ink, which is what a row that
  /// has to contain the digits needs — and it is the number the bar's height is
  /// derived from. (The column's ring cleared the ink instead, deliberately,
  /// and that ring is gone with the column: a circle around a 58pt clock is
  /// ~225pt across, i.e. taller than the transcript it would sit over.)
  func testThePlateReservesALineBoxTallerThanTheGlyphsAndDoesNotDependOnElapsed() {
    let base = RecordingPaneMetrics.bloomTimerBase
    XCTAssertGreaterThan(SessionTimerMetrics.plateHeight(base: base), base * 0.75)
    XCTAssertGreaterThan(
      SessionTimerMetrics.plateHeight(base: base),
      SessionTimerMetrics.plateHeight(base: RecordingPaneMetrics.restTimerBase)
    )
    // The widest form wins the reservation, so the step at the hour cannot ask
    // for a taller row than the one already reserved.
    XCTAssertGreaterThanOrEqual(
      SessionTimerMetrics.plateHeight(base: base),
      SessionTimerMetrics.plateHeight(base: SessionTimerMetrics.fontSize(base: base, elapsed: 3600))
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

  /// **Stop is a fill, not a material** — which is the whole reason it survives
  /// Reduce Transparency, the one setting that can take a material away. It is
  /// the one control that may never be hard to find.
  ///
  /// `accessibilityReduceTransparency` is a read-only environment value, so it
  /// cannot be driven from a test. What *can* be driven is the thing the
  /// setting is about: a material takes its appearance from what is behind it,
  /// and a fill does not. So Stop is rendered over two opposite backdrops and
  /// its interior compared, with the ghost button rendered the same way as the
  /// control — if the probe could not tell a material from a fill, the first
  /// half would pass for the wrong reason.
  ///
  /// This replaces a test that asserted five `static let`s equalled their own
  /// literals under a heading about Reduce Transparency. A constant cannot read
  /// an environment value, so it could not have failed.
  func testStopIsAFillAndNotAMaterialThatTheBackdropCanChange() {
    let size = CGSize(width: 240, height: 90)
    // Inside the 160pt-wide button (x 40…200) and clear of its centered label,
    // so what is sampled is the fill and not a glyph.
    let center = CGPoint(x: 60, y: 45)

    func stop(over backdrop: Color) -> NSBitmapImageRep? {
      RenderProbe.bitmap(
        ZStack {
          backdrop
          Button(RecordingPaneCopy.stopTitle) {}
            .buttonStyle(RecordingStopButtonStyle())
            .frame(width: 160)
        }
        .environment(\.colorScheme, .light),
        size: size
      )
    }
    func ghost(over backdrop: Color) -> NSBitmapImageRep? {
      RenderProbe.bitmap(
        ZStack {
          backdrop
          Button(RecordingPaneCopy.markTitle) {}
            .buttonStyle(RecordingGhostButtonStyle())
            .frame(width: 160)
        }
        .environment(\.colorScheme, .light),
        size: size
      )
    }

    guard
      let onWhite = stop(over: .white), let onBlack = stop(over: .black),
      let ghostWhite = ghost(over: .white), let ghostBlack = ghost(over: .black)
    else { return XCTFail("the hosting view produced no bitmap") }

    let stopWhite = RenderProbe.color(onWhite, at: center)
    let stopBlack = RenderProbe.color(onBlack, at: center)
    XCTAssertNotNil(stopWhite)
    XCTAssertTrue(
      RenderProbe.matches(stopWhite, NSColor(CraftTokens.ember(.light)), tolerance: 0.10),
      "Stop's interior is not the ember fill"
    )
    XCTAssertTrue(
      RenderProbe.matches(stopWhite, stopBlack, tolerance: 0.02),
      "Stop changed with the backdrop — it is a material, and a material can be taken away"
    )

    // The control: the ghost button *is* a material, and this probe sees it.
    XCTAssertFalse(
      RenderProbe.matches(
        RenderProbe.color(ghostWhite, at: center),
        RenderProbe.color(ghostBlack, at: center),
        tolerance: 0.02
      ),
      "the ghost button did not change with the backdrop either, so this probe proves nothing"
    )
  }

  /// Nothing the pane lays out with can move under an accessibility setting:
  /// every number is a constant or derived from constants, so there is no
  /// `@Environment` read for one to reach. The bloom is the one state the bar
  /// has, and it is driven by the pointer — Reduce Motion reaches the animation
  /// between the two heights and neither of the heights.
  func testNoPaneGeometryMovesUnderAnAccessibilitySetting() {
    XCTAssertEqual(RecordingPaneMetrics.gutterWidth, 52)
    XCTAssertEqual(RecordingPaneMetrics.dotDiameter, 20)
    // 65: the Stop capsule's 41pt row plus the bar's own 24 of padding. It is
    // measured from the button style rather than typed there, so this pins the
    // *answer* while `testTheRestingBarDrawsExactlyTheHeightItReserves` pins
    // that the answer is the one the bar draws. It read 64 while the bar drew
    // 65, which is how a whole file of geometry tests stayed green against a
    // reservation that never bound.
    XCTAssertEqual(RecordingPaneMetrics.barHeight(bloomed: false), 65)

    // The accent is untouched by either setting; only the scheme moves it.
    XCTAssertEqual(CraftTokens.ember(.light), CraftTokens.emberLight)
    XCTAssertEqual(CraftTokens.ember(.dark), CraftTokens.emberDark)
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

  /// The bar shows a **count**, and an empty log shows the flag alone rather
  /// than a tally of nothing. The popover is where the words live — the heading
  /// and `noMarkers` survived the column, which is what the owner's call asked
  /// for (2026-08-10).
  func testAnEmptyLogShowsNoCountAndTheWordsLiveInThePopover() {
    XCTAssertNil(RecordingPaneCopy.markerCount([]))
    XCTAssertEqual(RecordingPaneCopy.markerCount([SessionMarker(at: 3)]), "1")
    XCTAssertEqual(
      RecordingPaneCopy.markerCount((0..<12).map { SessionMarker(at: TimeInterval($0)) }),
      "12"
    )
    XCTAssertEqual(RecordingPaneCopy.markersHeading, "Moments")
    XCTAssertEqual(RecordingPaneCopy.noMarkers, "No moments yet")
  }

  /// A marker's timestamp is the same clock the timer runs, so "12:04" on the
  /// marker and "12:04" in the gutter name the same instant.
  func testMarkerAndGutterTimestampsShareTheTimersClock() {
    XCTAssertEqual(LiveTranscript.timestamp(724), SessionTimerMetrics.text(elapsed: 724))
    XCTAssertEqual(LiveTranscript.timestamp(3600), "1:00:00")
  }

  /// An unlabelled marker says **nothing** beside its timestamp. It used to
  /// fall back to the section heading, so every row under a heading reading
  /// MOMENTS read `12:04  Moments` — rendered, and evidently never looked at.
  func testAnUnlabelledMarkerRowIsItsTimestampAndNothingElse() {
    XCTAssertNil(RecordingPaneCopy.markerLabel(SessionMarker(at: 724)))
    XCTAssertNotEqual(
      RecordingPaneCopy.markerLabel(SessionMarker(at: 724)),
      RecordingPaneCopy.markersHeading,
      "a marker row is labelled with the list's own heading again"
    )
    // And a marker that *does* have one (XIA-433's auto-title) says it.
    XCTAssertEqual(
      RecordingPaneCopy.markerLabel(SessionMarker(at: 724, label: "Rollback note")),
      "Rollback note"
    )
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

  private func barHost(
    elapsed: TimeInterval = 61,
    kind: HistoryKind = .meeting,
    markers: [SessionMarker] = [],
    width: CGFloat = 980
  ) -> NSHostingView<some View> {
    let host = NSHostingView(
      rootView: SessionBarView(
        elapsed: elapsed,
        level: MicLevelFeed(level: 0.4),
        kind: kind,
        controls: .stop,
        markers: markers,
        onMark: {},
        onStop: {}
      )
      .frame(width: width)
    )
    host.layoutSubtreeIfNeeded()
    return host
  }

  /// The acceptance case: the bar is **one row** and the transcript takes the
  /// whole width. The row is what a test can measure; the width is the absence
  /// of the thing that used to take some of it, which is why the assertion is
  /// that the bar reserves no width of its own at any window size.
  func testTheBarIsOneRowAndTakesNoneOfTheTranscriptsWidth() {
    let height = barHost().fittingSize.height
    XCTAssertEqual(
      height,
      RecordingPaneMetrics.barHeight(bloomed: false),
      accuracy: 0.5,
      "the resting bar draws \(height)pt against a reservation of "
        + "\(RecordingPaneMetrics.barHeight(bloomed: false))pt"
    )

    // A bar has no intrinsic width to charge the transcript: at the narrowest
    // window the app allows it still lays out in one row.
    let narrow = barHost(width: Metrics.windowMinWidth).fittingSize.height
    XCTAssertEqual(
      narrow,
      height,
      accuracy: 0.5,
      "the bar grew taller at \(Metrics.windowMinWidth)pt — it wraps at a permitted window"
    )
  }

  /// Crossing the hour re-sizes the glyphs and moves nothing around them —
  /// including the bar they sit in.
  func testTheBarDoesNotReflowWhenTheTimerCrossesTheHour() {
    let before = barHost(elapsed: 3599).fittingSize
    let after = barHost(elapsed: 3600).fittingSize
    XCTAssertGreaterThan(before.height, 0, "hosting view produced no layout")
    XCTAssertEqual(before.height, after.height, accuracy: 0.5, "the bar changed height at the hour")
    XCTAssertNotEqual(
      SessionTimerMetrics.fontSize(base: RecordingPaneMetrics.restTimerBase, elapsed: 3599),
      SessionTimerMetrics.fontSize(base: RecordingPaneMetrics.restTimerBase, elapsed: 3600),
      "the size did not step, so 'no reflow' proves nothing"
    )
  }

  /// The moments live in the bar's popover, so the number of them may not
  /// change the bar. That is the whole reason the count is a count.
  func testTheNumberOfMomentsNeverChangesTheBar() {
    let none = barHost(markers: []).fittingSize
    let many = barHost(markers: (0..<40).map { SessionMarker(at: TimeInterval($0 * 7)) }).fittingSize
    XCTAssertEqual(none.height, many.height, accuracy: 0.5, "40 moments made the bar taller")
  }

  /// The resting height is the **Stop capsule**, and the constant that says so
  /// has to be measured from the style that draws it rather than typed beside
  /// it. It was typed — 40 against a row that lays out at 41 — so
  /// `barHeight(bloomed: false)` promised 64pt while the bar drew 65, the
  /// `.frame(minHeight:)` never bound, and the resting height was whatever child
  /// happened to be tallest: exactly what the constant exists to prevent, with
  /// every geometry test in this file green through it.
  ///
  /// Both halves are asserted, because either alone leaves the hole open. The
  /// **drawn Stop button** is the reservation (so the AppKit face the metric
  /// measures and the SwiftUI face the button draws cannot drift apart), and it
  /// is the tallest thing on the row (so it is really the floor).
  func testTheRestingBarDrawsExactlyTheHeightItReserves() {
    let stop = NSHostingView(
      rootView: Button(RecordingPaneCopy.stopTitle) {}
        .buttonStyle(RecordingStopButtonStyle())
        .frame(width: 160)
    )
    stop.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(stop.fittingSize.height, 0, "the hosting view produced no layout")
    XCTAssertEqual(
      stop.fittingSize.height,
      RecordingPaneMetrics.controlRowHeight,
      accuracy: 0.5,
      "Stop draws \(stop.fittingSize.height)pt and the bar reserves "
        + "\(RecordingPaneMetrics.controlRowHeight)pt for it"
    )

    // …and it is the floor, so the bar's content height is its height.
    XCTAssertEqual(
      RecordingPaneMetrics.barContentHeight(bloomed: false),
      RecordingPaneMetrics.controlRowHeight
    )
    XCTAssertEqual(
      barHost().fittingSize.height,
      RecordingPaneMetrics.barHeight(bloomed: false),
      accuracy: 0.5
    )
  }

  /// The same claim from the other side: the reservation **follows** the style.
  /// A padding change is supposed to move the bar's height with it, and the
  /// derivation is the only thing that makes that true.
  func testTheReservedRowIsDerivedFromTheStopStyleRatherThanTypedIn() {
    let line = ("0" as NSString)
      .size(withAttributes: [.font: RecordingStopButtonStyle.measuringFont])
      .height
    XCTAssertEqual(
      RecordingPaneMetrics.controlRowHeight,
      (line + 2 * RecordingStopButtonStyle.verticalPadding).rounded(.up)
    )
    XCTAssertEqual(RecordingStopButtonStyle.verticalPadding, CraftTokens.spacing12)
    XCTAssertEqual(RecordingStopButtonStyle.fontSize, 14)
  }

  // MARK: - The bloom's trigger is the whole bar

  /// The bar grows into a taller card "while the pointer is over it", and over
  /// **it** has to mean the bar and not its glyphs. A root `HStack` with no fill
  /// hit-tests to its children only, so `.onHover` on one reports the dot, the
  /// clock, the kind line and the three buttons — and nothing in the several
  /// hundred points of `Spacer` between them. Two opposite failures fall out: a
  /// pointer parked in the gap never blooms the bar at all, and a pointer
  /// travelling from the clock to Stop crosses the gap and fires `false` then
  /// `true`, costing two full bloom animations and two transcript relayouts
  /// inside one gesture.
  ///
  /// It is asserted here rather than left to `.contentShape(Rectangle())`
  /// because SwiftUI resolves hover inside the hosting view: neither `hitTest`
  /// nor the hosting view's tracking areas can tell a shaped bar from an
  /// unshaped one (measured, both ways), which is how this shipped. The tracking
  /// area is the same promise in something a test can read.
  func testTheWholeBarIsTheBloomsTriggerIncludingTheGap() {
    let hover = SessionHoverView()
    hover.frame = CGRect(x: 0, y: 0, width: 980, height: RecordingPaneMetrics.barHeight(bloomed: false))
    hover.updateTrackingAreas()

    XCTAssertEqual(hover.trackingAreas.count, 1, "the bar has no hover surface, or has two")
    XCTAssertEqual(
      hover.trackingAreas.first?.rect,
      hover.bounds,
      "the hover surface does not cover the bar — the gap between the clock and Stop is not in it"
    )
    // Re-laid out (the bloom makes the bar taller), the surface follows.
    hover.frame.size.height = RecordingPaneMetrics.barHeight(bloomed: true)
    hover.updateTrackingAreas()
    XCTAssertEqual(hover.trackingAreas.count, 1)
    XCTAssertEqual(hover.trackingAreas.first?.rect, hover.bounds)

    // And it reports both edges of the crossing.
    var reported: [Bool] = []
    hover.onHover = { reported.append($0) }
    hover.mouseEntered(with: Self.mouseMoved)
    hover.mouseExited(with: Self.mouseMoved)
    XCTAssertEqual(reported, [true, false])

    // It claims every point for hover and none for the mouse: Mark, Stop and
    // the moments button sit above it and keep their clicks.
    XCTAssertNil(hover.hitTest(CGPoint(x: 490, y: 20)))
  }

  /// …and the bar really installs one. The defect was the *absence* of a
  /// surface, so the test that catches it has to look at the laid-out bar.
  func testTheLaidOutBarCarriesThatHoverSurfaceAtItsFullWidth() {
    let host = barHost(width: 980)
    func find(_ view: NSView) -> SessionHoverView? {
      if let hit = view as? SessionHoverView { return hit }
      for sub in view.subviews {
        if let hit = find(sub) { return hit }
      }
      return nil
    }
    guard let surface = find(host) else {
      return XCTFail("the bar draws no hover surface, so most of it does not bloom")
    }
    XCTAssertEqual(surface.bounds.width, 980, accuracy: 1, "the surface is narrower than the bar")
    XCTAssertEqual(
      surface.bounds.height,
      RecordingPaneMetrics.barHeight(bloomed: false),
      accuracy: 1
    )
  }

  private static let mouseMoved: NSEvent = NSEvent.mouseEvent(
    with: .mouseMoved,
    location: .zero,
    modifierFlags: [],
    timestamp: 0,
    windowNumber: 0,
    context: nil,
    eventNumber: 0,
    clickCount: 0,
    pressure: 0
  )!

  // MARK: - The meter's feed

  /// The gate's whole job: a tap that delivers ~45 buffers a second may not
  /// produce 45 publishes a second on an object a window is observing.
  func testTheMeterPublishesNoFasterThanTheHudsOwnTick() {
    XCTAssertTrue(
      MeterPublishGate.shouldPublish(new: 0.5, last: 0, now: 1.0, lastPublishedAt: 0.9),
      "66 ms apart and half a meter of movement is a publish"
    )
    XCTAssertFalse(
      MeterPublishGate.shouldPublish(new: 0.5, last: 0, now: 1.0, lastPublishedAt: 0.98),
      "20 ms apart — a tap delivery — must not publish"
    )
    XCTAssertEqual(MeterPublishGate.minInterval, 0.066, accuracy: 0.0001)
  }

  /// A change nobody can see is a render spent on nothing.
  func testAMovementTooSmallToSeeDoesNotPublish() {
    XCTAssertFalse(
      MeterPublishGate.shouldPublish(new: 0.505, last: 0.5, now: 1.0, lastPublishedAt: 0.9),
      "a sub-threshold move published"
    )
    XCTAssertFalse(
      MeterPublishGate.shouldPublish(new: 0.5, last: 0.5, now: 1.0, lastPublishedAt: 0.0),
      "an identical level published even past maxHold"
    )
    XCTAssertTrue(
      MeterPublishGate.shouldPublish(new: 0.6, last: 0.5, now: 1.0, lastPublishedAt: 0.9),
      "a visible move at the tick did not publish"
    )
  }

  /// The escape the movement gate needs: a level decaying toward silence in
  /// steps below the threshold must still converge, or the meter holds at the
  /// last loud reading over a quiet room — the exact lie it exists to prevent.
  func testASlowDecayStillLandsRatherThanFreezingTheMeter() {
    XCTAssertFalse(
      MeterPublishGate.shouldPublish(new: 0.49, last: 0.5, now: 1.0, lastPublishedAt: 0.9),
      "a sub-threshold step this soon is not worth a render"
    )
    XCTAssertTrue(
      MeterPublishGate.shouldPublish(new: 0.49, last: 0.5, now: 1.5, lastPublishedAt: 0.9),
      "after maxHold any difference publishes, or a slow decay wedges the meter"
    )
  }

  func testTheFeedHoldsItsLevelUntilTheGateOpens() {
    let feed = MicLevelFeed()
    feed.publish(0.8, now: 100)
    XCTAssertEqual(feed.level, 0.8, accuracy: 0.0001)
    feed.publish(0.2, now: 100.01)
    XCTAssertEqual(feed.level, 0.8, accuracy: 0.0001, "a 10 ms-later buffer moved the meter")
    feed.publish(0.2, now: 100.1)
    XCTAssertEqual(feed.level, 0.2, accuracy: 0.0001)
  }

  /// Silence is the one level change that may not wait for a tick.
  func testSilenceIsImmediateAndUngated() {
    let feed = MicLevelFeed()
    feed.publish(0.9, now: 100)
    feed.silence(now: 100.001)
    XCTAssertEqual(feed.level, 0, "capture ended and the meter kept the room's last shout")
  }

  /// The meter answers the microphone **only while the audio is being kept**.
  /// On the AssemblyAI path `stop()` sits in `.stopping` for up to the 5 s
  /// watchdog with the tap still installed, while `handlePCMBuffer` drops every
  /// buffer — so an owner who kept talking watched the meter agree with them
  /// about words that reached neither the file nor the socket.
  func testTheMeterFollowsTheMicrophoneOnlyWhileTheAudioIsKept() {
    XCTAssertTrue(LiveMeetingSession.meterFollowsMicrophone(.recording))
    XCTAssertFalse(LiveMeetingSession.meterFollowsMicrophone(.stopping))
    XCTAssertFalse(LiveMeetingSession.meterFollowsMicrophone(.idle))
    XCTAssertFalse(LiveMeetingSession.meterFollowsMicrophone(.failed("dropped")))
  }

  // MARK: - The transcript is a flat list of rows

  /// The laziness invariant: **one row per line**, always. `LazyVStack` defers
  /// only its direct children, so a nested block would make the whole session
  /// one child — which is what it was, since every line's speaker is nil today.
  func testEveryLineIsItsOwnRow() {
    let lines = (0..<50).map {
      LiveTranscriptLine(id: UUID(), text: "line \($0)", endTime: TimeInterval($0), speaker: nil)
    }
    let rows = LiveTranscript.rows(LiveTranscript.blocks(lines))
    XCTAssertEqual(LiveTranscript.blocks(lines).count, 1, "with no labels the session is one block…")
    XCTAssertEqual(rows.count, 50, "…and 50 rows, or the stack has one child again")
    XCTAssertEqual(
      rows.map(\.id),
      lines.map { LiveTranscriptRow.ID.line($0.id) },
      "rows are the lines, in order, each under its own id"
    )
  }

  /// Grouping survives the flattening: the speaker name a block used to draw
  /// above its lines is a row of its own, emitted where the speaker changes.
  func testASpeakerHeaderIsARowEmittedWhereTheSpeakerChanges() {
    let a1 = LiveTranscriptLine(id: UUID(), text: "one", endTime: 3, speaker: "Amara")
    let a2 = LiveTranscriptLine(id: UUID(), text: "two", endTime: 7, speaker: "Amara")
    let k1 = LiveTranscriptLine(id: UUID(), text: "three", endTime: 11, speaker: "Kenny")
    let rows = LiveTranscript.rows(LiveTranscript.blocks([a1, a2, k1]))

    XCTAssertEqual(rows.count, 5, "two headers and three lines")
    XCTAssertEqual(rows[0].content, .speaker("Amara"))
    XCTAssertEqual(rows[1].content, .line(a1))
    XCTAssertEqual(rows[2].content, .line(a2))
    XCTAssertEqual(rows[3].content, .speaker("Kenny"))
    XCTAssertEqual(rows[4].content, .line(k1))

    // A speaker header and its turn's first line share a block id, so the row
    // ids have to be typed or the `ForEach` would collide on them.
    XCTAssertEqual(rows[0].id, .speaker(a1.id))
    XCTAssertEqual(rows[1].id, .line(a1.id))
    XCTAssertNotEqual(rows[0].id, rows[1].id)
  }

  /// The gutter belongs to whichever row opens a turn, and to nothing else —
  /// a continuation reserves the cell and leaves it blank.
  func testOnlyTheRowThatOpensATurnCarriesTheGutterTimestamp() {
    let rows = LiveTranscript.rows(
      LiveTranscript.blocks(LiveTranscript.lines(
        segments: [segment("one", at: 3), segment("two", at: 7)],
        partial: "still saying",
        elapsed: 9
      ))
    )
    XCTAssertEqual(rows.map(\.gutter), [3, nil, nil])
    XCTAssertEqual(rows.map(\.startsTurn), [true, false, false])
  }

  func testASilentSessionHasNoRowsAtAll() {
    XCTAssertTrue(
      LiveTranscript.rows(
        LiveTranscript.blocks(LiveTranscript.lines(segments: [], partial: nil, elapsed: 0))
      ).isEmpty
    )
  }

  // MARK: - The row model is not rebuilt by a render it did not cause

  /// `rows` maps every segment of the session, so a re-render the transcript
  /// did not cause may not pay for it. The cache is asserted to be a cache: the
  /// second identical call recomputes nothing.
  func testTheRowModelIsRebuiltOnlyWhenTheTranscriptChanges() {
    let cache = LiveTranscriptRowCache()
    let segments = [segment("one", at: 3), segment("two", at: 7)]

    _ = cache.rows(segments: segments, partial: nil, elapsed: 7)
    XCTAssertEqual(cache.recomputeCount, 1)

    // The same transcript, ten more renders (a meter tick, a toolbar change).
    for _ in 0..<10 {
      _ = cache.rows(segments: segments, partial: nil, elapsed: 7)
    }
    XCTAssertEqual(cache.recomputeCount, 1, "an unchanged transcript was rebuilt")

    // …and a real change still lands.
    _ = cache.rows(segments: segments, partial: "and", elapsed: 7)
    XCTAssertEqual(cache.recomputeCount, 2)
    _ = cache.rows(segments: segments + [segment("three", at: 11)], partial: "and", elapsed: 11)
    XCTAssertEqual(cache.recomputeCount, 3)
  }

  /// The cached rows are the rows, not a stale echo of them.
  func testTheCacheReturnsWhatAFreshComputationWouldHave() {
    let cache = LiveTranscriptRowCache()
    let segments = [segment("one", at: 3)]
    _ = cache.rows(segments: segments, partial: nil, elapsed: 3)
    let cached = cache.rows(segments: segments, partial: "tail", elapsed: 5)
    let fresh = LiveTranscript.rows(
      LiveTranscript.blocks(LiveTranscript.lines(segments: segments, partial: "tail", elapsed: 5))
    )
    XCTAssertEqual(cached, fresh)
  }

  // MARK: - The ember is only ever the open microphone

  /// The idle pane draws **no ember**. It is the state every owner sees before
  /// every recording, so it is the state that teaches them what the colour
  /// means — and `CraftTokens.ember(_:)` means exactly one thing, that the
  /// microphone is open. Rendered and scanned rather than asserted about a
  /// constant, because "there is no ember on screen" is a claim about pixels.
  func testTheIdlePaneDrawsNoEmber() {
    let idle = LiveMeetingView(session: LiveMeetingSession(), onStart: {}, onStop: {})
    guard
      let bitmap = RenderProbe.bitmap(
        idle.environment(\.colorScheme, .light),
        size: CGSize(width: 600, height: 420)
      )
    else { return XCTFail("the hosting view produced no bitmap") }

    XCTAssertEqual(
      RenderProbe.emberPixels(bitmap, scheme: .light),
      0,
      "the idle pane is drawing the recording accent over a closed microphone"
    )
  }

  /// …and the probe can see ember when there is ember, or the test above would
  /// pass against a blank canvas.
  func testTheProbeSeesTheEmberItIsLookingFor() {
    guard
      let bitmap = RenderProbe.bitmap(
        ZStack {
          Color.white
          SessionRing(diameter: 80, lineWidth: 6)
        }
        .environment(\.colorScheme, .light),
        size: CGSize(width: 200, height: 200)
      )
    else { return XCTFail("the hosting view produced no bitmap") }
    XCTAssertGreaterThan(RenderProbe.emberPixels(bitmap, scheme: .light), 0)
  }
}

// MARK: - Rendering probe

/// Renders a view into a bitmap so a claim about **pixels** can be asserted.
///
/// Two of this suite's claims are of that kind and neither could be made about
/// a constant: "the idle pane draws no ember" and "Stop is drawn identically
/// with and without Reduce Transparency".
@MainActor
enum RenderProbe {
  static func bitmap<V: View>(_ view: V, size: CGSize) -> NSBitmapImageRep? {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = CGRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep
  }

  /// How many sampled pixels are the recording accent.
  ///
  /// Matched on **hue and saturation**, not on RGB distance: the ring strokes
  /// at 55–90% opacity, so an ember pixel over a light ground is a long way
  /// from `#d1662a` in RGB while being unmistakably the same colour. The
  /// saturation floor is what keeps the ring's 10% interior wash — a glow, not
  /// a fill — and ordinary near-neutral chrome out of the count.
  static func emberPixels(_ rep: NSBitmapImageRep, scheme: ColorScheme) -> Int {
    guard let target = NSColor(CraftTokens.ember(scheme)).usingColorSpace(.sRGB) else { return 0 }
    let targetHue = target.hueComponent
    var count = 0
    for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
      for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
        guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        guard pixel.alphaComponent > 0.5, pixel.saturationComponent > 0.15 else { continue }
        let dh = abs(pixel.hueComponent - targetHue)
        if min(dh, 1 - dh) < 0.04 { count += 1 }
      }
    }
    return count
  }

  /// The colour at one point, in the bitmap's own pixel space (which is the
  /// backing scale times the point, on a Retina host).
  static func color(_ rep: NSBitmapImageRep, at point: CGPoint) -> NSColor? {
    let scaleX = CGFloat(rep.pixelsWide) / max(rep.size.width, 1)
    let scaleY = CGFloat(rep.pixelsHigh) / max(rep.size.height, 1)
    let x = min(max(Int(point.x * scaleX), 0), rep.pixelsWide - 1)
    let y = min(max(Int(point.y * scaleY), 0), rep.pixelsHigh - 1)
    return rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
  }

  static func matches(_ a: NSColor?, _ b: NSColor?, tolerance: CGFloat) -> Bool {
    guard
      let a = a?.usingColorSpace(.sRGB),
      let b = b?.usingColorSpace(.sRGB)
    else { return false }
    return abs(a.redComponent - b.redComponent) <= tolerance
      && abs(a.greenComponent - b.greenComponent) <= tolerance
      && abs(a.blueComponent - b.blueComponent) <= tolerance
  }
}
