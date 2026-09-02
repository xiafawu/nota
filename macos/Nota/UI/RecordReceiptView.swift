import AppKit
import SwiftUI

// MARK: - Geometry

/// What the receipt is allowed to occupy, derived from the cluster it replaces.
///
/// The receipt rises **in the capsule cluster's exact footprint** (XIA-429
/// option B), which is a claim about numbers and so is composed from
/// `RecordingPaneMetrics` rather than typed a second time — the precedent
/// `transcriptBottomReserve` set, and the mistake XIA-444 made when
/// `controlRowHeight` was written as 40 against a row that laid out at 41.
///
/// The one thing the receipt has that the cluster did not is a **status line**
/// (the receipt is the processing surface — rule 5). It is drawn as a second
/// row *under* the facts, and the height it takes comes out of the cluster's
/// own bottom clearance rather than being added to it: the fact row therefore
/// lands on exactly the pixels the capsules occupied, and the whole receipt
/// reserves exactly what the cluster reserved. That equality is asserted, not
/// hoped for (`testTheReceiptReservesExactlyWhatTheClusterDid`).
///
/// The status row is reserved **always**, drawn empty when there is nothing to
/// say, for the same reason the pending facts are drawn at their final widths:
/// a surface the owner is reading may not resize under them when a stage lands.
enum RecordReceiptMetrics {
  /// The facts row: the cluster's capsule height, exactly.
  static let factRowHeight: CGFloat = RecordingPaneMetrics.capsuleHeight

  /// The status line's own line box, **measured** from the face it is drawn in
  /// (`.caption2`, the face `ProcessingRowLine` uses) rather than typed.
  ///
  /// Measured as a **laid-out line height** (`NSLayoutManager`) off the system's
  /// own `.caption2` face, not as a glyph bounding box off a hand-guessed point
  /// size. A bare glyph height is smaller than the line box SwiftUI gives the
  /// same text, and the two rows below are `minHeight` rather than `height` for
  /// the same reason: a status line that did not fit would then make the receipt
  /// taller and take the geometry test red, instead of being silently clipped
  /// behind a reservation that measured itself.
  static let statusRowHeight: CGFloat = {
    let font = NSFont.preferredFont(forTextStyle: .caption2)
    return NSLayoutManager().defaultLineHeight(for: font).rounded(.up)
  }()

  static let totalHeight: CGFloat = factRowHeight + statusRowHeight

  /// Clearance from the bottom of the pane. The cluster's clearance, less the
  /// status row that now lives inside it — which is what puts the fact row back
  /// on the cluster's own pixels.
  static let bottomInset: CGFloat = max(
    0,
    RecordingPaneMetrics.clusterBottomInset - statusRowHeight
  )

  /// Inside the glass, left and right. The timer capsule's, so the clock starts
  /// where the clock started.
  static let paddingH: CGFloat = RecordingPaneMetrics.timerPaddingH

  /// Between the clock and the first fact, and between two facts.
  static let factGap: CGFloat = CraftTokens.spacing12

  /// What a document showing a receipt owes it: the whole footprint, so no line
  /// of transcript comes to rest behind glass. Equal to the cluster's reserve
  /// by construction.
  static let documentBottomReserve: CGFloat =
    totalHeight + bottomInset + RecordingPaneMetrics.clusterTranscriptGap
}

// MARK: - The transition

