import AppKit
import SwiftUI
import XCTest

@testable import Nota

/// XIA-429's promises about what a finished record says, and where.
///
/// Every case here is arithmetic or a pure decision — the split
/// `SessionTimerMetrics` and `HUDPrompterMetrics` established — except the
/// three that are about layout, which are laid out.
@MainActor
final class RecordFactsTests: XCTestCase {
  // MARK: - One model, two renderings

  /// The single strongest reason option B was chosen: the receipt at Stop and
  /// the document's fact strip cannot grow separate fact lists or separate
  /// formatting, because there is one list and one formatter.
  ///
  /// Asserted as identity rather than as similarity — the strip is literally
  /// the receipt's items, in the receipt's order, with the receipt's words.
  func testTheReceiptAndTheStripDrawTheSameFactsInTheSameOrder() {
    let facts = Self.full
    XCTAssertEqual(
      facts.items.map(\.field),
      [.duration, .kind, .speakers, .moments, .audio, .cost],
      "the field order changed; both renderings walk this one list"
    )
    // The cost is deliberately **last**, which is what makes "a pending slot
    // does not move anything" a claim about the receipt's own width rather than
    // about facts drawn after it.
    XCTAssertEqual(RecordFactField.allCases.last, .cost)

    // The two renderings, compared through the functions the two views
    // literally walk — not through a string neither of them calls. The receipt
    // draws its duration as the clock and the rest as facts; the strip draws
    // all of them.
    let receiptDrawn =
      [RecordFactField.duration] + RecordReceiptView.trailingItems(facts).map(\.field)
    XCTAssertEqual(
      receiptDrawn,
      RecordFactStripView.drawnItems(facts).map(\.field),
      "the receipt and the strip put different facts on screen for one record"
    )
    XCTAssertEqual(
      RecordFactStripView.drawnItems(facts).compactMap(\.text).joined(separator: " · "),
      facts.stripText
    )
    XCTAssertEqual(facts.stripText, "18:42 · Meeting · 3 speakers · 4 moments · 17.5 MB · $0.0031")

    // **The colour arm of the same identity.** The list and the formatter were
    // shared from the day these shipped and the *ink* was not: the strip drew
    // `secondaryLabelColor` while the receipt drew 85% white, so the owner read
    // one sentence twice — at Stop and in the Details panel — in two visibly
    // different inks. Both files are read rather than rendered, because these
    // are plain modifiers with no function to ask and an adoption gap is
    // invisible to a test that only checks the values that are there. (Same
    // mechanism `testTheRunningPaneIsInkedAndNotLabelled` uses.)
    let banned = [
      ".foregroundStyle(.primary", ".foregroundStyle(.secondary", ".foregroundStyle(.tertiary",
      ".white.opacity(", "Color.white",
    ]
    var offenders: [String] = []
    for name in ["RecordFacts.swift", "RecordReceiptView.swift"] {
      for (index, line) in Self.uiSource(name).split(
        separator: "\n", omittingEmptySubsequences: false
      ).enumerated() {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.hasPrefix("//"), !text.hasPrefix("///") else { continue }
        if banned.contains(where: { text.contains($0) }) {
          offenders.append("\(name):\(index + 1) \(text)")
        }
      }
    }
    XCTAssertEqual(
      offenders, [],
      "one RecordFacts, two colour systems — the thing the shared-data rule exists to "
        + "prevent: \(offenders)")
  }

  // **Why this rule is read off the source and not rendered.**
  //
  // The obvious assertion — put the receipt over a light ground under
  // `.light` and measure the fact glyphs — cannot be written: every fact is
  // drawn at `.opacity(arrived ? 1 : 0)` and `arrived` flips in `.onAppear`,
  // which an unhosted `NSHostingView` never fires. A probe therefore sees a
  // receipt with no facts in it at all (darkest pixel 255.0, measured), so it
  // would have been green against white text, against ink, and against no
  // text — the adjacent-assertion trap this file already carries a warning
  // about in `testTheTranscriptReservesTheReceiptsFootprintOnItsOwnFrame`.
  // The colour arm of the identity test above reads both files instead.

  /// The **strip** drops a pending fact entirely; the **receipt** keeps its
  /// slot. Both are the same rule read from two sides: the receipt has promised
  /// not to reflow, and a header row has promised not to carry an empty gap.
  ///
  /// Reachable on every live meeting: while the summary is in flight the cost
  /// is `.pending`, and the strip used to draw `… · 17.5 MB · ` — a dangling
  /// separator and a blank slot — for the whole run.
  func testAPendingFactIsASlotOnTheReceiptAndNothingAtAllOnTheStrip() {
    var facts = Self.full
    facts.cost = .pending

    let drawn = RecordFactStripView.drawnItems(facts)
    XCTAssertFalse(drawn.contains { $0.isPending }, "the strip drew a hole and a dangling separator")
    XCTAssertEqual(drawn.map(\.field), [.duration, .kind, .speakers, .moments, .audio])
    XCTAssertEqual(facts.stripText, "18:42 · Meeting · 3 speakers · 4 moments · 17.5 MB")
    XCTAssertFalse(facts.stripText.hasSuffix("·"))

    XCTAssertTrue(
      RecordReceiptView.trailingItems(facts).contains { $0.field == .cost && $0.isPending },
      "the receipt lost the slot it reserves so nothing reflows"
    )
  }

