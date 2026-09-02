import AppKit
import SwiftUI
import XCTest

@testable import Nota

/// **One reading surface** (ADR 0007), asserted where the two sides can differ.
///
/// The claim in this repo's docs was always that "a run is the transcript
/// arriving, and the pane becomes the document without the window changing".
/// Measured on 2026-09-02 it was false in six ways at once — a 14pt body
/// against 18.5, full window width against a 34em column, a 52pt gutter against
/// 48, a timestamp on every turn against hover only — so Stop swapped one
/// reading surface for a materially different one, in place. Every test here is
/// one of those rows, plus the two things the live side owes on its own: a name
/// column that is reserved before there is a name to put in it (ADR 0008), and
/// a control that says the follow is off.
@MainActor
final class LiveReadingSurfaceTests: XCTestCase {
  // MARK: - The column, the gutter and the faces are the document's

  /// The gutter is **the document's number**, reached through `Metrics` rather
  /// than agreed with it. It was 52 on this side and 48 on the other, so the
  /// words stepped 4pt at Stop; two constants that happen to be equal today is
  /// how that starts again.
  func testTheLiveGutterIsTheDocumentsGutter() {
    XCTAssertEqual(RecordingPaneMetrics.gutterWidth, Metrics.gutterWidth)
    XCTAssertEqual(RecordingPaneMetrics.gutterGap, Metrics.tsGutterTrailingGap)

    // And the lane really holds what is drawn in it: the ember rule sits inside
    // the gutter rather than in the reading column, and the hover timestamp
    // still has room left beside it.
    XCTAssertLessThan(
      RecordingPaneMetrics.markerRuleInset,
      RecordingPaneMetrics.gutterWidth,
      "the marker rule is drawn outside the gutter the column reserves"
    )
    XCTAssertGreaterThan(
      RecordingPaneMetrics.gutterWidth
        - RecordingPaneMetrics.gutterGap
        - RecordingPaneMetrics.markerRuleLane,
      0,
      "the rule's lane leaves no room for a timestamp beside it"
    )
  }

  /// The measure and its placement are **asked of the document's own
  /// arithmetic**, not reimplemented beside it. Checked across the widths that
  /// exercise both of its rules — the narrow one where the inset is the gutter
  /// floor, and the wide one where the cap binds and the leftover is split.
  func testTheLiveColumnIsTheDocumentsColumn() {
    for available in [400, 600, 780, 980, 1400, 2200].map(CGFloat.init) {
      XCTAssertEqual(
        RecordingPaneMetrics.readingColumnWidth(available: available),
        RichTextViewer.Column.containerWidth(available: available),
        "the live column is not the document's at \(available)pt"
      )
      XCTAssertEqual(
        RecordingPaneMetrics.readingColumnInset(available: available),
        RichTextViewer.Column.inset(available: available),
        "the live column sits somewhere else at \(available)pt"
      )
    }
    XCTAssertEqual(
      RecordingPaneMetrics.readingColumnWidth(available: 2200),
      Metrics.readingMeasure,
      "a wide window stopped capping the live measure at 34em"
    )
    XCTAssertGreaterThanOrEqual(
      RecordingPaneMetrics.readingColumnInset(available: 400),
      RecordingPaneMetrics.gutterWidth,
      "a narrow window squeezed the gutter out from under the column"
    )
  }

  /// The faces are the document's, wrapped rather than restated. 18.5pt is the
  /// load-bearing half: at ≥18pt WCAG calls the text large, which is the whole
  /// reason `GroundInk.Tier.reading` may draw at 0.80.
  func testTheLiveBodyIsTheDocumentsReadingFace() {
    XCTAssertEqual(RecordingPaneMetrics.transcriptFont, Font(NSFonts.readingBody))
    XCTAssertEqual(RecordingPaneMetrics.speakerFont, Font(NSFonts.readingSpeaker))
    XCTAssertEqual(RecordingPaneMetrics.gutterFont, Font(NSFonts.readingGutter))
    XCTAssertGreaterThanOrEqual(
      NSFonts.readingBody.pointSize,
      18,
      "the reading body dropped below WCAG large text, which the ink's alpha depends on"
    )
  }