/// Stop → receipt, as arithmetic — **the part of it that can actually run.**
///
/// The owner's staging was: 0–120ms Mark and Stop fade and scale to 0.92 while
/// the meter goes to zero width; at 120ms the *timer capsule stays* and
/// animates its width into the receipt's, so `18:42` is one surviving glyph
/// run; 140–320ms the remaining facts stagger in.
///
/// **The first two stages are not implementable on this architecture, and
/// pretending otherwise in code was worse than not having them.** XIA-435 sets
/// `isLiveSessionHandedOff` on the press *before any await*, so `LiveMeetingView`
/// and its `SessionCapsuleCluster` — Mark, Stop, the meter and the timer capsule
/// — are unmounted the instant Stop is pressed. The receipt is a different view
/// in a different `ContentView` phase, created seconds later when the seal lands
/// and the record's details have been rescanned. There is no shared container to
/// stage inside and no capsule left to keep: the clock is necessarily
/// re-created, not carried. A `controlOpacity`/`controlScale`/`meterWidthFraction`/
/// `widthProgress` calculator existed here with **no caller anywhere in the app**,
/// asserted by tests that drove it directly — arithmetic that read as a shipped
/// transition and was not one. It is gone rather than left to look implemented.
///
/// What survives is the stage that is real and is drawn: the receipt's facts
/// **stagger in over 140–320ms**, oldest fact first, and under **Reduce Motion**
/// the whole thing collapses to one 120ms opacity swap with no stagger at all.
/// Both are consumed by `RecordReceiptView` — `factDelay` becomes an animation
/// delay and `factDuration` its duration — so the numbers below are what the
/// screen does.
///
/// Pure, so they are asserted without a window server: the split
/// `SessionTimerMetrics` and `HUDPrompterMetrics` already established.
enum RecordReceiptTransition {
  static let factsStart: Double = 0.140
  static let end: Double = 0.320
  /// Reduce Motion: one opacity swap, and it is over.
  static let reducedEnd: Double = 0.120

  static func total(reduceMotion: Bool) -> Double {
    reduceMotion ? reducedEnd : end
  }

  /// When a fact begins to arrive, relative to the receipt appearing.
  ///
  /// The facts share the window 140–320ms and overlap by half a slice, so the
  /// row reads as one arrival rather than as a queue — and every fact finishes
  /// **by `end`** however many there are, so a record with a cost does not land
  /// later than one without.
  ///
  /// Under Reduce Motion every fact starts at zero: no stagger, one swap.
  static func factDelay(index: Int, count: Int, reduceMotion: Bool = false) -> Double {
    guard !reduceMotion, count > 1, index > 0 else { return reduceMotion ? 0 : factsStart }
    let span = end - factsStart
    let slice = span / Double(count)
    return factsStart + slice * Double(index) * 0.5
  }

  /// How long one fact takes to arrive once it starts.
  static func factDuration(index: Int, count: Int, reduceMotion: Bool = false) -> Double {
    guard !reduceMotion else { return reducedEnd }
    guard count > 0 else { return 0 }
    let slice = (end - factsStart) / Double(count)
    return min(end - factDelay(index: index, count: count), slice)
  }
}

// MARK: - The receipt