  /// **A figure that is still growing says so.** The receipt's cost is derived
  /// from the record's own total *and* from whether a billed call is running.
  ///
  /// The reachable failure is Retry Summary on a record that already has usage:
  /// the record says `$0.0031`, a second model call is in flight, and stating
  /// the first figure as settled is the "quietly understates the bill" failure
  /// `recordCost`'s own rules forbid.
  func testACostStillBeingSpentIsNeverStatedAsSettled() {
    XCTAssertEqual(RecordFacts.cost(recorded: .absent, workInFlight: false), .absent)
    XCTAssertEqual(RecordFacts.cost(recorded: .absent, workInFlight: true), .pending)
    XCTAssertEqual(
      RecordFacts.cost(recorded: .known(0.0031), workInFlight: false),
      .known(0.0031)
    )
    XCTAssertEqual(
      RecordFacts.cost(recorded: .known(0.0031), workInFlight: true),
      .note("$0.0031+"),
      "a settled figure was stated while a second billed call was running"
    )
    XCTAssertEqual(
      RecordFacts.cost(recorded: .note("included w/ subscription"), workInFlight: true),
      .note("included w/ subscription")
    )
  }

  /// The duration goes through the app's **one clock**. A second implementation
  /// of "the same instant" is a disagreement waiting for a rounding change.
  func testTheDurationIsTheOneClock() {
    for seconds in [0.0, 59.0, 61.0, 1122.0, 3599.0, 3600.0, 7325.0] {
      let facts = RecordFacts(duration: seconds)
      XCTAssertEqual(facts.text(for: .duration), LiveMeetingFormat.duration(seconds))
      XCTAssertEqual(facts.text(for: .duration), SessionTimerMetrics.text(elapsed: seconds))
    }
  }

  /// A record that keeps no audio says **nothing** about audio, and never
  /// `0 B` — which would mean a recording that exists and is empty. The two are
  /// different facts and only one of them is a size.
  func testAudioThatIsNotKeptIsNotDrawnAsZeroBytes() {
    XCTAssertNil(RecordFacts(audioBytes: nil).text(for: .audio))
    XCTAssertFalse(RecordFacts(audioBytes: nil).items.contains { $0.field == .audio })
    XCTAssertEqual(RecordFacts(audioBytes: 0).text(for: .audio), "0 B")
  }

  /// Zero moments and zero speakers are absences, not values: a strip reading
  /// "0 moments" is a fact nobody needs stated.
  func testZeroCountsAreAbsences() {
    let facts = RecordFacts(kind: .memo, speakerCount: 0, momentCount: 0)
    XCTAssertEqual(facts.stripText, "Memo")
    XCTAssertEqual(
      RecordFacts(speakerCount: 1, momentCount: 1).stripText,
      "1 speaker · 1 moment",
      "the singular is not a rounding detail on a surface read once and believed"
    )
  }

  /// A cost that is **unknown** is never a cost that is zero, and a model with
  /// no pricing renders its note rather than `$0.00` — the convention the Usage
  /// sheet and the CLI already keep.
  func testCostSaysWhatItKnowsAndNoMore() {
    XCTAssertNil(RecordFacts(cost: .absent).text(for: .cost))
    XCTAssertNil(RecordFacts(cost: .pending).text(for: .cost))
    XCTAssertEqual(RecordFacts(cost: .known(0.0031)).text(for: .cost), "$0.0031")
    XCTAssertEqual(
      RecordFacts(cost: .note("included w/ subscription")).text(for: .cost),
      "included w/ subscription"
    )
  }

  /// The record's own `usage` entries, summed the way the CLI sums them: null
  /// is **unknown**, never zero, and a partial answer carries the `+` that says
  /// "at least". A cost display that quietly understates the bill is the one
  /// failure mode it may not have.
  func testAPartlyPricedRecordSaysAtLeast() {
    XCTAssertEqual(HistoryRecordInfo.recordCost([]), .absent)
    XCTAssertEqual(
      HistoryRecordInfo.recordCost([["costUSD": 0.002], ["costUSD": 0.001]]),
      .known(0.003)
    )
    XCTAssertEqual(
      HistoryRecordInfo.recordCost([["costUSD": NSNull()], ["costUSD": NSNull()]]),
      .note("—")
    )
    XCTAssertEqual(
      HistoryRecordInfo.recordCost([["costUSD": 0.25], ["costUSD": NSNull()]]),
      .note("$0.25+")
    )
  }

  // MARK: - Still processing