  /// The follow's slack was `spacing24`, written when the body was 14pt and
  /// laid out at ~17. It is measured off the reading face now, because a slack
  /// shorter than one line makes the way back to the follow harder than the
  /// scroll that left it.
  func testTheFollowSlackIsOneLineOfTheFaceItScrolls() {
    let face = NSFonts.readingBody
    let line = (face.ascender - face.descender).rounded(.up)
    XCTAssertEqual(
      RecordingPaneMetrics.followSlack,
      line + Metrics.lineSpacingReading + RecordingPaneMetrics.lineSpacing
    )
    XCTAssertGreaterThan(
      RecordingPaneMetrics.followSlack,
      line,
      "the slack is shorter than the line it is supposed to absorb"
    )
  }

  // MARK: - The name column is reserved before there is a name in it

  /// **A name arriving moves no text** (ADR 0007/0008). The live pipeline fills
  /// `LiveSegment.speaker` turn by turn as identification lands, and the seal
  /// re-runs diarization over the whole audio and may add or correct a name at
  /// Stop — so the words have to share one left edge whether the column beside
  /// them holds a name or nothing at all.
  ///
  /// Measured off the pixels, and bounded on both sides so it cannot pass by
  /// accident: the words start at the same column in both renders, the nameless
  /// render draws **no ink at all** in the name column (which is what stops the
  /// text having crept left into it), and the named render does — otherwise the
  /// fixture would be proving that a name that is never drawn moves nothing.
  func testANameArrivingMovesNoText() {
    let text = "the migration lands next Tuesday"
    let id = UUID()
    let named = Self.transcriptBitmap([
      LiveTranscriptLine(id: id, text: text, endTime: 12, speaker: "Amara")
    ])
    let nameless = Self.transcriptBitmap([
      LiveTranscriptLine(id: id, text: text, endTime: 12, speaker: nil)
    ])
    guard let named, let nameless else { return XCTFail("the transcript did not render") }

    let scale = CGFloat(named.pixelsWide) / Self.probeSize.width
    let columnStart = Int(
      (RecordingPaneMetrics.readingColumnInset(available: Self.probeSize.width) * scale)
        .rounded(.down)
    )
    let textStart = Int((Self.textLeadingEdge * scale).rounded(.down))

    guard
      let namedText = Self.firstInk(named, from: textStart),
      let namelessText = Self.firstInk(nameless, from: textStart)
    else {
      return XCTFail("the words did not render at all")
    }
    XCTAssertEqual(
      namedText,
      namelessText,
      "a name arriving moved the words (\(namelessText) → \(namedText))"
    )

    XCTAssertEqual(
      Self.firstInk(nameless, from: columnStart),
      namelessText,
      "a nameless turn drew ink in the reserved name column, or its words crept into it"
    )
    guard let namedInk = Self.firstInk(named, from: columnStart) else {
      return XCTFail("the name did not render")
    }
    XCTAssertLessThan(
      namedInk,
      textStart,
      "the name was not drawn in its own column, so this proves nothing about the words"
    )
  }

  /// **Nothing is drawn in the gutter at rest.** Timestamps are hover-only now
  /// (ADR 0007) — the document's rule, for the document's reason: always-on
  /// timestamps in a page being read are noise, and the lane is wanted for the
  /// moment marks. An unhosted probe has no pointer, so this renders exactly
  /// the resting state and requires the whole gutter to be empty.
  func testTheGutterIsEmptyUntilThePointerIsOverARow() {
    guard
      let rep = Self.transcriptBitmap([
        LiveTranscriptLine(id: UUID(), text: "we lost the socket mid-sentence", endTime: 12)
      ])
    else {
      return XCTFail("the transcript did not render")
    }
    let scale = CGFloat(rep.pixelsWide) / Self.probeSize.width
    let columnStart = Int(
      (RecordingPaneMetrics.readingColumnInset(available: Self.probeSize.width) * scale)
        .rounded(.down)
    )
    guard let ink = Self.firstInk(rep, from: 0) else {
      return XCTFail("the transcript drew no ink at all, so the probe proves nothing")
    }
    XCTAssertGreaterThanOrEqual(
      ink,
      columnStart,
      "ink was drawn in the gutter with no pointer over any row"
    )
  }

