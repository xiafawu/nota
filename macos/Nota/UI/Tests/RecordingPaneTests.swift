import AppKit
import SwiftUI
import XCTest

@testable import Nota

/// The recording surface's promises, asserted against the pure decisions the
/// views read — the split `SessionTimerMetrics` and `HUDPrompterMetrics`
/// already established. The hosting-view cases are here because "every capsule
/// draws the one height the cluster reserved" is a claim about layout, and only
/// a layout can answer it.
@MainActor
final class RecordingPaneTests: XCTestCase {
  // MARK: - One cluster, three capsules, one height

  /// The height every capsule takes is **derived from what a capsule holds**,
  /// not typed beside it. This is the check XIA-444 owed and did not have:
  /// `controlRowHeight` was written as 40 against a row that laid out at 41, so
  /// the bar reserved 64 and drew 65 with every geometry test in this file
  /// green through it.
  func testTheCapsuleHeightIsDerivedFromTheTallestThingACapsuleHolds() {
    let icon = ("0" as NSString)
      .size(withAttributes: [.font: RecordingPaneMetrics.actionMeasuringFont])
      .height
    XCTAssertEqual(
      RecordingPaneMetrics.capsuleContentHeight,
      max(
        SessionTimerMetrics.plateHeight(base: RecordingPaneMetrics.clockBase),
        RecordingPaneMetrics.meterVariant.maxBarHeight,
        icon.rounded(.up)
      )
    )
    XCTAssertEqual(
      RecordingPaneMetrics.capsuleHeight,
      RecordingPaneMetrics.capsuleContentHeight + 2 * RecordingPaneMetrics.capsulePaddingV
    )
    // And it is the **clock** that sets it: the compact meter and a 15pt glyph
    // are both shorter than a 30pt line box, which is what makes the row read
    // as a clock with two buttons beside it rather than a button row with a
    // clock in it.
    XCTAssertEqual(
      RecordingPaneMetrics.capsuleContentHeight,
      SessionTimerMetrics.plateHeight(base: RecordingPaneMetrics.clockBase),
      "something other than the clock is now the tallest thing in a capsule"
    )
  }

  /// …and each of the three **draws** exactly that. The reservation is worth
  /// only what the laid-out view agrees with, which is the shape of
  /// `testTheRestingBarDrawsExactlyTheHeightItReserves` before it.
  func testEveryCapsuleDrawsExactlyTheHeightTheClusterReserves() {
    for (name, height) in Self.capsuleHeights() {
      XCTAssertGreaterThan(height, 0, "\(name) produced no layout")
      XCTAssertEqual(
        height,
        RecordingPaneMetrics.capsuleHeight,
        accuracy: 0.5,
        "\(name) draws \(height)pt against a reservation of "
          + "\(RecordingPaneMetrics.capsuleHeight)pt"
      )
    }
  }

  /// **One height for all four**, which is what makes the row one object made
  /// of parts rather than four things that happen to be near each other.
  /// Asserted separately from the reservation, because four capsules could
  /// each agree with the same wrong constant.
  func testTheFourCapsulesAreTheSameHeightAsEachOther() {
    let heights = Self.capsuleHeights().map(\.1)
    XCTAssertEqual(heights.count, 4)
    for height in heights {
      XCTAssertEqual(height, heights[0], accuracy: 0.5, "the capsules measure \(heights)")
    }
  }

  /// Each capsule, laid out: the timer, Mark, Pause and Stop. The pause face is
  /// measured in its *resume* form deliberately — `play.fill` and `pause.fill`
  /// are drawn at the same size by the same style, and taking the one the row
  /// only wears in the state the tests otherwise never render is what would
  /// catch a face that had been given its own frame.
  private static func capsuleHeights() -> [(String, CGFloat)] {
    func laidOut<V: View>(_ view: V) -> CGFloat {
      let host = NSHostingView(rootView: view)
      host.layoutSubtreeIfNeeded()
      return host.fittingSize.height
    }
    return [
      (
        "the timer capsule",
        laidOut(SessionTimerCapsule(elapsed: 754, level: MicLevelFeed(level: 0.4)))
      ),
      (
        "the Mark capsule",
        laidOut(
          Button(action: {}) { Image(systemName: "bookmark.fill") }
            .buttonStyle(RecordingCapsuleButtonStyle(tint: CraftTokens.primaryBlue))
        )
      ),
      (
        "the Pause capsule",
        laidOut(
          Button(action: {}) { Image(systemName: "play.fill") }
            .buttonStyle(RecordingCapsuleButtonStyle(tint: CraftTokens.primaryBlue))
        )
      ),
      (
        "the Stop capsule",
        laidOut(
          Button(action: {}) { Image(systemName: "stop.fill") }
            .buttonStyle(RecordingCapsuleButtonStyle(tint: CraftTokens.stopRed))
        )
      ),
    ]
  }

  // MARK: - The timer steps at the hour without reflowing

  /// The acceptance case, restated at the cluster's one base size and against
  /// `SessionTimerMetrics` rather than a second derivation of it: 30 → 22, and
  /// the clock the capsule **draws** keeps one width across the step.
  func testTheTimerStepsAtTheHourAndTheDrawnClockKeepsItsWidth() {
    let base = RecordingPaneMetrics.clockBase
    XCTAssertEqual(SessionTimerMetrics.fontSize(base: base, elapsed: 3599), 30)
    XCTAssertEqual(SessionTimerMetrics.fontSize(base: base, elapsed: 3600), 22)

    func drawnWidth(_ elapsed: TimeInterval) -> CGFloat {
      let host = NSHostingView(rootView: SessionTimer(elapsed: elapsed, base: base))
      host.layoutSubtreeIfNeeded()
      return host.fittingSize.width
    }

    let elapsed: [TimeInterval] = [0, 3599, 3600, 36_000, 86_399]
    let widths = elapsed.map(drawnWidth)
    XCTAssertGreaterThan(widths[0], 0, "the hosting view produced no layout")
    for (at, width) in zip(elapsed, widths) {
      XCTAssertEqual(
        width,
        widths[0],
        accuracy: 0.5,
        "the drawn clock changed width at \(at) — the plate is not reserved"
      )
    }
    // …and the text really did change across those values, or "one width"
    // would be a fact about a string that never moved.
    XCTAssertNotEqual(
      SessionTimerMetrics.text(elapsed: 3599),
      SessionTimerMetrics.text(elapsed: 3600)
    )
  }

  /// The plate reserves a **line box**, not the ink, which is what a capsule
  /// that has to contain the digits needs — and it is the number the capsule's
  /// height is derived from.
  func testThePlateReservesALineBoxTallerThanTheGlyphsAndDoesNotDependOnElapsed() {
    let base = RecordingPaneMetrics.clockBase
    XCTAssertGreaterThan(SessionTimerMetrics.plateHeight(base: base), base * 0.75)
    // The widest form wins the reservation, so the step at the hour cannot ask
    // for a taller row than the one already reserved.
    XCTAssertGreaterThanOrEqual(
      SessionTimerMetrics.plateHeight(base: base),
      SessionTimerMetrics.plateHeight(base: SessionTimerMetrics.fontSize(base: base, elapsed: 3600))
    )
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
      XCTAssertEqual(size.width, sizes[0].width, accuracy: 0.5, "the plate is not reserved")
    }
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

  /// Restated at the pane level: the ring is the one that stops, and the meter
  /// is the one that never does. This is the asymmetry `RecordingMotion` owns;
  /// the pane may not reintroduce a second opinion about it. It outlived both
  /// the surfaces that drew a ring (the column's, then the bar's dot) because
  /// it is about what a live microphone is allowed to look like, not about the
  /// shape drawn around it.
  func testTheRingStopsBreathingAndTheMeterKeepsMoving() {
    XCTAssertNil(RecordingMotion.ringAnimation(reduceMotion: true))
    XCTAssertNotNil(RecordingMotion.meterAnimation(reduceMotion: true))
    XCTAssertFalse(SessionRingMetrics.breathes(reduceMotion: true))
  }