  /// A fact that is coming draws a placeholder **at its final width**, so
  /// nothing reflows when it lands (rule 5). The claim is the width, and the
  /// width is the widest the field can ever be — not the width of whatever
  /// happens to arrive.
  func testAPendingFactReservesItsFinalWidth() {
    var facts = Self.full
    facts.cost = .pending
    guard let pending = facts.items.first(where: { $0.field == .cost }) else {
      return XCTFail("a pending cost produced no slot at all")
    }
    XCTAssertTrue(pending.isPending)
    XCTAssertNil(pending.text)
    XCTAssertEqual(pending.reservedWidth, RecordFacts.placeholderWidth(.cost))

    // …and it is wide enough for every answer that can land in it.
    for landed: RecordFacts.Cost in [
      .known(0.0031), .known(1234.56), .note("included w/ subscription"), .note("$0.25+"),
    ] {
      var settled = facts
      settled.cost = landed
      guard let item = settled.items.first(where: { $0.field == .cost }) else {
        return XCTFail("a settled cost produced no slot")
      }
      XCTAssertEqual(
        item.reservedWidth,
        pending.reservedWidth,
        "\(item.text ?? "") lands in a different slot than the placeholder reserved"
      )
    }
  }

  /// A fact that is simply **absent** produces no slot at all — a strip may not
  /// carry an empty gap, and a receipt may not reserve room for a number that
  /// is never coming.
  func testAnAbsentFactReservesNothing() {
    let facts = RecordFacts(duration: 90, kind: .memo, cost: .absent)
    XCTAssertEqual(facts.items.map(\.field), [.duration, .kind])
    XCTAssertFalse(facts.items.contains { $0.isPending })
  }

  // MARK: - The transition

  /// The stage that is real: the facts stagger in across 140–320ms, first
  /// fact first, and **every** fact has finished by the end of the window
  /// however many there are — a stagger whose tail depended on the field list
  /// would make a record with a cost land later than one without.
  ///
  /// These two functions are the ones `RecordReceiptView` hands to
  /// `.animation(_:value:)` as a delay and a duration, so they are what the
  /// screen does. The owner's first two stages — Mark and Stop fading and
  /// scaling, the timer capsule's width morphing into the receipt's — are
  /// **not implemented and cannot be**: XIA-435 unmounts the whole cluster on
  /// the press, seconds before the receipt is created in a different phase. A
  /// calculator for them lived here with no caller in the app and tests that
  /// drove it directly; it is deleted rather than left looking shipped.
  func testTheFactsStaggerWhereTheStagingSaysTheyDo() {
    for count in 1...6 {
      XCTAssertEqual(
        RecordReceiptTransition.factDelay(index: 0, count: count),
        RecordReceiptTransition.factsStart,
        accuracy: 0.0001,
        "the first fact did not start at 140ms"
      )
      var previous = -1.0
      for index in 0..<count {
        let delay = RecordReceiptTransition.factDelay(index: index, count: count)
        let duration = RecordReceiptTransition.factDuration(index: index, count: count)
        XCTAssertGreaterThan(delay, previous, "fact \(index) of \(count) did not follow its predecessor")
        XCTAssertGreaterThan(duration, 0, "fact \(index) of \(count) arrives instantly")
        XCTAssertLessThanOrEqual(
          delay + duration,
          RecordReceiptTransition.end + 0.0001,
          "fact \(index) of \(count) was still arriving after the transition ended"
        )
        previous = delay
      }
    }
  }

  /// **Reduce Motion is one 120ms opacity swap.** No stagger at all: every fact
  /// starts at zero and shares one duration, so the row arrives as a single
  /// change rather than as a queue.
  func testReduceMotionIsOneOpacitySwapWithNoStagger() {
    XCTAssertEqual(RecordReceiptTransition.total(reduceMotion: true), 0.120)
    for index in 0..<6 {
      XCTAssertEqual(
        RecordReceiptTransition.factDelay(index: index, count: 6, reduceMotion: true),
        0,
        "fact \(index) was staggered under Reduce Motion"
      )
      XCTAssertEqual(
        RecordReceiptTransition.factDuration(index: index, count: 6, reduceMotion: true),
        RecordReceiptTransition.reducedEnd,
        "fact \(index) took its own time under Reduce Motion"
      )
    }
  }

  // MARK: - Geometry

  /// The receipt rises in the capsule cluster's **exact footprint**, and it
  /// reserves exactly what the cluster reserved — the status line comes out of
  /// the cluster's own bottom clearance rather than being added to it, so the
  /// fact row lands on the pixels the capsules occupied.
  ///
  /// Composed from `RecordingPaneMetrics`, never typed a second time: this is
  /// the mistake XIA-444 made when `controlRowHeight` was written as 40 against
  /// a row that laid out at 41.
  func testTheReceiptReservesExactlyWhatTheClusterDid() {
    XCTAssertEqual(RecordReceiptMetrics.factRowHeight, RecordingPaneMetrics.capsuleHeight)
    XCTAssertEqual(
      RecordReceiptMetrics.totalHeight,
      RecordReceiptMetrics.factRowHeight + RecordReceiptMetrics.statusRowHeight
    )
    XCTAssertEqual(
      RecordReceiptMetrics.bottomInset + RecordReceiptMetrics.statusRowHeight,
      RecordingPaneMetrics.clusterBottomInset,
      accuracy: 0.001,
      "the status line stopped coming out of the cluster's own clearance, so the "
        + "fact row no longer lands where the capsules were"
    )
    XCTAssertEqual(
      RecordReceiptMetrics.documentBottomReserve,
      RecordingPaneMetrics.transcriptBottomReserve,
      accuracy: 0.001,
      "the receipt reserves \(RecordReceiptMetrics.documentBottomReserve)pt against the "
        + "cluster's \(RecordingPaneMetrics.transcriptBottomReserve)pt"
    )
  }