  // MARK: - The row model cannot serve a stale name

  /// **A live name lands in place**, and the row cache has to see it. Its key
  /// was the segment count plus the last segment's id — both unchanged when
  /// identification writes a name back onto a turn that is already in the list
  /// — so without a speaker signature the transcript would keep drawing rows
  /// built before the name existed until an unrelated turn arrived. Exactly the
  /// `markerSignature` defect, arriving from the other direction.
  func testANameWrittenInPlaceRebuildsTheRowModel() {
    let cache = LiveTranscriptRowCache()
    let first = LiveMeetingSession.LiveSegment(id: UUID(), text: "one", endTime: 5)
    let second = LiveMeetingSession.LiveSegment(id: UUID(), text: "two", endTime: 12)

    let anonymous = cache.rows(segments: [first, second], partial: nil, elapsed: 12)
    XCTAssertEqual(cache.recomputeCount, 1)
    XCTAssertEqual(anonymous.map(\.speaker), [String?](repeating: nil, count: 2))

    var identified = first
    identified.speaker = "Amara"
    let named = cache.rows(segments: [identified, second], partial: nil, elapsed: 12)
    XCTAssertEqual(
      cache.recomputeCount,
      2,
      "a name written onto a segment already in the list did not reach the row model"
    )
    // Two speakers now, so two turns — and the name is on the row that opens
    // the first of them.
    XCTAssertEqual(named.map(\.speaker), ["Amara", nil])
    XCTAssertEqual(named.map(\.id), [first.id, second.id], "a name changed which rows exist")

    _ = cache.rows(segments: [identified, second], partial: nil, elapsed: 12)
    XCTAssertEqual(cache.recomputeCount, 2, "the same transcript was rebuilt again")
  }

  /// And the speaker really comes through the model rather than being dropped
  /// at the line builder, which is where it was hardcoded nil.
  func testTheSegmentsSpeakerReachesTheDrawnRow() {
    let lines = LiveTranscript.lines(
      segments: [
        LiveMeetingSession.LiveSegment(id: UUID(), text: "one", endTime: 3, speaker: "Amara"),
        LiveMeetingSession.LiveSegment(id: UUID(), text: "two", endTime: 7, speaker: "Kenny"),
      ],
      partial: nil,
      elapsed: 7
    )
    XCTAssertEqual(lines.map(\.speaker), ["Amara", "Kenny"])
    XCTAssertEqual(
      LiveTranscript.rows(LiveTranscript.blocks(lines)).map(\.speaker),
      ["Amara", "Kenny"]
    )
  }

  // MARK: - Jump to newest

  /// **Absent while following, present when not.** Rendered rather than
  /// asserted about a flag: the control's whole job is to be the one thing on
  /// screen that says the follow is off, so "it draws nothing" has to be a
  /// measurement of what is drawn.
  func testTheJumpControlIsAbsentWhileFollowingAndPresentWhenNot() {
    XCTAssertFalse(SessionJumpToNewestControl.isShown(isFollowing: true, hasRows: true))
    XCTAssertTrue(SessionJumpToNewestControl.isShown(isFollowing: false, hasRows: true))
    XCTAssertFalse(
      SessionJumpToNewestControl.isShown(isFollowing: false, hasRows: false),
      "an empty transcript offered a way back to a line that does not exist"
    )

    XCTAssertEqual(
      Self.jumpControlSize(isFollowing: true),
      .zero,
      "the control drew itself while the newest line was already being followed"
    )
    let shown = Self.jumpControlSize(isFollowing: false)
    XCTAssertGreaterThan(shown.width, 0, "the control drew nothing while the follow was off")
    XCTAssertGreaterThan(shown.height, 0)
  }