/// What Stop looks like (XIA-429).
///
/// One Liquid Glass panel where the capsule cluster was, holding the same
/// `RecordFacts` the document header will carry forever after — so the moment
/// and the document cannot disagree about what was recorded. It is also the
/// **processing surface**: facts that are not known yet draw dimmed
/// placeholders at their final widths, and the stage line rides the second row.
///
/// It draws **no ember and no meter**. The microphone is closed by the time a
/// receipt exists, and `CraftTokens.ember` means exactly one thing.
///
/// SwiftUI `.glassEffect` via `craftGlassPanel` is correct here: this is inside
/// the main window and the field it refracts is in its own hierarchy. The
/// AppKit `NSGlassEffectView` rule is about floating `NSPanel`s.
struct RecordReceiptView: View {
  let facts: RecordFacts
  /// The stage line — the same value `ProcessingRowLine` draws in the drawer
  /// row. The *value* is shared, not the view: the row's `.caption2`/leading/
  /// `.infinity` framing is shaped for a drawer row.
  var status: ProcessingRowStatus?
  var onRetry: (() -> Void)?
  /// Scroll the transcript to the next moment pip, if there are pips.
  var onNextMoment: (() -> Void)?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Drives the stagger. One value, because there is one authority for this
  /// animation — the same rule the HUD pill's window frame keeps.
  @State private var arrived = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      factRow
      statusRow
    }
    .padding(.horizontal, RecordReceiptMetrics.paddingH)
    // `minHeight`, not `height`: a fixed height would *impose* the reservation
    // on the content and silently clip a status line that did not fit, while
    // the geometry test measured the constant it had just asserted. Growing
    // instead is what makes that test able to fail.
    .frame(minHeight: RecordReceiptMetrics.totalHeight)
    // …and deliberately NOT `maxWidth: .infinity`. The receipt rises in the
    // capsule cluster's footprint; a greedy row would take the whole document
    // pane, put the clock at the far-left edge instead of on the pixels the
    // timer capsule occupied, and — being stacked after `localCluster` — draw
    // over Summary and Share and eat presses aimed at them.
    .fixedSize(horizontal: true, vertical: false)
    .craftGlassPanel(in: Capsule(style: .continuous))
    .onAppear { arrived = true }
    .accessibilityElement(children: .contain)
    // What this surface *is*, not what produced it. It is up whenever the open
    // document's record has work in flight — including a Retry pressed on a
    // six-month-old meeting — so "Recording finished" would be a claim about a
    // session that ended in February.
    .accessibilityLabel(status?.text ?? RecordFactsCopy.receiptLabel)
  }

  /// The clock is drawn by `SessionTimer` — the same view the timer capsule
  /// held — so it is the app's one clock rather than a second spelling of it.
  /// `testTheDurationIsTheOneClock` pins the two to the same function.
  private var factRow: some View {
    HStack(spacing: RecordReceiptMetrics.factGap) {
      if let duration = facts.duration {
        SessionTimer(elapsed: duration, base: RecordingPaneMetrics.clockBase)
      }
      ForEach(Array(Self.trailingItems(facts).enumerated()), id: \.element.id) { index, item in
        fact(item, index: index, count: Self.trailingItems(facts).count)
      }
    }
    .frame(minHeight: RecordReceiptMetrics.factRowHeight)
  }

  /// Everything except the duration, which the clock already drew — i.e.
  /// exactly what this view puts on screen beside the clock, in `RecordFacts`'
  /// own order. Static and internal so a test compares the *drawn* list against
  /// the strip's, rather than comparing a model against itself.
  static func trailingItems(_ facts: RecordFacts) -> [RecordFactItem] {
    facts.items.filter { $0.field != .duration }
  }

  @ViewBuilder
  private func fact(_ item: RecordFactItem, index: Int, count: Int) -> some View {
    Group {
      if let text = item.text {
        if item.field == .moments, let onNextMoment {
          Button(action: onNextMoment) {
            Text(text).font(.system(size: RecordFacts.factFontSize)).underline()
          }
          .buttonStyle(.plain)
          .foregroundStyle(.white.opacity(0.85))
          .help(RecordFactsCopy.momentsAccessibilityHint)
        } else {
          Text(text)
            .font(.system(size: RecordFacts.factFontSize))
            .foregroundStyle(.white.opacity(0.85))
        }
      } else {
        // A fact that is coming: its final width, dimmed, so nothing reflows
        // when it lands.
        Capsule()
          .fill(.white.opacity(0.12))
          .frame(width: item.reservedWidth, height: RecordFacts.factFontSize)
          .accessibilityHidden(true)
      }
    }
    // `reservedWidth`, not `width`: a cost slot is the same size before and
    // after the figure lands, which is what "at their final widths so nothing
    // reflows" means for a value whose final spelling is not known in advance.
    .frame(minWidth: item.reservedWidth, alignment: .leading)
    // The stagger, as the screen does it: each fact's own delay and duration,
    // from the one pure calculator. Under Reduce Motion every delay is 0 and
    // every duration is the single 120ms swap, so the row arrives at once.
    .opacity(arrived ? 1 : 0)
    .animation(
      .easeOut(
        duration: RecordReceiptTransition.factDuration(
          index: index,
          count: max(1, count),
          reduceMotion: reduceMotion
        )
      )
      .delay(
        RecordReceiptTransition.factDelay(
          index: index,
          count: max(1, count),
          reduceMotion: reduceMotion
        )
      ),
      value: arrived
    )
  }

  /// The stage line, and on failure the Retry that replaces it.
  private var statusRow: some View {
    HStack(spacing: 6) {
      if let status {
        Text(status.text)
          .font(.caption2)
          .foregroundStyle(status.tone == .failure ? CraftTokens.failure : Color.white.opacity(0.6))
          .lineLimit(1)
          .truncationMode(.tail)
        if status.retry == .summary, let onRetry {
          // Manual, always. Nothing on this path re-runs a summary on its own.
          Button("Retry summary", action: onRetry)
            .font(.caption2)
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
      }
    }
    // No `maxWidth: .infinity` — that one modifier is what made the whole
    // receipt greedy, since a `VStack`'s width is its widest child's.
    .frame(minHeight: RecordReceiptMetrics.statusRowHeight, alignment: .leading)
  }
}