  /// **The receipt rises in the cluster's footprint, not across the pane.**
  ///
  /// It is stacked *after* the document's bottom-right Summary/Share cluster
  /// and takes hits, so a greedy row does not merely look wrong: it draws over
  /// those two controls and eats presses aimed at them for as long as a record
  /// is processing. One `.frame(maxWidth: .infinity)` on the status row was
  /// enough to do it, because a `VStack` is as wide as its widest child.
  ///
  /// Measured in a pane far wider than the receipt can want, which is the only
  /// arrangement that can see the bug — a test that pins the view at 620pt
  /// measures the width it was told to be.
  func testTheReceiptDoesNotTakeTheWholeDocumentPane() {
    let pane = CGSize(width: 900, height: 400)
    let drawn = Self.drawnSize(of: RecordReceiptView(facts: Self.full), inPane: pane)
    let ideal = NSHostingView(rootView: RecordReceiptView(facts: Self.full))
    ideal.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(drawn.width, 0, "the probe measured nothing")
    XCTAssertEqual(
      drawn.width,
      ideal.fittingSize.width,
      accuracy: 1,
      "the receipt drew \(drawn.width)pt of a \(pane.width)pt pane against its own "
        + "\(ideal.fittingSize.width)pt of content"
    )
    XCTAssertLessThan(drawn.width, pane.width * 0.9, "the receipt spans the document pane")
  }

  /// …and the laid-out receipt draws the height it reserved. A reservation is
  /// worth only what the view agrees with — which is why the view frames itself
  /// `minHeight` rather than `height`: a fixed height would impose the number
  /// this test then measures, and a status line that did not fit would be
  /// clipped instead of taking the assertion red.
  func testTheReceiptDrawsExactlyTheHeightItReserves() {
    let host = NSHostingView(
      rootView: RecordReceiptView(
        facts: Self.full,
        status: ProcessingRowStatus(text: "Summarizing…", tone: .progress, retry: nil)
      )
    )
    host.layoutSubtreeIfNeeded()
    let drawn = host.fittingSize.height
    XCTAssertGreaterThan(drawn, 0, "the hosting view produced no layout")
    XCTAssertEqual(
      drawn,
      RecordReceiptMetrics.totalHeight,
      accuracy: 0.5,
      "the receipt draws \(drawn)pt against a reservation of \(RecordReceiptMetrics.totalHeight)pt"
    )
  }

  /// **Nothing reflows when a pending fact lands.** The receipt is the
  /// processing surface, so the one thing it may not do is change size under
  /// the owner while a stage completes.
  func testAPendingCostLandingDoesNotResizeTheReceipt() {
    func size(_ cost: RecordFacts.Cost) -> CGSize {
      var facts = Self.full
      facts.cost = cost
      let host = NSHostingView(rootView: RecordReceiptView(facts: facts))
      host.layoutSubtreeIfNeeded()
      return host.fittingSize
    }
    let pending = size(.pending)
    let landed = size(.known(0.0031))
    XCTAssertGreaterThan(pending.width, 0, "the hosting view produced no layout")
    XCTAssertEqual(pending.height, landed.height, accuracy: 0.5, "the receipt changed height")
    XCTAssertEqual(
      pending.width,
      landed.width,
      accuracy: 0.5,
      "the receipt was \(pending.width)pt while the cost was pending and \(landed.width)pt "
        + "once it landed — the placeholder is not at the final width"
    )
  }

  /// The receipt draws **no ember**. The microphone is closed by the time one
  /// exists, and `CraftTokens.ember` means exactly one thing: it is open. The
  /// meter is dead by then too, and a receipt is not a recording surface.
  ///
  /// Pixels, because "there is no ember on screen" is not a claim a constant
  /// can carry — the same probe `testTheIdlePaneDrawsNoEmber` uses.
  /// It runs through `RenderProbe.emberPixels` — the repo's own probe, which
  /// derives its target from `CraftTokens.ember` rather than from hardcoded
  /// sRGB triples that would stop naming the ember the day it is retuned — and
  /// it carries a **positive control**, without which "no ember found" and "the
  /// probe found nothing at all" are the same green.
  func testTheReceiptDrawsNoEmber() {
    let size = CGSize(width: 620, height: 120)
    guard let control = RenderProbe.bitmap(
      ZStack {
        Color.white
        SessionRing(diameter: 80, lineWidth: 6)
      }
      .environment(\.colorScheme, .light),
      size: size
    ) else {
      return XCTFail("the probe produced no bitmap for its own control")
    }
    XCTAssertGreaterThan(
      RenderProbe.emberPixels(control, scheme: .light),
      0,
      "the probe cannot see the ember it is looking for; the assertion below would "
        + "pass against a blank canvas"
    )

    guard let image = RenderProbe.bitmap(
      ZStack {
        Color.white
        RecordReceiptView(facts: Self.full)
      }
      .environment(\.colorScheme, .light),
      size: size
    ) else {
      return XCTFail("the receipt produced no bitmap")
    }
    XCTAssertEqual(
      RenderProbe.emberPixels(image, scheme: .light),
      0,
      "the receipt drew the ember; the microphone is closed by the time it exists"
    )
  }