  /// **It is an overlay, not a capsule in the row.** The cluster is centred, so
  /// anything joining it widens the row and splits the widening across both
  /// sides, stepping Stop out from under the pointer aiming at it — the reason
  /// `markerCountWidth` was deleted.
  ///
  /// Asserted twice, because the two halves fail differently. Structurally:
  /// `SessionClusterAction.allCases` is the table the cluster draws with a
  /// `ForEach`, and a job that is not a case in it cannot be given a capsule, a
  /// tint or a shortcut by accident. And in pixels: Stop's drawn red starts and
  /// ends at the same place whether or not the control is on screen.
  func testTheJumpControlNeverJoinsTheCapsuleRow() {
    XCTAssertEqual(SessionClusterAction.allCases.count, 3, "the cluster grew a capsule")
    let titles: [String] = SessionClusterAction.allCases.flatMap { action -> [String] in
      [action.title(paused: false), action.title(paused: true)].compactMap { $0 }
        + [action.label(paused: false), action.label(paused: true)]
    }
    XCTAssertFalse(
      titles.contains(RecordingPaneCopy.jumpToNewestTitle),
      "a capsule in the row is wearing the jump control's word"
    )

    guard
      let without = Self.paneBitmap(showingJumpControl: false),
      let with = Self.paneBitmap(showingJumpControl: true),
      let bare = Self.stopRedSpan(without),
      let overlaid = Self.stopRedSpan(with)
    else {
      return XCTFail("the probe found no red capsule")
    }
    XCTAssertEqual(
      overlaid.min,
      bare.min,
      accuracy: 1,
      "Stop's leading edge moved when the jump control appeared"
    )
    XCTAssertEqual(
      overlaid.max,
      bare.max,
      accuracy: 1,
      "Stop's trailing edge moved when the jump control appeared"
    )
  }

  /// Under Reduce Motion it may fade, and it may not travel. `Tokens.popIn` is
  /// the app's one answer to that and this pins which half goes.
  func testTheJumpControlDoesNotTravelUnderReduceMotion() {
    XCTAssertFalse(Tokens.popInScales(reduceMotion: true))
    XCTAssertTrue(Tokens.popInScales(reduceMotion: false))
  }

  /// The control names what pressing it does, in words, in `RecordingPaneCopy`
  /// — where the promise about every string this surface can put on screen is
  /// kept. It is not a memo/meeting difference and never can be: it is a
  /// function of the scroll position alone.
  func testTheJumpControlsWordsAreCoveredByThePanesCopyPromise() {
    for controls in LiveMeetingControls.allCases {
      let all = RecordingPaneCopy.all(kind: .meeting, controls: controls)
      XCTAssertTrue(all.contains(RecordingPaneCopy.jumpToNewestTitle))
      XCTAssertTrue(all.contains(RecordingPaneCopy.jumpToNewestLabel))
      XCTAssertEqual(
        RecordingPaneCopy.all(kind: .memo, controls: controls).filter {
          $0 == RecordingPaneCopy.jumpToNewestTitle || $0 == RecordingPaneCopy.jumpToNewestLabel
        }.count,
        2,
        "the jump control says something different to a memo"
      )
    }
    XCTAssertNotEqual(RecordingPaneCopy.jumpToNewestTitle, RecordingPaneCopy.jumpToNewestLabel)
  }

  // MARK: - Probes

  /// Wide enough that the 34em cap binds and the column is really centred, so
  /// the inset under test is the computed one rather than the 48pt floor.
  private static let probeSize = CGSize(width: 760, height: 200)

  /// Where the **words** start, in the pane's own coordinates: the column's
  /// inset, plus the reserved name column and the gap after it. Composed from
  /// the constants the row is laid out with, never typed.
  private static var textLeadingEdge: CGFloat {
    RecordingPaneMetrics.readingColumnInset(available: probeSize.width)
      + RecordingPaneMetrics.speakerColumnWidth
      + RecordingPaneMetrics.speakerColumnGap
  }