  /// **Stop's red is drawn over the glass, not through it**, and that is what
  /// makes it survive Reduce Transparency — the one setting that can take a
  /// material away. A `Glass.tint(_:)` is a property of the effect and goes with
  /// it when `liquidGlass` degrades to `.regularMaterial`; a background fill on
  /// the same capsule does not. Stop is the one control that may never be hard
  /// to find.
  ///
  /// `accessibilityReduceTransparency` is a read-only environment value and
  /// cannot be driven from a test. What *can* be driven is the property the
  /// setting is about: a material takes its appearance from what is behind it,
  /// so Stop is rendered over two opposite backdrops and its colour looked for
  /// in both.
  ///
  /// This is the honest successor to the bar's
  /// `testStopIsAFillAndNotAMaterialThatTheBackdropCanChange`, and one half of
  /// that test is deliberately **not** carried over: the bar's Stop was an
  /// opaque ember fill, so the two readings could be asserted *equal*. This one
  /// is 62% over glass — the owner's number, and the whole reason the capsule
  /// refracts at all — so it does vary with the ground. What it may not do is
  /// stop being red.
  ///
  /// The Mark capsule is the control. If the probe could not tell red from
  /// something else, the first half would pass for the wrong reason.
  func testStopStaysItsOwnRedOverAnyBackdrop() {
    let size = CGSize(width: 200, height: 90)

    func capsule(_ tint: Color, over backdrop: Color) -> NSBitmapImageRep? {
      RenderProbe.bitmap(
        ZStack {
          backdrop
          Button(action: {}) { Image(systemName: "stop.fill") }
            .buttonStyle(RecordingCapsuleButtonStyle(tint: tint))
        }
        .environment(\.colorScheme, .light),
        size: size
      )
    }

    /// Pixels where red clearly leads both other channels — i.e. the tint, at
    /// whatever the glass under it did to the value.
    func redPixels(_ rep: NSBitmapImageRep?) -> Int {
      guard let rep else { return 0 }
      var count = 0
      for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
          guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
          guard pixel.alphaComponent > 0.5 else { continue }
          if pixel.redComponent > pixel.greenComponent + 0.25,
             pixel.redComponent > pixel.blueComponent + 0.25 {
            count += 1
          }
        }
      }
      return count
    }

    for backdrop in [Color.white, Color.black] {
      XCTAssertGreaterThan(
        redPixels(capsule(CraftTokens.stopRed, over: backdrop)),
        0,
        "Stop drew no red over \(backdrop) — the backdrop washed the tint away"
      )
      XCTAssertEqual(
        redPixels(capsule(CraftTokens.primaryBlue, over: backdrop)),
        0,
        "the blue capsule read as red over \(backdrop), so this probe proves nothing"
      )
    }

    // The tint's strength is the owner's number and lives in one place, so both
    // action capsules are coloured the same amount.
    XCTAssertEqual(RecordingCapsuleTint.strength, 0.62, accuracy: 0.0001)
  }

  /// **Liquid Glass carries its own rim, so `craftGlassPanel` draws one only
  /// where the material has none** (P-A6).
  ///
  /// Nine main-window surfaces go through that modifier — the history drawer,
  /// the Details panel, the home cards, the failed-session banner, the receipt
  /// and every capsule of the recording cluster — and each of them painted
  /// `CraftTokens.hairline` over a plate that already has a rim. That is the
  /// doubled outline the toolbar pills and the three floating panels each
  /// deleted (CLAUDE.md, Key Design Decisions: "the neutral fill and the
  /// hairline go, because the plate has its own rim"). The Reduce Transparency
  /// branch swaps the effect for `.regularMaterial`, which has no rim of its
  /// own, so the stroke stays exactly there — and the shadow stays on both,
  /// being a `CraftTokens` constant rather than a property of the glass.
  ///
  /// The half that has to be **measured** is that this is chrome and not
  /// geometry — otherwise `capsuleHeight`, the four-capsule row width and the
  /// `transcriptBottomReserve` composed from them would all mean something
  /// different under one accessibility setting than under the other.
  ///
  /// `\.accessibilityReduceTransparency` is a **read-only** environment value,
  /// so the two branches cannot be driven from a test. What can be measured is
  /// the mechanism the whole rule rests on: the hairline is an `.overlay` of
  /// exactly `CraftTokens.hairline` at `panelHairlineWidth` on the panel's own
  /// shape, and adding one to each real cluster surface moves not a point. A
  /// stroke that costs nothing to add costs nothing to remove.
  func testTheRimIsChromeAndOnlyTheDegradedMaterialDrawsIt() {
    XCTAssertFalse(
      CraftGlassPanel.drawsHairline(reduceTransparency: false),
      "glass carries its own rim; a second stroke on it is the doubled outline"
    )
    XCTAssertTrue(
      CraftGlassPanel.drawsHairline(reduceTransparency: true),
      "`.regularMaterial` has no rim of its own — the degraded panel keeps the hairline"
    )

    func laidOut<V: View>(_ view: V) -> CGSize {
      let host = NSHostingView(rootView: view)
      host.layoutSubtreeIfNeeded()
      return host.fittingSize
    }
    func rimmed<V: View>(_ view: V) -> some View {
      view.overlay(
        Capsule(style: .continuous)
          .stroke(CraftTokens.hairline, lineWidth: CraftTokens.panelHairlineWidth)
      )
    }

    let cluster = SessionCapsuleCluster(
      elapsed: 61,
      level: MicLevelFeed(level: 0.4),
      controls: .stop,
      markers: [],
      onMark: {},
      onStop: {}
    )
    let surfaces: [(String, AnyView)] = [
      (
        "the timer capsule",
        AnyView(SessionTimerCapsule(elapsed: 61, level: MicLevelFeed(level: 0.4)))
      ),
      ("Mark", AnyView(cluster.capsule(.mark))),
      ("Stop", AnyView(cluster.capsule(.stop))),
      ("the whole cluster", AnyView(cluster)),
    ]
    for (name, view) in surfaces {
      let bare = laidOut(view)
      let stroked = laidOut(rimmed(view))
      XCTAssertGreaterThan(bare.width, 0, "\(name) produced no layout")
      XCTAssertEqual(
        stroked.width, bare.width, accuracy: 0.01,
        "\(name) changed width by \(stroked.width - bare.width)pt — the rim is geometry, not chrome"
      )
      XCTAssertEqual(
        stroked.height, bare.height, accuracy: 0.01,
        "\(name) changed height by \(stroked.height - bare.height)pt — the rim is geometry, not chrome"
      )
    }
  }

  /// Nothing the pane lays out with can move under an accessibility setting:
  /// every number is a constant or is measured once from a font, and neither
  /// kind reads an `@Environment` value. The cluster has exactly **one** size —
  /// the bar's hover bloom is gone with the bar — so there is not even a
  /// transition left for Reduce Motion to reach.
  func testNoPaneGeometryMovesUnderAnAccessibilitySetting() {
    XCTAssertEqual(RecordingPaneMetrics.gutterWidth, 52)
    XCTAssertEqual(RecordingPaneMetrics.clockBase, 30)
    // 43: the 30pt clock's 35pt line box plus 4 above and below. Measured from
    // the font rather than typed there, so this pins the *answer* while
    // `testEveryCapsuleDrawsExactlyTheHeightTheClusterReserves` pins that the
    // answer is the one the capsules draw. The bar's version of this pair read
    // 64 while the bar drew 65, which is how a whole file of geometry tests
    // stayed green against a reservation that never bound.
    XCTAssertEqual(RecordingPaneMetrics.capsuleHeight, 43)
    // 83 = 43 + 24 + 16. The gap went to 31 while "Paused" was a badge floating
    // above the row — an overlay is outside the reserve, so a 16pt gap put the
    // word on the last lines of the live transcript. The word is on the Pause
    // capsule now (owner, 2026-08-12), nothing is drawn above the row, and the
    // transcript gets those 15 points back.
    XCTAssertEqual(RecordingPaneMetrics.clusterTranscriptGap, CraftTokens.spacing16)
    XCTAssertEqual(RecordingPaneMetrics.transcriptBottomReserve, 83)

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

  /// Mark shows a **count**, and an empty log shows the flag alone rather than
  /// a tally of nothing. The words are `SessionMarkerList`'s and the surface
  /// draws none of them since the Moments capsule went — they are asserted here
  /// because that view is XIA-433's and still has to say something sensible.
  func testAnEmptyLogShowsNoCountAndTheListStillHasItsWords() {
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

  // MARK: - The ember margin rule (XIA-433)

  private func line(_ text: String, endingAt end: TimeInterval, speaker: String? = nil) -> LiveTranscriptLine {
    LiveTranscriptLine(id: UUID(), text: text, endTime: end, speaker: speaker)
  }

  /// **A moment is a timestamp, not an annotation on text.** Pressing ⌘K
  /// before a single word has been recognized has to land — it is the case a
  /// rule written as "attach the mark to a line" fails on, and it is a common
  /// one (the owner flags the thing that was *just* said, before the recognizer
  /// has caught up). Nothing may throw the mark away for want of a line to
  /// hang it on: it is in the log, it goes to disk (see
  /// `LiveSessionPersistenceTests`), and it simply has no rule to draw yet.
  func testAMarkerPressedBeforeAnySpeechIsStillKept() {
    let log = SessionMarkerLog()
    log.mark(at: 4)
    XCTAssertEqual(log.markers.count, 1)
    XCTAssertEqual(log.markers.first?.at, 4)

    XCTAssertTrue(
      LiveTranscriptMarking.markedLineIDs(markers: log.markers, lines: []).isEmpty,
      "a transcript with no lines produced a marked line id"
    )

    let cache = LiveTranscriptRowCache()
    let rows = cache.rows(segments: [], partial: nil, elapsed: 4, markers: log.markers)
    XCTAssertTrue(rows.isEmpty, "a mark before any speech invented a transcript row")
  }

  // MARK: - The press itself

  /// **⌘K writes the record, and it writes the whole log.** This is the
  /// ticket's headline claim and it lives in `SessionMarkPress` rather than in
  /// `LiveMeetingView.mark()` for exactly this reason: a view method is
  /// unreachable from this bundle, and a claim nothing can drive is a claim
  /// nobody is keeping.
  func testEveryPressHandsTheWholeLogToTheRecordWriter() {
    let log = SessionMarkerLog()
    var writes: [[TimeInterval]] = []

    XCTAssertTrue(
      SessionMarkPress.press(log: log, at: 12) { markers in
        writes.append(markers.map(\.at))
        return true
      }
    )
    XCTAssertTrue(
      SessionMarkPress.press(log: log, at: 44) { markers in
        writes.append(markers.map(\.at))
        return true
      }
    )

    XCTAssertEqual(writes.count, 2, "a press did not reach the record at all")
    XCTAssertEqual(writes[0], [12])
    XCTAssertEqual(
      writes[1], [44, 12],
      "the second press wrote its own moment instead of the session's list"
    )
    XCTAssertEqual(log.markers.count, 2)
  }

  /// **A write that did not land is not reported as success**, and the moment
  /// is not thrown away either. It stays in the log, and because every press
  /// rewrites the whole array the next press that lands carries it — one
  /// unwritable moment costs a warning, never a moment the owner cannot
  /// recreate.
  func testAFailedWriteIsReportedAndTheMomentIsCarriedToTheNextPress() {
    let log = SessionMarkerLog()

    XCTAssertFalse(
      SessionMarkPress.press(log: log, at: 12) { _ in false },
      "an unwritable record was reported as a flagged moment"
    )
    XCTAssertEqual(log.markers.count, 1, "the press vanished from the session as well")

    var landed: [TimeInterval] = []
    XCTAssertTrue(
      SessionMarkPress.press(log: log, at: 44) { markers in
        landed = markers.map(\.at)
        return true
      }
    )
    XCTAssertEqual(
      landed, [44, 12],
      "the press that landed did not carry the moment the failed one held"
    )
  }

  /// A press stamps the wall clock **once**, at the press, and the log keeps
  /// what it stamped. `createdAt` is a stored property for this reason: every
  /// later press rewrites the whole array, and a marker rewritten must not
  /// change its own history.
  func testAPressStampsItsOwnWallClockAndNoLaterPressRestampsIt() {
    let log = SessionMarkerLog()
    let first = Date(timeIntervalSince1970: 1_700_000_000)
    let second = first.addingTimeInterval(32)

    log.mark(at: 12, createdAt: first)
    log.mark(at: 44, createdAt: second)

    XCTAssertEqual(log.markers.map(\.createdAt), [second, first])
  }

  /// A non-finite elapsed is clamped on the way in. `max(0, x)` answers 0 for
  /// NaN and **not** for `+infinity`, and an infinity is not one bad marker: the
  /// whole array is written on every press, `JSONSerialization` refuses a
  /// non-finite Double, so one would veto every moment of the session —
  /// including the ones already safely on disk — for the rest of the session.
  func testATimeThatIsNotATimeCannotPoisonTheSessionsMoments() {
    let log = SessionMarkerLog()
    log.mark(at: .infinity)
    log.mark(at: .nan)
    log.mark(at: -5)

    XCTAssertEqual(log.markers.map(\.at), [0, 0, 0])
    XCTAssertTrue(
      JSONSerialization.isValidJSONObject(
        ["markers": LiveSessionPersistence.markerDictionaries(log.markers)]
      )
    )
    // And the backstop, for a marker that did not come through the log at all.
    let raw = LiveSessionPersistence.markerDictionaries([
      SessionMarker(at: 9),
      SessionMarker(at: .infinity)
    ])
    XCTAssertEqual(raw.count, 1, "a time that cannot be encoded reached the record")
    XCTAssertTrue(JSONSerialization.isValidJSONObject(["markers": raw]))
  }

  /// The matching rule, stated as the claim: a mark belongs to **the turn that
  /// was in flight when it was pressed** — the first line whose `endTime` has
  /// not yet passed it. A `LiveSegment` carries only an end time, so that
  /// predicate is `start <= t < end` with each start derived as the previous
  /// end, which is the same idiom `segmentDictionaries` and `buildMarkdown`
  /// already use.
  func testAMarkerRulesTheLineThatWasInFlightWhenItWasPressed() {
    let lines = [
      line("first", endingAt: 5),
      line("second", endingAt: 12),
      line("third", endingAt: 20)
    ]
    // 8 falls inside the second turn (5…12), not the one that had already ended.
    let marked = LiveTranscriptMarking.markedLineIDs(
      markers: [SessionMarker(at: 8)],
      lines: lines
    )
    XCTAssertEqual(marked, [lines[1].id])

    // Exactly on a boundary, the turn that is closing owns it: `endTime >= t`.
    XCTAssertEqual(
      LiveTranscriptMarking.markedLineIDs(markers: [SessionMarker(at: 5)], lines: lines),
      [lines[0].id]
    )
    // And a mark at zero belongs to the first line, whatever it ends at —
    // there is no line before it for it to fall through to.
    XCTAssertEqual(
      LiveTranscriptMarking.markedLineIDs(markers: [SessionMarker(at: 0)], lines: lines),
      [lines[0].id]
    )
  }

  /// **A rule that has been drawn never moves.** A mark past every line — the
  /// owner flagging something during silence — waits for the line it belongs
  /// to rather than attaching to the last one and then jumping forward when the
  /// next turn arrives. The alternative ("nearest line") relocates a rule under
  /// the owner's eyes, which is worse than a rule that arrives with its words.
  func testAMarkerPastEveryLineWaitsForTheLineItBelongsTo() {
    let earlier = [line("first", endingAt: 5), line("second", endingAt: 12)]
    XCTAssertTrue(
      LiveTranscriptMarking.markedLineIDs(markers: [SessionMarker(at: 30)], lines: earlier).isEmpty,
      "a mark during silence was attached to a turn that had already ended"
    )

    let later = earlier + [line("third", endingAt: 34)]
    XCTAssertEqual(
      LiveTranscriptMarking.markedLineIDs(markers: [SessionMarker(at: 30)], lines: later),
      [later[2].id],
      "the line that finally covered the mark did not take it"
    )
    // And the lines it passed over are still unmarked — the mark did not smear.
    XCTAssertFalse(
      LiveTranscriptMarking.markedLineIDs(markers: [SessionMarker(at: 30)], lines: later)
        .contains(later[1].id)
    )
  }

  /// The volatile tail has `endTime == elapsed`, so it covers every fresh mark;
  /// when it finalizes into a segment ending at about the same instant, the
  /// rule lands on the same words. That is the whole of why the rule is
  /// "first line whose end has not passed" and not something anchored to a
  /// line id: the id changes at finalization and the instant does not.
  func testAFreshMarkRidesTheVolatileTailAndStaysWhenItFinalizes() {
    let spoken = segment("already said", at: 9)
    let cache = LiveTranscriptRowCache()
    let markers = [SessionMarker(at: 14)]

    let live = cache.rows(segments: [spoken], partial: "still talking", elapsed: 14, markers: markers)
    XCTAssertEqual(
      live.filter(\.isMarked).map(\.id),
      [LiveTranscriptRow.ID.line(LiveTranscript.volatileLineID)],
      "a mark pressed mid-turn did not land on the in-flight line"
    )

    let finalized = segment("still talking", at: 14)
    let settled = cache.rows(segments: [spoken, finalized], partial: nil, elapsed: 15, markers: markers)
    XCTAssertEqual(
      settled.filter(\.isMarked).map(\.id),
      [LiveTranscriptRow.ID.line(finalized.id)],
      "the rule left the words it was drawn beside when the turn finalized"
    )
  }

  /// The rule belongs beside the **words**, never beside a name. A speaker
  /// header is a row like any other in a flat stack, so nothing structural
  /// stops it taking a mark — only `rows(_:markedLineIDs:)` matching on line
  /// ids does, and that is the assertion.
  func testTheMarkerRuleNeverLandsOnASpeakerHeader() {
    let lines = [
      line("hello", endingAt: 5, speaker: "Amara"),
      line("and then", endingAt: 12, speaker: "Bo")
    ]
    let marked = LiveTranscriptMarking.markedLineIDs(markers: [SessionMarker(at: 3)], lines: lines)
    let rows = LiveTranscript.rows(LiveTranscript.blocks(lines), markedLineIDs: marked)

    let headers = rows.filter {
      if case .speaker = $0.content { return true }
      return false
    }
    XCTAssertEqual(headers.count, 2, "the fixture stopped producing speaker headers")
    XCTAssertTrue(headers.allSatisfy { !$0.isMarked }, "a speaker header wore the ember rule")
    XCTAssertEqual(rows.filter(\.isMarked).count, 1)
  }

  /// **The mark is a flag on a flat row, not a wrapper around a run of them.**
  /// That is the property the laziness rests on: a `LazyVStack` defers only its
  /// direct children, so a container hung around the marked rows would collapse
  /// a whole session into one child (XIA-432).
  ///
  /// The row *count* cannot fail for that reason — `LiveTranscript.rows`
  /// appends one row per line whether it is marked or not — so what is asserted
  /// is the model marking cannot break: the drawn model is exactly one row per
  /// line plus one header per turn that has a speaker, the ids are byte for
  /// byte the unmarked ones, and marking changes nothing but the flag. What no
  /// test in this bundle can reach is `LiveTranscriptView`'s own hierarchy;
  /// that claim is carried by the `.overlay` in the row view and by this
  /// model's shape, not by an assertion.
  func testMarkingIsAFlagOnAFlatRowAndChangesNothingElse() {
    let lines = (0..<8).map { line("line \($0)", endingAt: TimeInterval($0 * 6 + 6)) }
    let blocks = LiveTranscript.blocks(lines)
    let plain = LiveTranscript.rows(blocks)
    let marked = LiveTranscript.rows(blocks, markedLineIDs: [lines[1].id, lines[6].id])

    let headers = plain.filter {
      if case .speaker = $0.content { return true }
      return false
    }
    XCTAssertEqual(
      plain.count,
      lines.count + headers.count,
      "the drawn model stopped being one row per line plus one header per named turn"
    )
    XCTAssertEqual(plain.map(\.id), marked.map(\.id))
    XCTAssertEqual(plain.map(\.gutter), marked.map(\.gutter))
    XCTAssertEqual(plain.map(\.startsTurn), marked.map(\.startsTurn))
    XCTAssertEqual(marked.filter(\.isMarked).count, 2)
    XCTAssertEqual(
      zip(plain, marked).filter { $0.0 != $0.1 }.count,
      2,
      "flagging two moments changed a row it does not belong to"
    )
  }

  /// The memo has to see a mark, or the rule would not be drawn until the next
  /// turn arrived — and it has to *stop* seeing one, or the flag would rebuild
  /// 400 line structs on every clock tick, which is the cost the cache exists
  /// to refuse.
  func testFlaggingAMomentRebuildsTheRowModelAndNothingElseDoes() {
    let cache = LiveTranscriptRowCache()
    let segments = [segment("one", at: 5), segment("two", at: 12)]

    _ = cache.rows(segments: segments, partial: nil, elapsed: 12, markers: [])
    XCTAssertEqual(cache.recomputeCount, 1)

    _ = cache.rows(segments: segments, partial: nil, elapsed: 12, markers: [])
    XCTAssertEqual(cache.recomputeCount, 1, "an unchanged transcript was rebuilt")

    let markers = [SessionMarker(at: 8)]
    let marked = cache.rows(segments: segments, partial: nil, elapsed: 12, markers: markers)
    XCTAssertEqual(cache.recomputeCount, 2, "a flagged moment did not reach the row model")
    XCTAssertEqual(marked.filter(\.isMarked).count, 1)

    _ = cache.rows(segments: segments, partial: nil, elapsed: 12, markers: markers)
    XCTAssertEqual(cache.recomputeCount, 2, "the same marker list rebuilt the model again")
  }

  /// The key is a **signature of every marker**, not a count, and each of these
  /// three changes is one a count cannot see. Two of them can happen today: a
  /// `reset()` and a fresh press across a session boundary (the row cache is a
  /// `@State` that outlives the session, the log is emptied), and a mark whose
  /// time differs. The third — a `label` written in place — is what the
  /// auto-title follow-up does, and a memo that could not see it would go on
  /// drawing rows built before the label existed.
  func testTheRowModelSeesEveryChangeToAMarkerAndNotOnlyTheirNumber() {
    let cache = LiveTranscriptRowCache()
    let segments = [segment("one", at: 5), segment("two", at: 12)]
    let early = [SessionMarker(at: 3)]

    let first = cache.rows(segments: segments, partial: nil, elapsed: 12, markers: early)
    XCTAssertEqual(cache.recomputeCount, 1)
    XCTAssertEqual(first.filter(\.isMarked).map(\.id), [.line(segments[0].id)])

    // Same count, different time — a different line entirely.
    let later = [SessionMarker(at: 9)]
    let second = cache.rows(segments: segments, partial: nil, elapsed: 12, markers: later)
    XCTAssertEqual(cache.recomputeCount, 2, "a marker that moved did not reach the row model")
    XCTAssertEqual(second.filter(\.isMarked).map(\.id), [.line(segments[1].id)])

    // Same count, same time, same id — only a label, written in place.
    var labelled = later[0]
    labelled.label = "the rollback"
    _ = cache.rows(segments: segments, partial: nil, elapsed: 12, markers: [labelled])
    XCTAssertEqual(cache.recomputeCount, 3, "a marker's label changed and the model did not")
  }

  /// **The rule is drawn inside the margin, and it moves no text.** Both halves
  /// are measured off the rendered pixels rather than argued from the fact that
  /// `.overlay` takes no layout.
  ///
  /// The text is measured as the leading edge of the **body text**, not as the
  /// leftmost ink anywhere in the bitmap: the leftmost ink is the gutter
  /// timestamp, ~24pt left of the words, so a `.padding(.leading, 8)` on the
  /// line branch would move every sentence on screen without moving it.
  ///
  /// And the ember is bounded on **both** sides against derived numbers. Left
  /// of the body text is not enough — the whole gutter is left of it, so a
  /// `markerRuleInset` typed to 0 would draw the rule inside the transcript's
  /// content column and still pass. The claim is that the rule sits in the
  /// margin `transcriptPaddingH` reserves and nowhere else, which is what makes
  /// the `transcriptPaddingH / 2` derivation load-bearing rather than
  /// decorative, plus that it is on screen at all.
  func testTheEmberRuleSitsInsideTheMarginAndMovesNoText() {
    let lines = [line("the migration lands next Tuesday", endingAt: 12)]
    let blocks = LiveTranscript.blocks(lines)
    let plain = LiveTranscript.rows(blocks)
    let marked = LiveTranscript.rows(blocks, markedLineIDs: [lines[0].id])
    XCTAssertTrue(marked[0].isMarked)

    guard
      let plainRep = Self.transcriptBitmap(plain),
      let markedRep = Self.transcriptBitmap(marked),
      let plainText = Self.leftmostBodyTextColumn(plainRep),
      let markedText = Self.leftmostBodyTextColumn(markedRep),
      let ember = Self.leftmostEmberColumn(markedRep)
    else {
      return XCTFail("the transcript did not render")
    }

    XCTAssertEqual(
      plainText,
      markedText,
      "flagging a moment moved the transcript's text (\(plainText) → \(markedText))"
    )
    XCTAssertEqual(
      Self.leftmostInkColumn(plainRep),
      Self.leftmostInkColumn(markedRep),
      "flagging a moment moved the gutter timestamp"
    )

    let scale = CGFloat(markedRep.pixelsWide) / Self.transcriptProbeSize.width
    let margin = RecordingPaneMetrics.transcriptPaddingH * scale
    let rule = RecordingPaneMetrics.markerRuleWidth * scale
    XCTAssertGreaterThanOrEqual(
      CGFloat(ember), 0, "the rule was drawn off the leading edge of the window"
    )
    XCTAssertLessThanOrEqual(
      CGFloat(ember) + rule,
      margin.rounded(.up),
      "the rule left the margin the transcript reserves and entered its content column"
    )
    XCTAssertNil(
      Self.leftmostEmberColumn(plainRep),
      "an unmarked transcript drew the ember, which means the microphone is open"
    )
  }

  /// **The ember is withheld from every state whose microphone is closed.** The
  /// failed banner draws the same `LiveTranscriptView` over the same transcript,
  /// and the session's marks are still in the log when it does — so without this
  /// decision a stopped session would carry ember down its margin beside a dead
  /// microphone, no meter and no clock: the lie `showsRecordingPane` withholds
  /// the cluster to avoid, and the one `testTheIdlePaneDrawsNoEmber` pins for
  /// idle. Nothing is lost by it; the moments are on the record.
  ///
  /// It used to be expressed as `showsRecordingPane`, and **XIA-447 split the
  /// two on purpose**: a paused session keeps the pane — taking it away is the
  /// "a paused session looks stopped" failure the whole ticket is about — while
  /// its microphone is closed, and the ember means the microphone is open. The
  /// rules come back with the microphone at Resume.
  func testOnlyALiveSessionsTranscriptWearsTheEmberRule() {
    let log = [SessionMarker(at: 8)]
    for controls in LiveMeetingControls.allCases {
      let drawn = LiveMeetingView.drawnMarkers(controls: controls, log: log)
      XCTAssertEqual(
        drawn.isEmpty,
        !controls.drawsMarkerRules,
        "\(controls) disagrees with itself about whether the microphone is open"
      )
    }
    XCTAssertTrue(LiveMeetingView.drawnMarkers(controls: .saveOrDiscard, log: log).isEmpty)
    XCTAssertTrue(LiveMeetingView.drawnMarkers(controls: .retryOrDiscard, log: log).isEmpty)
    XCTAssertEqual(LiveMeetingView.drawnMarkers(controls: .stop, log: log), log)

    // The split, stated: the pane stays and the ember goes.
    XCTAssertTrue(LiveMeetingControls.paused.showsRecordingPane)
    XCTAssertTrue(LiveMeetingView.drawnMarkers(controls: .paused, log: log).isEmpty)
  }

  /// And the pixels agree: the transcript a failed session shows carries no
  /// ember, drawn from the *same* rows the live one would have drawn had the
  /// markers reached it.
  func testAStoppedSessionsTranscriptDrawsNoEmber() {
    let lines = [line("we lost the socket mid-sentence", endingAt: 12)]
    let blocks = LiveTranscript.blocks(lines)
    let log = [SessionMarker(at: 6)]

    let stopped = LiveTranscript.rows(
      blocks,
      markedLineIDs: LiveTranscriptMarking.markedLineIDs(
        markers: LiveMeetingView.drawnMarkers(controls: .saveOrDiscard, log: log),
        lines: lines
      )
    )
    XCTAssertTrue(stopped.allSatisfy { !$0.isMarked })

    guard let rep = Self.transcriptBitmap(stopped) else {
      return XCTFail("the transcript did not render")
    }
    XCTAssertNil(
      Self.leftmostEmberColumn(rep),
      "a failed session's transcript drew the colour that means the microphone is open"
    )
  }

  private static let transcriptProbeSize = CGSize(width: 500, height: 160)

  private static func transcriptBitmap(_ rows: [LiveTranscriptRow]) -> NSBitmapImageRep? {
    RenderProbe.bitmap(
      ZStack {
        Color.white
        LiveTranscriptView(rows: rows, volatileID: nil)
      }
      .environment(\.colorScheme, .light),
      size: transcriptProbeSize
    )
  }

  /// Leftmost column of the **body text** — the ink at or right of where the
  /// gutter cell ends. The gutter timestamp is the leftmost ink in the whole
  /// bitmap and sits a whole cell away from the words, so measuring "the
  /// leftmost dark pixel" measures a column that does not move when the
  /// sentence does.
  private static func leftmostBodyTextColumn(_ rep: NSBitmapImageRep) -> Int? {
    let scale = CGFloat(rep.pixelsWide) / transcriptProbeSize.width
    let contentStart = Int(
      ((RecordingPaneMetrics.transcriptPaddingH + RecordingPaneMetrics.gutterWidth) * scale)
        .rounded(.up)
    )
    return leftmostColumn(rep, from: contentStart) { pixel in
      pixel.brightnessComponent < 0.65
    }
  }

  /// Leftmost column holding a dark, near-neutral pixel — the ink
  /// (`GroundInk.light` is `#1C1A16`, brightness 0.11) at any tier, over the
  /// white ground the probe paints.
  private static func leftmostInkColumn(_ rep: NSBitmapImageRep) -> Int? {
    Self.leftmostColumn(rep) { pixel in
      pixel.brightnessComponent < 0.65
    }
  }

  /// Leftmost column holding the ember. Matched on hue **and** a high
  /// saturation floor, which is what tells `#d1662a` (saturation 0.80,
  /// brightness 0.82) from the warm near-black ink (saturation 0.21,
  /// brightness 0.11) whose hue is only 0.05 of a turn away.
  private static func leftmostEmberColumn(_ rep: NSBitmapImageRep) -> Int? {
    guard let target = NSColor(CraftTokens.ember(.light)).usingColorSpace(.sRGB) else { return nil }
    let hue = target.hueComponent
    return Self.leftmostColumn(rep) { pixel in
      guard pixel.saturationComponent > 0.5, pixel.brightnessComponent > 0.5 else { return false }
      let delta = abs(pixel.hueComponent - hue)
      return min(delta, 1 - delta) < 0.04
    }
  }

  private static func leftmostColumn(
    _ rep: NSBitmapImageRep,
    from first: Int = 0,
    matching: (NSColor) -> Bool
  ) -> Int? {
    for x in max(0, first)..<rep.pixelsWide {
      for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
        guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        guard pixel.alphaComponent > 0.5 else { continue }
        if matching(pixel) { return x }
      }
    }
    return nil
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

  private func clusterHost(
    elapsed: TimeInterval = 61,
    markers: [SessionMarker] = []
  ) -> NSHostingView<some View> {
    let host = NSHostingView(
      rootView: SessionCapsuleCluster(
        elapsed: elapsed,
        level: MicLevelFeed(level: 0.4),
        controls: .stop,
        markers: markers,
        onMark: {},
        onStop: {}
      )
    )
    host.layoutSubtreeIfNeeded()
    return host
  }

  /// The acceptance case: the cluster is **one row** of the reserved height,
  /// and it charges the transcript no width at all — it floats, so its own
  /// intrinsic width is whatever three capsules need and nothing beside it has
  /// to give any up.
  func testTheClusterIsOneRowOfCapsules() {
    let size = clusterHost().fittingSize
    XCTAssertGreaterThan(size.width, 0, "the hosting view produced no layout")
    XCTAssertEqual(
      size.height,
      RecordingPaneMetrics.capsuleHeight,
      accuracy: 0.5,
      "the cluster draws \(size.height)pt against a reservation of "
        + "\(RecordingPaneMetrics.capsuleHeight)pt"
    )
  }

  /// **The cluster is exactly four capsules and the three gaps between them.**
  ///
  /// The count is the claim. `SessionClusterAction.allCases` says what the row
  /// holds and a `ForEach` draws it, so the table and the drawing cannot
  /// disagree with each other — which is precisely why neither of them can
  /// answer "is there a capsule here that should not be". Only the laid-out
  /// width can, so the reservation is composed from the four faces the row is
  /// allowed to have and compared against what the cluster draws.
  ///
  /// The faces come from `cluster.capsule(_:)`, the same builder the row uses:
  /// a test that rebuilt the label would measure its own copy of the markup and
  /// agree with itself about a capsule the cluster had stopped drawing.
  func testTheClusterIsExactlyFourCapsulesAndThreeGaps() {
    func laidOut<V: View>(_ view: V) -> CGFloat {
      let host = NSHostingView(rootView: view)
      host.layoutSubtreeIfNeeded()
      return host.fittingSize.width
    }
    let cluster = SessionCapsuleCluster(
      elapsed: 61,
      level: MicLevelFeed(level: 0.4),
      controls: .stop,
      markers: [],
      onMark: {},
      onStop: {}
    )
    let reserved =
      laidOut(SessionTimerCapsule(elapsed: 61, level: MicLevelFeed(level: 0.4)))
      + laidOut(cluster.capsule(.mark))
      + laidOut(cluster.capsule(.pause))
      + laidOut(cluster.capsule(.stop))
      + 3 * RecordingPaneMetrics.capsuleGap

    let drawn = clusterHost().fittingSize.width
    XCTAssertGreaterThan(drawn, 0, "the hosting view produced no layout")
    XCTAssertEqual(
      drawn,
      reserved,
      accuracy: 0.5,
      "the cluster draws \(drawn)pt against four capsules and three gaps at \(reserved)pt"
    )
  }

  /// **Pause grows into the word, and it is the only capsule that moves a
  /// pixel** (owner, 2026-08-13: "when not pause, same as before, when pause,
  /// pill grows, pushes the neighbors to either direction").
  ///
  /// This reverses the reservation the first cut shipped — `pauseCapsuleWidth`,
  /// which held the wide form in both states so the press could not move Stop.
  /// It kept that rule at a visible price: a round glyph adrift in a box sized
  /// for a word it was not saying, so a row of four capsules drew three
  /// different-looking gaps. Growth is the state change here, not a cost.
  ///
  /// What is asserted is therefore the *shape* of the growth rather than its
  /// absence: the row widens by exactly what Pause widens by, and Mark, Stop
  /// and the timer are untouched. Measured off the laid-out capsules rather
  /// than a constant — XIA-444 typed a number that disagreed with the row it
  /// described and every geometry test in the file stayed green through it.
  func testOnlyThePauseCapsuleGrowsWhenTheSessionPauses() {
    func laidOut<V: View>(_ view: V) -> CGFloat {
      let host = NSHostingView(rootView: view)
      host.layoutSubtreeIfNeeded()
      return host.fittingSize.width
    }
    func cluster(_ controls: LiveMeetingControls) -> SessionCapsuleCluster {
      SessionCapsuleCluster(
        elapsed: 754,
        level: MicLevelFeed(level: 0.4),
        controls: controls,
        markers: [],
        onMark: {},
        onPause: {},
        onStop: {}
      )
    }

    let running = cluster(.stop)
    let paused = cluster(.paused)
    let runningRow = laidOut(running)
    let pausedRow = laidOut(paused)
    XCTAssertGreaterThan(runningRow, 0, "the hosting view produced no layout")

    let pauseGrowth = laidOut(paused.capsule(.pause)) - laidOut(running.capsule(.pause))
    XCTAssertGreaterThan(
      pauseGrowth, 20,
      "the Pause capsule grew \(pauseGrowth)pt — it is not drawing the word")
    XCTAssertEqual(
      pausedRow - runningRow, pauseGrowth, accuracy: 0.5,
      "the row grew \(pausedRow - runningRow)pt against Pause's \(pauseGrowth)pt")

    for action in [SessionClusterAction.mark, .stop] {
      XCTAssertEqual(
        laidOut(paused.capsule(action)), laidOut(running.capsule(action)), accuracy: 0.5,
        "\(action) changed width when the session paused")
    }
  }

  /// And the word really is drawn — otherwise the test above measures a
  /// widening with no cause, and every state string in the row is a no-op.
  func testThePauseCapsuleSaysPausedOnlyWhilePaused() {
    XCTAssertEqual(SessionClusterAction.pause.title(paused: true), RecordingPaneCopy.pausedTitle)
    XCTAssertNil(SessionClusterAction.pause.title(paused: false))
    for action in [SessionClusterAction.mark, .stop] {
      XCTAssertNil(action.title(paused: true), "\(action) grew a label the row is icon-only to avoid")
      XCTAssertNil(action.title(paused: false))
    }
  }

  /// Crossing the hour re-sizes the glyphs and moves nothing around them —
  /// including the capsule they sit in, and the two capsules beside it.
  func testTheClusterDoesNotReflowWhenTheTimerCrossesTheHour() {
    let before = clusterHost(elapsed: 3599).fittingSize
    let after = clusterHost(elapsed: 3600).fittingSize
    XCTAssertGreaterThan(before.width, 0, "hosting view produced no layout")
    XCTAssertEqual(before.height, after.height, accuracy: 0.5, "the cluster changed height at the hour")
    XCTAssertEqual(before.width, after.width, accuracy: 0.5, "the cluster changed width at the hour")
    XCTAssertNotEqual(
      SessionTimerMetrics.fontSize(base: RecordingPaneMetrics.clockBase, elapsed: 3599),
      SessionTimerMetrics.fontSize(base: RecordingPaneMetrics.clockBase, elapsed: 3600),
      "the size did not step, so 'no reflow' proves nothing"
    )
  }

  /// The tally rides on Mark, and its number may not change the cluster's
  /// height **or its width** — at any count, the first one included.
  ///
  /// The tally rides on the control it counts, as a **badge overlaid** on Mark.
  /// This used to assert the opposite for the zero→one step — that the first
  /// moment *did* widen the capsule — which is the defect stated as a promise:
  /// a centred cluster splits any widening across both sides, so it stepped
  /// Stop right under the pointer. The plate reserved from zero that first
  /// fixed it kept this test green and cost the row its shape (Mark laid out at
  /// 44pt against Stop's 23pt, permanently, for digits that were not there). An
  /// overlay is outside the layout, so the size claim below now holds by
  /// construction rather than by a reservation someone has to keep in step.
  func testTheNumberOfMomentsNeverChangesTheClustersSize() {
    let none = clusterHost(markers: []).fittingSize
    let one = clusterHost(markers: [SessionMarker(at: 3)]).fittingSize
    let nine = clusterHost(markers: (0..<9).map { SessionMarker(at: TimeInterval($0 * 7)) }).fittingSize
    let many = clusterHost(markers: (0..<40).map { SessionMarker(at: TimeInterval($0 * 7)) }).fittingSize
    XCTAssertGreaterThan(none.width, 0, "the hosting view produced no layout")
    for (count, size) in [(1, one), (9, nine), (40, many)] {
      XCTAssertEqual(size.height, none.height, accuracy: 0.5, "\(count) moments made the cluster taller")
      XCTAssertEqual(size.width, none.width, accuracy: 0.5, "\(count) moments made the cluster wider")
    }
  }

  /// The transcript **reserves the cluster's whole footprint** at the bottom
  /// (owner's call: "Reserve space"), so no line can come to rest behind glass —
  /// which matters precisely because `scrollToNewest` pins the newest row to
  /// `.bottom`, i.e. to the point the cluster covers.
  ///
  /// The reserve has to come off the scroll view's **visible region**, and that
  /// is the whole of what this test is for. As shipped it was scroll *content*
  /// padding on the `LazyVStack`, and content padding buys nothing here:
  /// `scrollTo(_:anchor: .bottom)` aligns the target row's bottom with the
  /// bottom of the visible region, so 83pt of padding *after* the last row is
  /// simply offset the scroll view never needs to reach. The newest line came
  /// to rest flush against the window's bottom edge and the one before it sat
  /// behind the glass — for the whole session, with the reservation constant
  /// green beside it. The predecessor test measured `fittingSize` with and
  /// without the reserve, which content padding satisfies perfectly.
  ///
  /// So: the composition (never typed a second time), and then the laid-out
  /// scroll view, whose visible region must end `transcriptBottomReserve` above
  /// the bottom of the pane. Measured off the backing `NSScrollView` because
  /// that is the only place the difference is visible at all — a SwiftUI
  /// `.safeAreaInset` leaves its frame, clip view and `contentInsets` at full
  /// height (measured 2026-08-11), so a test could not tell it from the content
  /// padding that was the defect.
  func testTheTranscriptReservesTheClustersWholeFootprint() {
    XCTAssertEqual(
      RecordingPaneMetrics.transcriptBottomReserve,
      RecordingPaneMetrics.capsuleHeight
        + RecordingPaneMetrics.clusterBottomInset
        + RecordingPaneMetrics.clusterTranscriptGap
    )

    guard let bare = Self.transcriptBottomClearance(reserve: 0) else {
      return XCTFail("no scroll view in the laid-out transcript")
    }
    guard
      let reserved = Self.transcriptBottomClearance(
        reserve: RecordingPaneMetrics.transcriptBottomReserve
      )
    else {
      return XCTFail("no scroll view in the laid-out transcript")
    }

    XCTAssertEqual(bare, 0, accuracy: 0.5, "an unreserved transcript already ends short")
    XCTAssertEqual(
      reserved,
      RecordingPaneMetrics.transcriptBottomReserve,
      accuracy: 0.5,
      "the scroll view's visible region ends \(reserved)pt above the pane's bottom, "
        + "for a cluster that covers \(RecordingPaneMetrics.transcriptBottomReserve)pt — "
        + "content padding does not move where scrollTo(anchor: .bottom) lands"
    )
  }

  /// How far above the bottom of the pane the transcript's **visible region**
  /// ends, laid out at a real size.
  ///
  /// Measured off the backing `NSScrollView` rather than off a fitting size,
  /// because the fitting size cannot tell a reserve `scrollTo` respects from
  /// one it scrolls straight past. Both mechanisms that would be respected are
  /// summed: SwiftUI may inset the clip view's frame or set `contentInsets`,
  /// and the two are the same promise expressed differently.
  private static func transcriptBottomClearance(reserve: CGFloat) -> CGFloat? {
    let rows = LiveTranscript.rows(
      LiveTranscript.blocks(
        LiveTranscript.lines(
          segments: (0..<40).map {
            LiveMeetingSession.LiveSegment(id: UUID(), text: "line \($0)", endTime: TimeInterval($0))
          },
          partial: nil,
          elapsed: 40
        )
      )
    )
    let host = NSHostingView(
      rootView: LiveTranscriptView(rows: rows, volatileID: nil, bottomReserve: reserve)
    )
    host.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
    host.layoutSubtreeIfNeeded()
    guard let scroll = firstScrollView(in: host) else { return nil }
    let clip = scroll.convert(scroll.contentView.frame, to: host)
    let below = host.isFlipped ? host.bounds.maxY - clip.maxY : clip.minY
    return below + scroll.contentInsets.bottom
  }

  private static func firstScrollView(in view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    for child in view.subviews {
      if let found = firstScrollView(in: child) { return found }
    }
    return nil
  }

  /// **Stop does not move when a moment is flagged.** The count plate and its
  /// gap once appeared out of nothing on the first ⌘K — and because the cluster
  /// is horizontally centred, that widening is split across both sides and Stop
  /// translated right, out from under the pointer resting on it. That is the
  /// exact motion `RecordingPaneCopy.markerCount` refuses for the same reason
  /// one digit earlier.
  ///
  /// The count is a badge overlaid on Mark now, so nothing about it is in the
  /// layout and no width can reach Stop. That makes this test cheap to satisfy
  /// and no less worth running: it is the claim, and the claim outlived two
  /// mechanisms for keeping it. The badge is deliberately not red, so the probe
  /// below still has exactly one red shape to find.
  ///
  /// Asserted where it happens: the leading edge of the drawn red capsule, over
  /// four marker counts that cross both steps.
  func testTheNumberOfMomentsNeverMovesStop() {
    let size = CGSize(width: 700, height: 140)

    func stopLeadingEdge(_ count: Int) -> CGFloat? {
      let markers = (0..<count).map { SessionMarker(at: TimeInterval($0 * 7)) }
      guard
        let rep = RenderProbe.bitmap(
          ZStack {
            Color.white
            SessionCapsuleCluster(
              elapsed: 754,
              level: MicLevelFeed(level: 0.4),
              controls: .stop,
              markers: markers,
              onMark: {},
              onStop: {}
            )
          }
          .environment(\.colorScheme, .light),
          size: size
        )
      else { return nil }
      return Self.stopRedMinX(rep)
    }

    let edges = [0, 1, 9, 10].map { ($0, stopLeadingEdge($0)) }
    guard let first = edges[0].1 else {
      return XCTFail("the probe found no red capsule at all")
    }
    // The probe must be looking at Stop, and "right of centre" was only ever a
    // sanity guard. Now that the row is three capsules the edge is *derivable*,
    // so it is derived: the cluster is centred in the canvas, and Stop is the
    // last thing in it, so its leading edge is the row's trailing edge less its
    // own width. Nothing about that reading survives a capsule being added back.
    let cluster = clusterHost()
    let stopCapsule = NSHostingView(
      rootView: SessionCapsuleCluster(
        elapsed: 754,
        level: MicLevelFeed(level: 0.4),
        controls: .stop,
        markers: [],
        onMark: {},
        onStop: {}
      ).capsule(.stop)
    )
    stopCapsule.layoutSubtreeIfNeeded()
    let expected =
      (size.width + cluster.fittingSize.width) / 2 - stopCapsule.fittingSize.width
    XCTAssertEqual(
      first,
      expected,
      accuracy: 1,
      "Stop's drawn edge is \(first)pt, but a centred row of "
        + "\(cluster.fittingSize.width)pt ending in a \(stopCapsule.fittingSize.width)pt "
        + "capsule puts it at \(expected)pt"
    )
    for (count, edge) in edges {
      guard let edge else { return XCTFail("no red capsule at \(count) moments") }
      XCTAssertEqual(
        edge,
        first,
        accuracy: 1,
        "Stop starts at \(edge)pt with \(count) moments and \(first)pt with none"
      )
    }
  }

  /// The leading edge, in points, of the pixels that are Stop's red.
  ///
  /// Two conditions, because the ember meter is also a warm colour on this
  /// surface: red has to lead green by a lot (the meter's washed bars do not),
  /// and green and blue have to be close to each other (the ember's are 0.24
  /// apart at full strength). Either alone lets one of the two through.
  private static func stopRedMinX(_ rep: NSBitmapImageRep) -> CGFloat? {
    let scale = CGFloat(rep.pixelsWide) / max(rep.size.width, 1)
    var minX: Int?
    for x in stride(from: 0, to: rep.pixelsWide, by: 1) {
      for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
        guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        guard pixel.alphaComponent > 0.5 else { continue }
        guard pixel.redComponent - pixel.greenComponent > 0.30 else { continue }
        guard abs(pixel.greenComponent - pixel.blueComponent) < 0.10 else { continue }
        minX = min(minX ?? x, x)
        break
      }
      if minX != nil { break }
    }
    return minX.map { CGFloat($0) / scale }
  }

  /// **The visible Mark capsule flags a moment.** The first cut of the cluster
  /// gave the only Mark-looking control the *moments popover*, and `onMark`
  /// survived on a zero-sized, fully transparent, `accessibilityHidden(true)`
  /// button behind the row. So a mouse could not flag a moment at all, and
  /// VoiceOver could not either — the one element that marked was removed from
  /// the tree, and the one that could be reached opened a list. The list is
  /// gone from the surface now and this is what has to stay true without it.
  ///
  /// Asserted through `perform(_:)`, which is the same call every capsule's
  /// button makes. Walking the accessibility tree was tried first and cannot
  /// answer this: SwiftUI publishes no tree for a hosting view in an unhosted
  /// test bundle, with or without a window (measured 2026-08-11 — every label
  /// came back empty, Stop's included).
  func testEachCapsuleRunsItsOwnJobAndNoOtherCapsulesJob() {
    var marked = 0
    var paused = 0
    var stopped = 0
    let cluster = SessionCapsuleCluster(
      elapsed: 61,
      level: MicLevelFeed(level: 0.4),
      controls: .stop,
      markers: [],
      onMark: { marked += 1 },
      onPause: { paused += 1 },
      onStop: { stopped += 1 }
    )

    cluster.perform(.mark)
    XCTAssertEqual(marked, 1, "the Mark capsule does not flag a moment")
    XCTAssertEqual(paused, 0)
    XCTAssertEqual(stopped, 0)

    cluster.perform(.pause)
    XCTAssertEqual(paused, 1, "the Pause capsule does not pause")
    XCTAssertEqual(marked, 1)
    XCTAssertEqual(stopped, 0, "the Pause capsule ended the session")

    cluster.perform(.stop)
    XCTAssertEqual(stopped, 1)
    XCTAssertEqual(marked, 1)
    XCTAssertEqual(paused, 1)
  }

  /// Four pills, three buttons, one job each — the owner's "one button per
  /// pill" over a table with nothing left in it that the surface does not do.
  /// Every one of them is named, since an icon-only control's label is the only
  /// name it has, and **in both of its faces**: the pause capsule has two, and
  /// a face that collided with another capsule's would be a row with two
  /// identically-named controls in exactly one state of the session.
  ///
  /// Stop stays **last**, which `testTheNumberOfMomentsNeverMovesStop` derives
  /// its expected edge from.
  func testEveryJobOnTheClusterIsItsOwnNamedCapsule() {
    let actions = SessionClusterAction.allCases
    XCTAssertEqual(actions, [.mark, .pause, .stop], "the row's order changed")
    XCTAssertEqual(actions.last, .stop, "Stop is no longer the last capsule in the row")
    for paused in [false, true] {
      XCTAssertEqual(
        Set(actions.map { $0.label(paused: paused) }).count,
        actions.count,
        "two capsules answer to the same name (paused: \(paused))"
      )
      XCTAssertEqual(
        Set(actions.map { $0.symbol(paused: paused) }).count,
        actions.count,
        "two capsules draw the same glyph (paused: \(paused))"
      )
    }
    XCTAssertEqual(SessionClusterAction.mark.label(paused: false), RecordingPaneCopy.markTitle)
    XCTAssertEqual(SessionClusterAction.stop.label(paused: false), RecordingPaneCopy.stopTitle)

    // The tally rides on the control that produces it, and on nothing else.
    // With no list left to open it is the only feedback ⌘K has.
    XCTAssertEqual(actions.filter(\.carriesMarkerCount), [.mark])
  }

  /// **The pause capsule says which of its two verbs it is about to run.** One
  /// case with two faces rather than two cases, because the row is `allCases`
  /// in order and a case that cannot be drawn in the current state would be a
  /// hole in it — so the face is what carries the state, and it has to carry it
  /// in the label, the glyph and the tooltip alike. An icon that changed with
  /// no name change would leave a VoiceOver user pressing "Pause" to resume.
  func testThePauseCapsuleNamesWhichVerbItWillRun() {
    XCTAssertEqual(SessionClusterAction.pause.label(paused: false), RecordingPaneCopy.pauseTitle)
    XCTAssertEqual(SessionClusterAction.pause.label(paused: true), RecordingPaneCopy.resumeTitle)
    XCTAssertEqual(SessionClusterAction.pause.symbol(paused: false), "pause.fill")
    XCTAssertEqual(SessionClusterAction.pause.symbol(paused: true), "play.fill")
    XCTAssertEqual(SessionClusterAction.pause.help(paused: false), RecordingPaneCopy.pauseTitle)
    XCTAssertEqual(SessionClusterAction.pause.help(paused: true), RecordingPaneCopy.resumeTitle)
    XCTAssertNotEqual(RecordingPaneCopy.pauseTitle, RecordingPaneCopy.resumeTitle)

    // The other two do not move with it: their whole point is that they mean
    // the same thing in both states.
    for action in [SessionClusterAction.mark, .stop] {
      XCTAssertEqual(action.label(paused: false), action.label(paused: true))
      XCTAssertEqual(action.symbol(paused: false), action.symbol(paused: true))
    }
  }

  /// **Mark is refused while paused, and Pause and Stop are not.**
  ///
  /// `NotaModel.markCurrentMoment` gates on the open microphone, so a Mark
  /// capsule left live during a pause would be a control that does nothing at
  /// all — the tally is the whole of what a press says out loud, and it would
  /// not move. Stop is live because Stop is terminal from a pause too: an owner
  /// may not have to resume in order to end.
  func testAPausedSessionRefusesMarkAndKeepsPauseAndStop() {
    XCTAssertFalse(SessionClusterAction.mark.isEnabled(.paused))
    XCTAssertTrue(SessionClusterAction.pause.isEnabled(.paused))
    XCTAssertTrue(SessionClusterAction.stop.isEnabled(.paused))

    for action in SessionClusterAction.allCases {
      XCTAssertTrue(action.isEnabled(.stop), "\(action) is refused on a live session")
      // Nothing on the cluster is pressable once the session is finalizing, or
      // in either failed state — those wear the banner, not the cluster.
      for controls in [LiveMeetingControls.finalizing, .saveOrDiscard, .retryOrDiscard, .start, .starting] {
        XCTAssertFalse(
          action.isEnabled(controls),
          "\(action) is pressable in \(controls)"
        )
      }
    }
  }

  /// **Reviewing moments is not something the recording surface does** (owner,
  /// 2026-08-11), so the marker list has no way to be reached from it. Asserted
  /// on the table because that is what the row is built from: a capsule that is
  /// not a case cannot be drawn, disabled, tinted or given a shortcut.
  ///
  /// `SessionMarkerList` itself is deliberately still in the file — XIA-433 is
  /// where a mark gets a meaning worth reading back — so it is exercised here
  /// rather than left to rot untouched.
  func testNoCapsuleOpensTheMarkerList() {
    XCTAssertFalse(
      SessionClusterAction.allCases.contains {
        $0.symbol(paused: false) == "list.bullet" || $0.symbol(paused: true) == "list.bullet"
      },
      "a capsule is drawing the moments list's glyph again"
    )
    XCTAssertFalse(
      SessionClusterAction.allCases.contains {
        $0.label(paused: false) == RecordingPaneCopy.markersHeading
          || $0.label(paused: true) == RecordingPaneCopy.markersHeading
      },
      "a capsule is named for the moments list again"
    )

    // The list survives for XIA-433 and still lays out, with both of its states.
    for markers in [[], [SessionMarker(at: 12), SessionMarker(at: 40)]] {
      let host = NSHostingView(rootView: SessionMarkerList(markers: markers))
      host.layoutSubtreeIfNeeded()
      XCTAssertEqual(host.fittingSize.width, SessionMarkerList.width + 2 * CraftTokens.spacing16, accuracy: 0.5)
    }
  }

  /// ⌘K is **named on the surface**. The cluster is icon-only, so the shortcut
  /// reaches the owner through the tooltip and the accessibility hint or it
  /// reaches them nowhere: it used to be drawn in no label, no `.help`, and no
  /// hint anywhere, on a button that was itself hidden from accessibility.
  func testTheMarkControlNamesItsShortcut() {
    XCTAssertEqual(SessionClusterAction.mark.help(paused: false), RecordingPaneCopy.markHelp)
    XCTAssertEqual(
      SessionClusterAction.stop.help(paused: false),
      RecordingPaneCopy.stopTitle,
      "a capsule with no shortcut invented one"
    )
    XCTAssertEqual(RecordingPaneCopy.markShortcut, "⌘K")
    XCTAssertTrue(
      RecordingPaneCopy.markHelp.contains(RecordingPaneCopy.markTitle),
      "the Mark tooltip does not name the action"
    )
    XCTAssertTrue(
      RecordingPaneCopy.markHelp.contains(RecordingPaneCopy.markShortcut),
      "the Mark tooltip does not name ⌘K, which is drawn nowhere else"
    )
  }

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
    let idle = LiveMeetingView(
      session: LiveMeetingSession(),
      onStart: {},
      onStop: {},
      markerLog: SessionMarkerLog()
    )
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
/// Three of this suite's claims are of that kind and none could be made about a
/// constant: "the idle pane draws no ember", "Stop stays its own red over any
/// backdrop", and "the number of moments never moves Stop" (which needs the
/// *drawn* leading edge of the red capsule, not a fitting size).
///
/// It deliberately offers no equality helper. The claim it once had one for —
/// "Stop is drawn identically with and without Reduce Transparency" — is gone
/// with the bar's opaque ember fill: Stop is now 62% over glass, so it varies
/// with the ground **on purpose**, and an equality assertion here would fail by
/// construction. `testStopStaysItsOwnRedOverAnyBackdrop` is what replaced it,
/// and it asserts the colour survives rather than that the value does.
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

}