  /// **The reserve comes off the scroll view's own frame.**
  ///
  /// The repo has been here before: `testTheTranscriptReservesTheClustersWholeFootprint`
  /// exists because scroll *content* padding satisfies every adjacent
  /// assertion while the newest line still comes to rest behind the glass —
  /// `scrollTo(anchor: .bottom)` aligns against the visible region, which
  /// content padding does not move. So the claim is measured on the backing
  /// `NSScrollView`, not on a constant beside it.
  func testTheTranscriptReservesTheReceiptsFootprintOnItsOwnFrame() {
    let pane = CGSize(width: 620, height: 400)
    let body = NSAttributedString(string: String(repeating: "a line of transcript\n", count: 80))
    func scrollHeight(reserve: CGFloat) -> CGFloat? {
      let host = NSHostingView(
        rootView: RichTextViewer(attributedString: body).padding(.bottom, reserve)
      )
      host.frame = NSRect(origin: .zero, size: pane)
      host.layoutSubtreeIfNeeded()
      return Self.firstScrollView(in: host)?.frame.height
    }
    guard let full = scrollHeight(reserve: 0),
          let reserved = scrollHeight(reserve: RecordReceiptMetrics.documentBottomReserve)
    else {
      return XCTFail("no NSScrollView was laid out")
    }
    XCTAssertEqual(full, pane.height, accuracy: 1)
    XCTAssertEqual(
      reserved,
      pane.height - RecordReceiptMetrics.documentBottomReserve,
      accuracy: 1,
      "the reserve did not come off the scroll view's frame — \(reserved)pt of \(full)pt"
    )
  }

  // MARK: - Moment pips

  /// A marker belongs to the **last line that had already started** when it was
  /// flagged, because the exported `.md` prints each segment's start. That is
  /// deliberately not the live surface's rule (first line whose end ≥ t), and
  /// they disagree at boundaries: each is right about the document it reads.
  func testAMarkerLandsOnTheLastLineThatHadStarted() {
    let starts: [TimeInterval] = [0, 10, 20, 30]
    XCTAssertEqual(TranscriptMarkerGutter.markedLines(markerSeconds: [15], lineStarts: starts), [1])
    XCTAssertEqual(TranscriptMarkerGutter.markedLines(markerSeconds: [20], lineStarts: starts), [2])
    XCTAssertEqual(TranscriptMarkerGutter.markedLines(markerSeconds: [99], lineStarts: starts), [3])
    // Flagged before the first line still has one: the alternative is a moment
    // the owner flagged that the document refuses to admit exists.
    XCTAssertEqual(TranscriptMarkerGutter.markedLines(markerSeconds: [-5], lineStarts: starts), [0])
    // Two moments inside one line draw one pip — there is no second place to
    // put the second one.
    XCTAssertEqual(
      TranscriptMarkerGutter.markedLines(markerSeconds: [11, 12, 25], lineStarts: starts),
      [1, 2]
    )
    XCTAssertEqual(TranscriptMarkerGutter.markedLines(markerSeconds: [5], lineStarts: []), [])
  }

  /// "N moments" walks the pips and **wraps**. The strip says how many there
  /// are, so a press that did nothing on the last one would read as a broken
  /// count.
  func testTheMomentsButtonWalksThePipsAndWraps() {
    let marked = [1, 4, 9]
    XCTAssertEqual(TranscriptMarkerGutter.nextLine(after: nil, marked: marked), 1)
    XCTAssertEqual(TranscriptMarkerGutter.nextLine(after: 1, marked: marked), 4)
    XCTAssertEqual(TranscriptMarkerGutter.nextLine(after: 4, marked: marked), 9)
    XCTAssertEqual(TranscriptMarkerGutter.nextLine(after: 9, marked: marked), 1)
    XCTAssertNil(TranscriptMarkerGutter.nextLine(after: nil, marked: []))
  }