  private static func transcriptBitmap(_ lines: [LiveTranscriptLine]) -> NSBitmapImageRep? {
    RenderProbe.bitmap(
      ZStack {
        Color.white
        LiveTranscriptView(rows: LiveTranscript.rows(LiveTranscript.blocks(lines)), volatileID: nil)
      }
      .environment(\.colorScheme, .light),
      size: probeSize
    )
  }

  /// The pane as it is really composed: the transcript with the cluster's
  /// footprint reserved off its frame, the cluster floating over it, and the
  /// jump control overlaid in the band above the cluster — the same three
  /// pieces `LiveMeetingView` puts in its `ZStack`.
  private static func paneBitmap(showingJumpControl: Bool) -> NSBitmapImageRep? {
    let lines = (0..<12).map {
      LiveTranscriptLine(id: UUID(), text: "line \($0)", endTime: TimeInterval($0 * 4))
    }
    return RenderProbe.bitmap(
      ZStack(alignment: .bottom) {
        Color.white
        LiveTranscriptView(
          rows: LiveTranscript.rows(LiveTranscript.blocks(lines)),
          volatileID: nil,
          bottomReserve: RecordingPaneMetrics.transcriptBottomReserve
        )
        .overlay(alignment: .bottom) {
          SessionJumpToNewestControl(
            isFollowing: !showingJumpControl,
            hasRows: true,
            bottomReserve: RecordingPaneMetrics.transcriptBottomReserve
          ) {}
        }

        SessionCapsuleCluster(
          elapsed: 754,
          level: MicLevelFeed(level: 0.4),
          controls: .stop,
          markers: [],
          onMark: {},
          onStop: {}
        )
        .padding(.bottom, RecordingPaneMetrics.clusterBottomInset)
      }
      .environment(\.colorScheme, .light),
      size: CGSize(width: 760, height: 320)
    )
  }

  /// The leading and trailing edges, in points, of the pixels that are Stop's
  /// red. Two conditions, because the ember meter is also a warm colour on this
  /// surface: red has to lead green by a lot, and green and blue have to be
  /// close to each other.
  private static func stopRedSpan(_ rep: NSBitmapImageRep) -> (min: CGFloat, max: CGFloat)? {
    let scale = CGFloat(rep.pixelsWide) / 760
    var minX: Int?
    var maxX: Int?
    for x in 0..<rep.pixelsWide {
      for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
        guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        guard pixel.alphaComponent > 0.5 else { continue }
        guard pixel.redComponent - pixel.greenComponent > 0.30 else { continue }
        guard abs(pixel.greenComponent - pixel.blueComponent) < 0.10 else { continue }
        minX = min(minX ?? x, x)
        maxX = max(maxX ?? x, x)
        break
      }
    }
    guard let minX, let maxX else { return nil }
    return (CGFloat(minX) / scale, CGFloat(maxX) / scale)
  }

  /// The first column at or right of `first` holding dark, near-neutral ink
  /// (`GroundInk.light` is `#1C1A16`) over the white the probe paints.
  private static func firstInk(_ rep: NSBitmapImageRep, from first: Int) -> Int? {
    for x in max(0, first)..<rep.pixelsWide {
      for y in stride(from: 0, to: rep.pixelsHigh, by: 1) {
        guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        guard pixel.alphaComponent > 0.5 else { continue }
        if pixel.brightnessComponent < 0.65 { return x }
      }
    }
    return nil
  }

  private static func jumpControlSize(isFollowing: Bool) -> CGSize {
    let host = NSHostingView(
      rootView: SessionJumpToNewestControl(
        isFollowing: isFollowing,
        hasRows: true,
        bottomReserve: 0
      ) {}
    )
    host.layoutSubtreeIfNeeded()
    return host.fittingSize
  }
}