// MARK: - One colour per meaning

/// The app's colour vocabulary, asserted where it is declared rather than at
/// each surface that reads it. Both of these were drift the owner could see:
/// two blues for "the confident action" in one window, and one failed summary
/// drawn orange in the drawer row, orange on the receipt and red once the
/// Details panel was opened to find out why.
@MainActor
final class ColourVocabularyTests: XCTestCase {
  /// A **filled** confident action is one blue, wherever it is drawn. The local
  /// cluster's prominent button (Details, bottom-right) and the recording
  /// cluster's Mark (bottom-centre) are the two loudest blue affordances in the
  /// window, and the prominent button used to take `Color.accentColor` while
  /// Mark took `CraftTokens.primaryBlue` — a difference the token's own comment
  /// calls deliberate.
  func testTheTwoFilledConfidentActionsAreOneBlue() {
    XCTAssertEqual(
      NSColor(LocalCluster.prominentTint).usingColorSpace(.sRGB),
      NSColor(SessionClusterAction.mark.tint).usingColorSpace(.sRGB)
    )
    XCTAssertEqual(
      NSColor(LocalCluster.prominentTint).usingColorSpace(.sRGB),
      NSColor(CraftTokens.primaryBlue).usingColorSpace(.sRGB)
    )
  }

  /// One word for failure. `CraftTokens.failure` is `stopRed` by construction —
  /// Stop is that red as a fill, a failed job is that red as ink — so the
  /// drawer row, the receipt's stage line, the Details panel's message and the
  /// failed-session banner cannot disagree the way they did.
  func testAFailedJobIsOneColour() {
    for appearance in [NSAppearance(named: .aqua), NSAppearance(named: .darkAqua)] {
      guard let appearance else { continue }
      var failure: NSColor?
      var stop: NSColor?
      var orange: NSColor?
      appearance.performAsCurrentDrawingAppearance {
        failure = NSColor(CraftTokens.failure).usingColorSpace(.sRGB)
        stop = NSColor(CraftTokens.stopRed).usingColorSpace(.sRGB)
        orange = NSColor.systemOrange.usingColorSpace(.sRGB)
      }
      XCTAssertEqual(failure, stop, "failure ink and Stop's fill are one red")
      XCTAssertNotEqual(
        failure, orange,
        "a failed job is red, never the orange half of the old split"
      )
    }
  }
}