  /// The pip's seconds come off the **same capture** the gutter's label does,
  /// as a number the renderer attached — never parsed back out of the display
  /// string at draw time.
  func testTheRendererCarriesTheTimestampAsANumberBesideTheLabel() {
    XCTAssertEqual(timestampSeconds("0:51"), 51)
    XCTAssertEqual(timestampSeconds("01:02:03"), 3723)

    let body = renderMarkdownAsRichText("[01:05] **Alice:** hello\n[02:00] and again\n", sections: .whole)
    var found: [(String, TimeInterval)] = []
    body.enumerateAttribute(.notaTimestamp, in: NSRange(location: 0, length: body.length)) {
      value, range, _ in
      guard let label = value as? String else { return }
      let seconds = body.attribute(.notaTimestampSeconds, at: range.location, effectiveRange: nil)
      found.append((label, (seconds as? NSNumber)?.doubleValue ?? -1))
    }
    XCTAssertEqual(found.map(\.0), ["1:05", "2:00"])
    XCTAssertEqual(found.map(\.1), [65, 120], "the numeric half disagrees with the label")
  }

  // MARK: - One duration per surface

  /// **The Details panel states the length once.** The exported markdown's
  /// `**Duration:**` line is rounded UP to whole minutes by the writer, while
  /// the fact strip reads `durationSeconds` — so drawing both put "May 20 ·
  /// 19 min" four points above "18:42 · Meeting · 3 speakers", inside a single
  /// surface, on the one feature chosen so the moment and the document could
  /// not disagree about how long the recording was.
  ///
  /// The surface has moved twice — header, info card, now the panel — and the
  /// rule never moved with it, which is why it lives on `DocMeta`.
  func testTheDetailsPanelNeverStatesTheDurationTwice() {
    let markdown = """
      # Standup
      **Captured:** 2026-05-20
      **Duration:** 19 minutes

      ## Summary
      """
    guard let meta = parseDocumentMeta(markdown) else {
      return XCTFail("the header did not parse")
    }
    XCTAssertEqual(meta.dateText, "May 20")
    XCTAssertEqual(meta.durationText, "19 min")

    // With a strip: the date only, and the strip says 18:42.
    let facts = RecordFacts(duration: 1122, kind: .meeting, speakerCount: 3)
    XCTAssertEqual(meta.subtitle(facts: facts), "May 20")
    XCTAssertFalse(
      meta.subtitle(facts: facts).contains("min"),
      "the panel states the length twice, in two roundings"
    )

    // Without one — an imported `.md` with no record — the parsed figure is the
    // only duration the document has, so it stays.
    XCTAssertEqual(meta.subtitle(facts: nil), "May 20 · 19 min")
    XCTAssertEqual(
      meta.subtitle(facts: RecordFacts(kind: .file)),
      "May 20 · 19 min",
      "a strip with no duration in it is not a reason to drop the only one there is"
    )
  }

  // MARK: - Kind relabeling

  /// The submenu offers all three kinds and refuses the one the record already
  /// has — choosing it would set `summaryOutdated` for a write that changed
  /// nothing, i.e. a stale banner earned by a no-op.
  func testTheKindSubmenuOffersEveryKindAndRefusesTheCurrentOne() {
    XCTAssertEqual(RecordKindMenuItems.choices, [.meeting, .memo, .file])
    for kind in RecordKindMenuItems.choices {
      XCTAssertFalse(RecordFactsCopy.kind(kind).isEmpty)
    }
    // The refusal itself, through the function the `.disabled` modifier reads —
    // an accessibility tree is not published for a hosting view in this bundle,
    // so a pure rule is the only form of this claim a test can hold.
    for current in RecordKindMenuItems.choices {
      for kind in RecordKindMenuItems.choices {
        XCTAssertEqual(
          RecordKindMenuItems.isEnabled(kind, current: current, isBusy: false),
          kind != current,
          "choosing the kind a record already has would set summaryOutdated for a no-op"
        )
      }
    }
  }

  /// **A relabel is refused while the record is being written to.**
  ///
  /// `setKind` is a read-modify-write of the whole record JSON, and
  /// `nota history summarize` writes the same file from another process — so a
  /// relabel during the window Stop opens can read the pre-summary JSON and put
  /// it back after the CLI landed, taking the summary and the `done` status
  /// with it. The row's own `.disabled(model.isRunning)` is about a *file*
  /// transcription and says nothing about that window.
  func testTheKindSubmenuIsRefusedWhileTheRecordIsBeingWorkedOn() {
    for kind in RecordKindMenuItems.choices {
      XCTAssertFalse(
        RecordKindMenuItems.isEnabled(kind, current: .memo, isBusy: true),
        "a relabel was offered while a summary was writing the same record"
      )
    }
  }

  /// Relabeling writes the record and marks the summary outdated — and
  /// **nothing else**. It does not re-summarize (a model call spent on a
  /// mis-click in a context menu), and it does not touch the transcript, the
  /// tags, the markers or any other key.
  func testRelabelingTheKindMarksTheSummaryStaleAndRunsNothing() throws {
    let dir = try Self.temporaryHistory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let output = dir.appendingPathComponent("meeting.summary.md").path
    let record: [String: Any] = [
      "id": "rec-1",
      "outputPath": output,
      "kind": "memo",
      "summary": "a narrative",
      "tags": ["one", "two"],
      "transcriptText": "hello",
      "status": "done",
    ]
    try Self.write(record, id: "rec-1", in: dir)

    HistoryRecordInfo.setKind(.meeting, outputPath: output, historyDir: dir)
    let updated = try Self.read(id: "rec-1", in: dir)
    XCTAssertEqual(updated["kind"] as? String, "meeting")
    XCTAssertEqual(updated["summaryOutdated"] as? Bool, true)
    XCTAssertEqual(updated["summary"] as? String, "a narrative", "the summary was touched")
    XCTAssertEqual(updated["tags"] as? [String], ["one", "two"], "the tags were touched")
    XCTAssertEqual(updated["transcriptText"] as? String, "hello")
    XCTAssertEqual(updated["status"] as? String, "done", "the relabel moved the lifecycle status")
  }