// MARK: - When a receipt is up

/// The one place that decides whether a receipt exists, and the only thing in
/// the document pane that observes the ledger.
///
/// **The receipt IS the processing surface** (XIA-429 rule 5): it is on screen
/// exactly while this document's record is still being worked on, and it goes
/// when the work lands — the facts it stated do not go with it, they are in the
/// header's strip, drawn from the same `RecordFacts`.
///
/// It observes `ProcessingLedger` **here** rather than in `MainPaneView`, and
/// that is the XIA-432 trap written down: the ledger ticks once a second and
/// the pane is the whole document, so the rate of a publisher and the breadth
/// of its observers would multiply. What crosses back out to the pane is one
/// Bool — "reserve the footprint" — which changes at most twice a session.
struct RecordReceiptSlot: View {
  let facts: RecordFacts
  /// The document's own `.summary.md` path: the join between a row and a job.
  let outputPath: String
  let onRetry: () -> Void
  var onNextMoment: (() -> Void)?
  /// Told whenever a receipt appears or disappears, so the transcript can
  /// reserve the footprint while one is up and nothing while none is.
  let onVisibilityChange: (Bool) -> Void

  @ObservedObject private var ledger = ProcessingLedger.shared

  init(
    facts: RecordFacts,
    outputPath: String,
    onRetry: @escaping () -> Void,
    onNextMoment: (() -> Void)? = nil,
    onVisibilityChange: @escaping (Bool) -> Void
  ) {
    self.facts = facts
    self.outputPath = outputPath
    self.onRetry = onRetry
    self.onNextMoment = onNextMoment
    self.onVisibilityChange = onVisibilityChange
  }

  private var status: ProcessingRowStatus? {
    guard let job = ledger.job(outputPath: outputPath) else { return nil }
    return ProcessingRowStatus.make(job: job, now: ledger.tick)
  }

  var body: some View {
    Group {
      if let status {
        RecordReceiptView(
          facts: facts,
          status: status,
          onRetry: onRetry,
          onNextMoment: onNextMoment
        )
        .transition(.opacity)
        .onAppear { onVisibilityChange(true) }
        .onDisappear { onVisibilityChange(false) }
      }
    }
    .animation(Tokens.animFast, value: status == nil)
  }
}

#if DEBUG
#Preview("receipt – processing") {
  RecordReceiptView(
    facts: RecordFacts(
      duration: 1122,
      kind: .meeting,
      speakerCount: 3,
      momentCount: 4,
      audioBytes: 18_400_000,
      cost: .pending
    )
  )
  .padding(40)
  .frame(width: 720)
}

#Preview("receipt – landed") {
  RecordReceiptView(
    facts: RecordFacts(
      duration: 1122,
      kind: .memo,
      speakerCount: 1,
      momentCount: 0,
      audioBytes: 2_400_000,
      cost: .known(0.0031)
    )
  )
  .padding(40)
  .frame(width: 720)
}
#endif