  /// Only a record that HAS a summary can have a stale one. Marking a
  /// transcript-only record outdated would put a "Regenerate Summary" banner on
  /// a document that has never had one.
  func testRelabelingATranscriptOnlyRecordMarksNothingStale() throws {
    let dir = try Self.temporaryHistory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let output = dir.appendingPathComponent("memo.summary.md").path
    try Self.write(
      ["id": "rec-2", "outputPath": output, "kind": "meeting", "status": "transcribed"],
      id: "rec-2",
      in: dir
    )
    HistoryRecordInfo.setKind(.memo, outputPath: output, historyDir: dir)
    let updated = try Self.read(id: "rec-2", in: dir)
    XCTAssertEqual(updated["kind"] as? String, "memo")
    XCTAssertNil(updated["summaryOutdated"])
  }

  // MARK: - Reading a record's facts back

  /// The scan that feeds both renderings reads every field the strip states,
  /// and **prefers the seconds over the rounded minutes**: a receipt reading
  /// 19:00 for a session whose clock ended on 18:42 would flicker the one
  /// number on screen that did not change.
  func testTheRecordScanCarriesEveryFactAndPrefersSeconds() throws {
    let dir = try Self.temporaryHistory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let output = dir.appendingPathComponent("m.summary.md").path
    try Self.write([
      "id": "rec-3",
      "outputPath": output,
      "kind": "meeting",
      "status": "done",
      "durationMinutes": 19,
      "durationSeconds": 1122,
      "audioBytes": 18_400_000,
      "markers": [["atSeconds": 300.0], ["atSeconds": 61.0]],
      "segments": [["speaker": "Alice"], ["speaker": "Bob"], ["speaker": "Alice"]],
      "usage": [["costUSD": 0.0031]],
    ], id: "rec-3", in: dir)

    let key = URL(fileURLWithPath: output).standardizedFileURL.path
    guard let detail = HistoryRecordInfo.detailsByOutputPath(historyDir: dir)[key] else {
      return XCTFail("the record did not appear in the scan")
    }
    XCTAssertEqual(detail.durationSeconds, 1122)
    XCTAssertEqual(detail.speakerCount, 2)
    XCTAssertEqual(detail.momentSeconds, [61, 300], "moments are not oldest-first")
    XCTAssertEqual(detail.audioBytes, 18_400_000)
    XCTAssertEqual(detail.cost, .known(0.0031))
    XCTAssertEqual(detail.kind, .meeting)
  }

  /// A record written before `durationSeconds` existed still has a duration:
  /// the rounded minutes are the fallback, never nothing.
  func testALegacyRecordFallsBackToTheRoundedMinutes() throws {
    let dir = try Self.temporaryHistory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let output = dir.appendingPathComponent("legacy.summary.md").path
    try Self.write(
      ["id": "rec-4", "outputPath": output, "durationMinutes": 7, "status": "done"],
      id: "rec-4",
      in: dir
    )
    let key = URL(fileURLWithPath: output).standardizedFileURL.path
    let detail = HistoryRecordInfo.detailsByOutputPath(historyDir: dir)[key]
    XCTAssertEqual(detail?.durationSeconds, 420)
    XCTAssertNil(detail?.audioBytes, "a record with no audioBytes must not read as 0 B")
    XCTAssertEqual(detail?.cost, .absent)
    XCTAssertEqual(detail?.momentSeconds, [])
  }

  /// **The pips are really drawn, and the button really moves.** Everything
  /// above this is arithmetic; a gutter x computed outside the view's bounds,
  /// a y misplaced by an inset, or a `draw(_:)` that returned early would leave
  /// all of it green while the strip advertised "4 moments" and nothing was
  /// ever marked.
  ///
  /// With a negative control, because "no pip pixel found" and "the probe found
  /// nothing at all" are otherwise the same green.
  func testTheGutterDrawsAPipAndTheButtonWalksToIt() {
    func textView(markers: [TimeInterval]) -> HoverTimestampTextView {
      let view = HoverTimestampTextView(frame: NSRect(x: 0, y: 0, width: 620, height: 400))
      let body = renderMarkdownAsRichText(
        (0..<40).map { "[00:\(String(format: "%02d", $0))] **Alice:** line \($0)" }
          .joined(separator: "\n") + "\n"
      , sections: .whole)
      view.textStorage?.setAttributedString(body)
      view.markerSeconds = markers
      // The gutter is the text container's inset (XIA-441 centres the reading
      // column by growing it), so the pip has nowhere to land until the column
      // is applied. A bare NSTextView insets by zero and the pip drew at a
      // negative x — off the left edge, invisible, in a test that had been
      // asserting it was there.
      RichTextViewer.layout(view, in: view.bounds.width)
      view.layoutManager?.ensureLayout(for: view.textContainer!)
      return view
    }

    let marked = textView(markers: [5, 20])
    XCTAssertTrue(marked.revealNextMarker(), "the moments button had no pip to reach")
    XCTAssertTrue(marked.revealNextMarker(), "the second press did not move on")
    XCTAssertFalse(
      textView(markers: []).revealNextMarker(),
      "a document with no moments answered a press it cannot honour"
    )

    // …and the gutter really has pips in it, **asserted as geometry rather than
    // as pixels** (changed 2026-08-16, XIA-441).
    //
    // The pixel version could not see a pip and never could: measured, a
    // `cacheDisplay` bitmap of an unhosted `NSTextView` contains none of this
    // view's custom `draw(_:)` output — a solid red fill in the pip loop
    // produces **zero** differing pixels. What it was really reading is one
    // frame to the side: `revealNextMarker` above scrolls `marked` and nothing
    // scrolls `bare`, so the two bitmaps differed wherever the text moved. It
    // stayed green against a pip drawn at x = -13, off the left edge, which is
    // exactly what the reading column's growing inset produced before
    // `pipRects` started reading the inset instead of the constant.
    //
    // `pipRects()` is what `draw(_:)` fills, so this is the drawn value and not
    // a second copy of the arithmetic.
    let pips = marked.pipRects()
    XCTAssertEqual(pips.count, 2, "the strip advertises 2 moments and the gutter marks \(pips.count)")
    for (index, pip) in pips.enumerated() {
      XCTAssertGreaterThanOrEqual(pip.minX, 0, "pip \(index) is off the left edge at \(pip.minX)")
      XCTAssertLessThanOrEqual(
        pip.maxX, marked.textContainerInset.width,
        "pip \(index) runs past the gutter into the text at \(pip.maxX)")
      // Beside its OWN line, not merely somewhere in the gutter.
      guard let line = marked.lineFragmentForPip(at: index) else {
        return XCTFail("pip \(index) belongs to no line")
      }
      XCTAssertGreaterThanOrEqual(pip.midY, line.minY)
      XCTAssertLessThanOrEqual(pip.midY, line.maxY)
    }
    // The negative control, and it is a real one now: a document with no
    // moments produces no pips at all, so the two above are the markers rather
    // than something the view draws regardless.
    XCTAssertEqual(
      textView(markers: []).pipRects(), [],
      "a document with no moments still drew pips")
  }

  // MARK: - Fixtures

  /// A UI source file, found relative to this test's own path. The test target
  /// copies no resources, so a bundle lookup would silently resolve to nil.
  private static func uiSource(_ name: String) -> String {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent(name)
    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    XCTAssertFalse(text.isEmpty, "could not read \(name) beside this test")
    return text
  }

  private static let full = RecordFacts(
    duration: 1122,
    kind: .meeting,
    speakerCount: 3,
    momentCount: 4,
    audioBytes: 18_400_000,
    cost: .known(0.0031)
  )

  private static func temporaryHistory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("xia429-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private static func write(_ record: [String: Any], id: String, in dir: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted])
    try data.write(to: dir.appendingPathComponent("\(id).json"))
  }

  private static func read(id: String, in dir: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: dir.appendingPathComponent("\(id).json"))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  /// The first `NSScrollView` anywhere under `view`, so a claim about the
  /// backing scroll view's frame can be made about a SwiftUI hierarchy.
  private static func firstScrollView(in view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    for subview in view.subviews {
      if let found = firstScrollView(in: subview) { return found }
    }
    return nil
  }


  /// The size a view really takes when a **pane** of `pane` is proposed to it.
  ///
  /// `fittingSize` answers "how big does it want to be", which is exactly the
  /// question a greedy `maxWidth: .infinity` still answers modestly — so it
  /// could not see the receipt spanning the document. A `GeometryReader` in the
  /// background reports what the view was actually laid out at.
  private static func drawnSize<V: View>(of view: V, inPane pane: CGSize) -> CGSize {
    let box = SizeBox()
    let host = NSHostingView(
      rootView: view
        .background(GeometryReader { proxy in recordLaidOutSize(proxy.size, into: box) })
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    )
    host.frame = NSRect(origin: .zero, size: pane)
    host.layoutSubtreeIfNeeded()
    return box.size
  }
}

/// A box a `GeometryReader` can report into during layout, so a test can ask
/// "how wide was this view actually laid out" rather than "how wide would it
/// like to be" — the two differ exactly when a view is greedy, which is the
/// bug the receipt had.
final class SizeBox {
  var size: CGSize = .zero
}

func recordLaidOutSize(_ size: CGSize, into box: SizeBox) -> Color {
  box.size = size
  return .clear
}
