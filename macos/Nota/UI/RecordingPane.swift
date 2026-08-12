import AppKit
import SwiftUI

// MARK: - Metrics

/// Everything about the recording surface that is arithmetic, kept out of the
/// views for the reason `SessionTimerMetrics` and `HUDPrompterMetrics` are: a
/// test can then answer "how tall is a capsule" without a window server.
enum RecordingPaneMetrics {
  // MARK: The capsule cluster

  /// Three sibling capsules — timer, Mark, Stop — floating over the transcript
  /// at the bottom of the window (XIA-445). They replaced the full-width bar
  /// XIA-444 shipped, which had replaced a 288pt trailing column.
  ///
  /// The bar was measured and rejected: it still charged the transcript a whole
  /// band of every window for an indicator that is a clock, a meter and two
  /// buttons wide, and it grew that band on hover. A cluster charges the
  /// transcript nothing at all — it floats over it — and the transcript reserves
  /// exactly the cluster's footprint at the bottom so no line ever comes to rest
  /// under glass (`transcriptBottomReserve`).
  ///
  /// They are **siblings**, never nested. Apple's guidance is that Liquid Glass
  /// inside Liquid Glass is silently auto-converted to a vibrant fill, so a
  /// capsule drawn inside a capsule is not doubled — it is quietly overridden,
  /// which is a failure nothing on screen announces. One `GlassEffectContainer`
  /// holds the three so their lensing merges rather than refracting three times.
  ///
  /// It is a SwiftUI `.glassEffect` here, via `craftGlassPanel`, and that is not
  /// a contradiction of the HUD's rule. That rule is about an `NSPanel`: SwiftUI
  /// glass refracts only its own hierarchy, and a floating panel's hierarchy is
  /// a glyph and a line of text. This cluster is inside the main window, and the
  /// field it refracts *is* in its hierarchy.

  /// The clock's `mm:ss` size. One size, because the cluster has one state —
  /// the bar's hover bloom (22pt → 58pt) is gone with the bar, and with it the
  /// hover machinery, the two reserved plates and the animation between them.
  /// `SessionTimerMetrics` derives the hour form from this and reserves the
  /// wider of the two, so crossing the hour still costs no reflow (XIA-431).
  static let clockBase: CGFloat = 30

  /// Above and below whatever the capsule holds. Small on purpose: the clock's
  /// own line box is what gives the capsule its height, and padding on top of a
  /// 30pt plate is what turns it into a control rather than a card.
  static let capsulePaddingV: CGFloat = CraftTokens.spacing4
  static let timerPaddingH: CGFloat = CraftTokens.spacing16
  /// Between the meter and the clock inside the timer capsule.
  static let timerContentGap: CGFloat = CraftTokens.spacing12
  /// Inside an action capsule, past its square minimum — what the moment count
  /// gets to spend when it appears beside the flag.
  static let actionPaddingH: CGFloat = CraftTokens.spacing12
  /// Between two capsules, and the merge distance the container is given: the
  /// same number in both places or the glass merges at a gap the eye does not
  /// see, or fails to merge at the one it does.
  static let capsuleGap: CGFloat = CraftTokens.spacing8
  /// The cluster's own clearance from the bottom of the pane.
  static let clusterBottomInset: CGFloat = CraftTokens.spacing24
  /// Between the cluster's top edge and the last line the transcript may draw.
  static let clusterTranscriptGap: CGFloat = CraftTokens.spacing16

  /// The meter in the cluster. `.compact`, and named rather than passed at the
  /// call site because `capsuleContentHeight` has to measure the same one the
  /// capsule draws.
  static let meterVariant: SessionMeterMetrics.Variant = .compact

  /// The action capsules' symbol size, and the AppKit twin of the face that
  /// draws it — `capsuleContentHeight` measures the icon's line box from this,
  /// so a bigger glyph cannot outgrow the row that was reserved for it.
  static let actionIconSize: CGFloat = 15
  static var actionMeasuringFont: NSFont { .systemFont(ofSize: actionIconSize, weight: .semibold) }

  /// The plate the moment tally is drawn on: two digits wide, reserved up
  /// front.
  ///
  /// The zero→one step is already refused (`RecordingPaneCopy.markerCount`
  /// returns nil at zero and the flag is always there) on the grounds that a
  /// control may not move under the pointer. One→two **digits** is the same
  /// defect at the tenth moment, and it moves Stop, which is the control the
  /// owner is most likely to be aiming at. So the count gets the reservation
  /// `SessionTimerMetrics.plateWidth` gives the clock. Past 99 it widens once,
  /// which is the hour step's bargain: one step, at a boundary nobody crosses
  /// by accident.
  static let markerCountWidth: CGFloat = {
    let font = NSFont.monospacedDigitSystemFont(ofSize: actionIconSize, weight: .semibold)
    return ("00" as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
  }()

  /// The tallest thing any capsule has to hold. **Measured, not typed** — this
  /// is the precedent XIA-444 got wrong: `controlRowHeight` was written as 40
  /// against a row that laid out at 41, so the bar promised 64 and drew 65, the
  /// `.frame(minHeight:)` never bound, and every geometry test in the file
  /// stayed green through it. A number that calls itself a derivation has to
  /// *be* one, and to be compared against the laid-out view.
  ///
  /// `static let` because it builds two `NSFont`s and measures two strings, and
  /// the cluster's body re-runs on every tick of the clock.
  static let capsuleContentHeight: CGFloat = {
    let icon = ("0" as NSString)
      .size(withAttributes: [.font: actionMeasuringFont])
      .height
    return max(
      SessionTimerMetrics.plateHeight(base: clockBase),
      meterVariant.maxBarHeight,
      icon.rounded(.up)
    )
  }()

  /// **One height for all three.** A row of capsules is one object made of
  /// parts; three heights reads as three things that happen to be near each
  /// other. Every capsule takes this as a hard frame, which is safe only
  /// because it was derived from the tallest content rather than chosen.
  static let capsuleHeight: CGFloat = capsuleContentHeight + 2 * capsulePaddingV

  /// What the transcript owes the cluster: the whole footprint, so no line can
  /// come to rest behind glass (owner's call, 2026-08-11 — "Reserve space",
  /// over reading through the refraction or having the cluster fade while text
  /// arrives). Computed from the constants the cluster is *placed* with, never
  /// typed a second time, or the reserve and the placement drift apart.
  static let transcriptBottomReserve: CGFloat =
    capsuleHeight + clusterBottomInset + clusterTranscriptGap

  // MARK: The transcript

  /// The timestamp gutter, mirroring the rich document pane so a live
  /// transcript and a finished one are read the same way.
  static let gutterWidth: CGFloat = 52
  static let gutterGap: CGFloat = CraftTokens.spacing12
  static let transcriptPaddingH: CGFloat = CraftTokens.spacing24
  static let transcriptPaddingV: CGFloat = CraftTokens.spacing24
  /// Between two blocks. Larger than between two lines *inside* one block —
  /// that difference is what makes a per-speaker block read as a turn.
  static let blockSpacing: CGFloat = CraftTokens.spacing16
  static let lineSpacing: CGFloat = CraftTokens.spacing4

  // MARK: Type

  static let kindLineFont: Font = .system(size: 13, weight: .medium)
  static let markerTimeFont: Font = CraftTokens.metadataFont
  static let markerLabelFont: Font = .system(size: 12)
  static let speakerFont: Font = .system(size: 12, weight: .semibold)
  static let transcriptFont: Font = .system(size: 14)
  static let gutterFont: Font = .system(size: 11, weight: .regular, design: .monospaced)

  // There is no `volatileOpacity` here any more. The tail was dimmed to 55% to
  // match the HUD prompter — a number off the tier table, one point under
  // `GroundInk.Tier.timestamp`'s 56%. It was **not** below the readability
  // floor: the solve says 3.0:1 wants 54% light and 40% dark, so 55% cleared it
  // on both themes. What it was, was unmeasured — an alpha nobody swept, sitting
  // between two that were. So the transcript draws the tail at the tier instead,
  // and every alpha the transcript spends is one the sweep solved. The HUD keeps
  // its own 55%: that is white text on a dark glass plate, not ink on the field,
  // and it was never in this measurement — nothing here is a finding against it.
}

// MARK: - Capsule tint

/// How strongly an action capsule is coloured, and the one place that number
/// lives.
///
/// The tint is drawn as the capsule's own background **over** its glass rather
/// than through `Glass.tint(_:)`, and the difference is Reduce Transparency:
/// the degraded branch of `liquidGlass` swaps the effect for `.regularMaterial`
/// and a `Glass` tint goes with it. Stop is the one control that may never be
/// hard to find, so its colour may not be a property of a material the system
/// is allowed to take away. Both action capsules use the same mechanism — one
/// vocabulary, and Mark is not worth a second one.
///
/// 62% is the owner's, chosen against the live prototype on 2026-08-11: enough
/// that the capsule reads as its colour over any ground, little enough that the
/// glass under it still refracts rather than being a flat button.
enum RecordingCapsuleTint {
  static let strength: Double = 0.62

  static func fill(_ tint: Color) -> Color { tint.opacity(strength) }
}

// MARK: - The meter's feed

/// When the microphone's level may be republished.
///
/// `MicCapture` installs its tap with a 1024-frame buffer at the source rate —
/// a delivery roughly every 21 ms, ~45 a second. An unconditional assignment to
/// a `@Published` property fires `objectWillChange` on every one of them, and
/// the meter's first home was `LiveMeetingSession`, which `ContentView` and
/// `LiveMeetingView` both observe: each tick invalidated the whole window body,
/// toolbar and transcript included. CLAUDE.md already records this trap for the
/// HUD prompter ("re-rendered on every 66 ms RMS tick … an unbounded main-actor
/// cost on a feed that ticks 15 times a second"); this was three times that
/// rate against a much larger hierarchy.
///
/// So the level lives on its own object (`MicLevelFeed`) that only the meter
/// observes, **and** the writes are gated. Two gates, because either alone
/// leaves a hole:
///
/// - **Time.** Never faster than `minInterval` — the HUD's own tick, and more
///   than a bar can visibly move between.
/// - **Movement.** A change smaller than `minDelta` is a change nobody can see;
///   spending a render on it is spending it on nothing.
///
/// And one escape, because the movement gate alone can wedge: a level that
/// decays toward silence in steps below the threshold would never publish
/// again, leaving a full meter over a quiet room — which is the exact lie the
/// meter exists to make impossible. After `maxHold` any difference at all
/// publishes.
enum MeterPublishGate {
  /// 66 ms — the HUD's RMS tick, i.e. ~15 Hz.
  static let minInterval: TimeInterval = 0.066
  /// Below this the tallest bar moves under a point.
  static let minDelta: Float = 0.02
  /// Past this, any difference publishes: convergence beats economy.
  static let maxHold: TimeInterval = 0.5

  static func shouldPublish(
    new: Float,
    last: Float,
    now: TimeInterval,
    lastPublishedAt: TimeInterval
  ) -> Bool {
    guard new != last else { return false }
    let since = now - lastPublishedAt
    guard since >= minInterval else { return false }
    return abs(new - last) >= minDelta || since >= maxHold
  }
}

/// The microphone level, published on an object **only the meter observes**.
///
/// It is deliberately not a `@Published` property of `LiveMeetingSession`: that
/// object is observed by `ContentView` and `LiveMeetingView`, and a 45 Hz feed
/// on it re-renders the window. Held by the session as a plain `let`, so
/// mutating it never touches the session's own `objectWillChange`.
@MainActor
final class MicLevelFeed: ObservableObject {
  @Published private(set) var level: Float

  private var lastPublishedAt: TimeInterval = -.greatestFiniteMagnitude

  init(level: Float = 0) {
    self.level = level
  }

  /// Publish if `MeterPublishGate` allows it. `now` is injected so the gate is
  /// testable without waiting out a real 66 ms.
  func publish(_ level: Float, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    guard
      MeterPublishGate.shouldPublish(
        new: level,
        last: self.level,
        now: now,
        lastPublishedAt: lastPublishedAt
      )
    else { return }
    self.level = level
    lastPublishedAt = now
  }

  /// Silence, immediately and ungated. Capture ending is the one level change
  /// that may not wait for a tick: a meter frozen at the last thing it heard is
  /// a meter claiming a live session.
  func silence(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    guard level != 0 else { return }
    level = 0
    lastPublishedAt = now
  }
}

/// `SessionMeter` bound to the live feed.
///
/// This wrapper is the entire point of the split: `@ObservedObject` **here**
/// means a level tick re-runs *this* body and nothing above it — not the
/// column, not the transcript, not the window.
struct SessionMeterFeedView: View {
  @ObservedObject var feed: MicLevelFeed
  var variant: SessionMeterMetrics.Variant

  var body: some View {
    SessionMeter(level: feed.level, variant: variant)
  }
}

// MARK: - Copy

/// Every fixed string the recording surface draws, in one place.
///
/// It is a type rather than string literals scattered through the views because
/// of the promise it exists to keep: **a memo and a meeting differ by exactly
/// one word**. The accent does not change, no chrome changes, no control
/// changes — the kind is a label and it is relabelable after the fact
/// (`docs/design/recording-refresh-inspiration.md`, don't #6). `all(kind:…)`
/// is what a test can diff to hold that.
enum RecordingPaneCopy {
  /// "Meeting" / "Memo" — the whole of the difference.
  static func noun(_ kind: HistoryKind) -> String {
    kind == .memo ? "Memo" : "Meeting"
  }

  /// What the session is doing, independent of the kind.
  static func activity(_ controls: LiveMeetingControls) -> String {
    switch controls {
    case .start: return "ready"
    case .starting: return "starting"
    case .stop: return "listening"
    case .finalizing: return "finishing"
    case .saveOrDiscard, .retryOrDiscard: return "stopped"
    }
  }

  /// The kind line: "Meeting · listening".
  ///
  /// Since XIA-445 it reaches the screen in the **idle** state alone. The
  /// cluster draws no kind: the owner chose the "C · Essential" timer capsule,
  /// which is the meter and the clock and nothing else, on the reasoning that a
  /// kind is relabelable after Stop and forbidden from changing anything visual
  /// — so during a session it is a word that never moves and never does
  /// anything. It stays in `all(kind:controls:)` because it is still the whole
  /// of the difference between a memo and a meeting, and that promise is about
  /// the pane rather than about one of its states.
  static func kindLine(kind: HistoryKind, controls: LiveMeetingControls) -> String {
    "\(noun(kind)) · \(activity(controls))"
  }

  /// What a marker row says beside its timestamp — **nothing**, until XIA-433
  /// gives markers a meaning to say. It used to fall back to the section
  /// heading, so every row under a heading reading MOMENTS read `12:04 Moments`:
  /// drawn, and evidently never looked at. A timestamp alone is the honest row,
  /// and it is the row the auto-titled label will land in.
  static func markerLabel(_ marker: SessionMarker) -> String? {
    marker.label
  }

  /// Mark and Stop are **icon only** on the cluster (owner, 2026-08-11), so
  /// these three reach the owner as the accessibility label and the tooltip
  /// rather than as a drawn label. They are still strings the surface puts in
  /// front of someone, which is why they are still in `all(kind:controls:)`.
  static let markTitle = "Mark"
  static let markShortcut = "⌘K"
  static let stopTitle = "Stop"
  static let listening = "Listening…"
  static let markersHeading = "Moments"
  static let noMarkers = "No moments yet"

  /// The count beside the flag on the Mark capsule — **nil at zero**, not "0".
  ///
  /// The button itself is always there: an affordance that appeared the moment
  /// the first moment was flagged would be a control that moves under the
  /// pointer, on the one surface whose whole job is to hold still. What it may
  /// not do is report a tally nobody has started, so an empty log shows the
  /// flag alone and the popover says `noMarkers` in words.
  ///
  /// Not part of `all(kind:controls:)` below, and that is deliberate: this is
  /// the one string on the surface that is a function of the session rather
  /// than of the (kind, controls) pair, so it cannot differ between a memo and
  /// a meeting no matter what it says.
  static func markerCount(_ markers: [SessionMarker]) -> String? {
    markers.isEmpty ? nil : "\(markers.count)"
  }

  /// Every string the pane can put on screen for one (kind, controls) pair.
  /// The test that diffs meeting against memo reads this, so a string added to
  /// a view without being added here is a string the promise stops covering —
  /// which is exactly the drift worth failing on.
  static func all(kind: HistoryKind, controls: LiveMeetingControls) -> [String] {
    [
      kindLine(kind: kind, controls: controls),
      markTitle,
      markShortcut,
      stopTitle,
      listening,
      markersHeading,
      noMarkers,
    ]
  }
}

// MARK: - Moment markers

/// A flagged moment in a running session.
///
/// `label` is unused today and deliberately present: the marker's *meaning*
/// (auto-titled from the surrounding transcript) is XIA-433's, and a row that
/// has to grow a second line later is a row that has to be re-laid-out later.
struct SessionMarker: Equatable, Identifiable {
  let id: UUID
  /// Seconds into the session.
  let at: TimeInterval
  var label: String?

  init(id: UUID = UUID(), at: TimeInterval, label: String? = nil) {
    self.id = id
    self.at = at
    self.label = label
  }
}

/// The marker list's ordering rule, pure so "newest first" is a fact rather
/// than an argument about where `append` was called.
enum SessionMarkerOrder {
  /// Newest first — the list sits at the bottom of the column, and the moment
  /// the owner just flagged is the one they are looking for.
  static func inserting(_ marker: SessionMarker, into markers: [SessionMarker]) -> [SessionMarker] {
    [marker] + markers
  }
}

/// Session-local marker storage.
///
/// **Stub, and named as one.** The end-to-end marker (persisted on the record,
/// carried into the summary, shown on the finished document) is XIA-433. What
/// this owns is the UI slot: pressing Mark produces a visible, timestamped row
/// so the affordance is real rather than a dead button, and the log is thrown
/// away with the session. When the real model lands, the column reads its
/// markers instead and `SessionMarkerList` does not change.
@MainActor
final class SessionMarkerLog: ObservableObject {
  @Published private(set) var markers: [SessionMarker] = []

  func mark(at elapsed: TimeInterval) {
    markers = SessionMarkerOrder.inserting(SessionMarker(at: max(0, elapsed)), into: markers)
  }

  func reset() {
    markers = []
  }
}

// MARK: - Transcript model

/// One line of live transcript as the pane needs to draw it.
///
/// `speaker` is the field the realtime pipeline does not fill yet — AssemblyAI
/// realtime speaker labels are a known unresolved follow-up. It is here anyway,
/// and the grouping below already honours it, because the reference sweep's
/// note was explicit (do #6): leave room for a speaker column *before* the
/// labels exist, so the day they arrive the transcript gains names and loses
/// no layout.
struct LiveTranscriptLine: Equatable, Identifiable {
  let id: UUID
  let text: String
  let endTime: TimeInterval
  var speaker: String?
  /// The in-flight recognition tail: drawn dimmed, replaced wholesale on the
  /// next update, and never part of what has been said.
  var isVolatile: Bool = false
}

/// Consecutive lines from one speaker, drawn as a turn with the name above it.
struct LiveTranscriptBlock: Equatable, Identifiable {
  /// The first line's id, so a block is a stable scroll anchor across the
  /// updates that extend it.
  let id: UUID
  let speaker: String?
  /// The block's own gutter timestamp — where the turn *started*.
  let startedAt: TimeInterval
  var lines: [LiveTranscriptLine]
}

/// One **drawn** row of the live transcript.
///
/// Rows are flat on purpose, and that is a correction rather than a style. A
/// `LazyVStack` defers only its **direct** children; the first cut put each
/// block in the stack and each block's lines in an inner `VStack`, and since
/// `speaker` is nil for every line the pipeline produces today, the entire
/// session was one block — one child — so every `Text` the meeting had ever
/// drawn was built and measured on every render pass, on screen or not. Master
/// put each segment directly in the stack and only built what was visible.
///
/// Flattening keeps that laziness and keeps the grouping: the speaker name a
/// block used to draw above its lines is emitted as its own row where the
/// speaker changes, which is the same picture with one less level of nesting.
struct LiveTranscriptRow: Equatable, Identifiable {
  enum Content: Equatable {
    /// A turn's speaker name. Emitted only where the speaker changes, so it is
    /// absent entirely until the realtime pipeline fills the labels in.
    case speaker(String)
    case line(LiveTranscriptLine)
  }

  /// Typed, because a speaker row and its turn's first line would otherwise
  /// share an id — a block anchors on its first line.
  enum ID: Hashable {
    case speaker(UUID)
    case line(UUID)
  }

  let id: ID
  /// The gutter timestamp, present only on the row that **starts** a turn. A
  /// continuation row still reserves the cell and draws nothing in it, or its
  /// text would step left under the line above it.
  let gutter: TimeInterval?
  let content: Content

  /// Rows that start a turn take the larger inter-block gap. That difference is
  /// what makes a turn read as a turn once a flat stack has no blocks left to
  /// space apart.
  var startsTurn: Bool { gutter != nil }
}

enum LiveTranscript {
  /// One stable id for the volatile tail, so the scroll reader can chase a run
  /// that is rewritten on every interim result.
  static let volatileLineID = UUID()

  /// The session's published state as lines. The volatile tail is a line like
  /// any other — it groups with the turn it continues and differs only in how
  /// it is drawn.
  static func lines(
    segments: [LiveMeetingSession.LiveSegment],
    partial: String?,
    elapsed: TimeInterval
  ) -> [LiveTranscriptLine] {
    var lines = segments.map {
      LiveTranscriptLine(id: $0.id, text: $0.text, endTime: $0.endTime, speaker: nil)
    }
    if let partial, !partial.isEmpty {
      lines.append(
        LiveTranscriptLine(
          id: volatileLineID,
          text: partial,
          endTime: elapsed,
          // Continues whoever was last speaking; nil today, and nil is a
          // speaker value like any other as far as the grouping is concerned.
          speaker: lines.last?.speaker,
          isVolatile: true
        )
      )
    }
    return lines
  }

  /// Group consecutive lines by speaker. With no labels every line has the same
  /// (nil) speaker, so today this produces exactly one block and reads as the
  /// continuous transcript it is — the grouping is not waiting to be written,
  /// it is waiting to be *fed*.
  static func blocks(_ lines: [LiveTranscriptLine]) -> [LiveTranscriptBlock] {
    var blocks: [LiveTranscriptBlock] = []
    for line in lines {
      if var last = blocks.last, last.speaker == line.speaker {
        last.lines.append(line)
        blocks[blocks.count - 1] = last
      } else {
        blocks.append(
          LiveTranscriptBlock(
            id: line.id,
            speaker: line.speaker,
            startedAt: line.endTime,
            lines: [line]
          )
        )
      }
    }
    return blocks
  }

  /// The blocks, flattened into the rows the `LazyVStack` actually gets.
  ///
  /// One row per line, always — that is the invariant the laziness rests on —
  /// plus one header row per turn that has a speaker.
  static func rows(_ blocks: [LiveTranscriptBlock]) -> [LiveTranscriptRow] {
    var rows: [LiveTranscriptRow] = []
    for block in blocks {
      // The gutter belongs to whichever row opens the turn: the speaker header
      // if there is one, otherwise the turn's first line.
      var gutter: TimeInterval? = block.startedAt
      if let speaker = block.speaker {
        rows.append(LiveTranscriptRow(id: .speaker(block.id), gutter: gutter, content: .speaker(speaker)))
        gutter = nil
      }
      for line in block.lines {
        rows.append(LiveTranscriptRow(id: .line(line.id), gutter: gutter, content: .line(line)))
        gutter = nil
      }
    }
    return rows
  }

  /// "mm:ss" / "h:mm:ss" for the gutter — the same clock the timer runs, so a
  /// marker at 12:04 and a transcript line at 12:04 name the same instant.
  static func timestamp(_ interval: TimeInterval) -> String {
    SessionTimerMetrics.text(elapsed: interval)
  }
}

/// Memoizes the transcript's row model against the inputs that can change it.
///
/// `lines` → `blocks` → `rows` maps **every** segment of the session, so it is
/// O(all segments) — nothing when it runs on new text, ruinous when it runs on
/// a render the transcript did not cause. The pane's other publishers (the
/// elapsed ticker, and anything else that invalidates the window) would
/// otherwise rebuild 400 line structs to redraw a clock.
///
/// The key is cheap on purpose: a segment list is append-only, so its count and
/// its last id say everything about it, and `elapsed` reaches the model only as
/// the volatile line's gutter timestamp — which is drawn to the second.
@MainActor
final class LiveTranscriptRowCache {
  struct Key: Equatable {
    let segmentCount: Int
    let lastSegmentID: UUID?
    let partial: String?
    let elapsedSeconds: Int
  }

  /// How many times the model was really rebuilt. Exposed so a test can prove
  /// the cache is a cache rather than a wrapper around a recomputation.
  private(set) var recomputeCount = 0

  private var key: Key?
  private var rows: [LiveTranscriptRow] = []

  func rows(
    segments: [LiveMeetingSession.LiveSegment],
    partial: String?,
    elapsed: TimeInterval
  ) -> [LiveTranscriptRow] {
    let next = Key(
      segmentCount: segments.count,
      lastSegmentID: segments.last?.id,
      partial: partial,
      elapsedSeconds: elapsed.isFinite && elapsed > 0 ? Int(elapsed) : 0
    )
    if next == key { return rows }
    key = next
    rows = LiveTranscript.rows(
      LiveTranscript.blocks(
        LiveTranscript.lines(segments: segments, partial: partial, elapsed: elapsed)
      )
    )
    recomputeCount += 1
    return rows
  }
}

// MARK: - Controls

/// An action capsule: one glyph, one job, one colour, and exactly the height
/// every other capsule in the cluster has.
///
/// Internal rather than private because the claim it makes is about **pixels** —
/// that the colour survives the material being taken away — and only a rendered
/// button can answer that.
///
/// Three things it owes:
///
/// - **The height is the cluster's, as a hard frame.** A capsule that sized
///   itself to its glyph would be shorter than the timer beside it, and the row
///   would read as three unrelated controls. It is safe as a hard frame only
///   because `capsuleContentHeight` measured this face before reserving it.
/// - **The width is square at its minimum and grows for the count.** Icon only
///   is the owner's call; the moment count is the one thing that may widen a
///   capsule, and it widens the one it counts.
/// - **The tint is drawn over the glass, not through it.** See
///   `RecordingCapsuleTint`: a `Glass` tint is a property of the material and
///   goes with it under Reduce Transparency, and Stop is the one control that
///   may never be hard to find.
struct RecordingCapsuleButtonStyle: ButtonStyle {
  let tint: Color

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: RecordingPaneMetrics.actionIconSize, weight: .semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, RecordingPaneMetrics.actionPaddingH)
      .frame(minWidth: RecordingPaneMetrics.capsuleHeight)
      .frame(height: RecordingPaneMetrics.capsuleHeight)
      .background(RecordingCapsuleTint.fill(tint), in: Capsule(style: .continuous))
      .craftGlassPanel(in: Capsule(style: .continuous))
      .opacity(configuration.isPressed ? 0.85 : 1)
  }
}

// MARK: - Marker list

/// The flagged moments, newest first — the contents of the Mark capsule's
/// popover (owner's call, 2026-08-10: "markers are a count that opens a
/// popover", not hairlines down the transcript; unchanged by XIA-445, which
/// moved which control opens it and nothing else).
///
/// The list used to sit at the bottom of the session column, and neither a bar
/// nor a capsule has a bottom to put it at. The popover is what the column's
/// height was buying:
/// somewhere a list may accumulate without pushing the fixed things around.
/// Hairlines in the transcript were the alternative and were refused — a mark
/// is a *time*, and a mark in the middle of a scrolling transcript is only
/// findable if you already know where it is.
///
/// It keeps its own `ScrollView` now, which the column's version explicitly did
/// not: nesting two on one axis is what that comment was avoiding, and a
/// popover has no outer scroll to fight with. Unbounded it would grow the
/// popover past the screen on a long meeting.
struct SessionMarkerList: View {
  let markers: [SessionMarker]

  /// Wide enough for a timestamp and an auto-title (XIA-433) without the
  /// popover resizing as one arrives.
  static let width: CGFloat = 240
  /// About nine rows. Past that the list scrolls rather than the popover
  /// growing to whatever the session flagged.
  static let maxListHeight: CGFloat = 220

  var body: some View {
    VStack(alignment: .leading, spacing: CraftTokens.spacing8) {
      Text(RecordingPaneCopy.markersHeading)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.ground(.speaker))
        .textCase(.uppercase)

      if markers.isEmpty {
        Text(RecordingPaneCopy.noMarkers)
          .font(RecordingPaneMetrics.markerLabelFont)
          .foregroundStyle(.ground(.timestamp))
      } else {
        // This list DOES get its own `ScrollView`, and the rule it used to break
        // no longer applies. XIA-443 wrote it without one because the 288pt
        // column already scrolled and two scroll views nested on one axis fight
        // over every wheel event; XIA-444 deleted the column and put the markers
        // in a popover, which scrolls nothing on its own. One scroll view on the
        // axis, still — the reason survived, the containing surface changed.
        ScrollView {
          VStack(alignment: .leading, spacing: CraftTokens.spacing8) {
            ForEach(markers) { marker in
              HStack(spacing: CraftTokens.spacing8) {
                Text(LiveTranscript.timestamp(marker.at))
                  .font(RecordingPaneMetrics.markerTimeFont)
                  .foregroundStyle(.ground(.timestamp))
                if let label = RecordingPaneCopy.markerLabel(marker) {
                  Text(label)
                    .font(RecordingPaneMetrics.markerLabelFont)
                    .foregroundStyle(.ground(.body))
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: Self.maxListHeight)
      }
    }
    .frame(width: Self.width, alignment: .leading)
    .padding(CraftTokens.spacing16)
  }
}

// MARK: - The capsule cluster

/// The timer capsule: **the meter and the clock, and nothing else.**
///
/// That is the owner's "C · Essential" (2026-08-11), chosen against three
/// fuller variants, and each omission has a reason worth keeping. The ember
/// **dot** went because the meter proves the same thing and proves it harder —
/// a dot is lit whether or not anything is being heard, and a meter with a
/// floor is the only thing on screen that can tell a live microphone from a
/// wedged one. The **kind** went because it is relabelable after Stop and
/// forbidden from changing anything visual, so during a session it is a word
/// that never moves and never does anything.
///
/// Clear glass, no tint: this capsule is information, and the two beside it are
/// actions.
struct SessionTimerCapsule: View {
  let elapsed: TimeInterval
  /// The meter's own object. Passed rather than a `Float` so the level's ~15 Hz
  /// feed is observed by `SessionMeterFeedView` alone — see `MeterPublishGate`.
  let level: MicLevelFeed

  var body: some View {
    HStack(spacing: RecordingPaneMetrics.timerContentGap) {
      SessionMeterFeedView(feed: level, variant: RecordingPaneMetrics.meterVariant)
      SessionTimer(elapsed: elapsed, base: RecordingPaneMetrics.clockBase)
    }
    .padding(.horizontal, RecordingPaneMetrics.timerPaddingH)
    .frame(height: RecordingPaneMetrics.capsuleHeight)
    .craftGlassPanel(in: Capsule(style: .continuous))
  }
}

/// The recording surface: three sibling capsules floating over the transcript
/// (XIA-445).
///
/// Left to right the session, then what to do about it — the clock, Mark, Stop.
/// That is the bar's order and the column's before it; what changed is that the
/// row no longer takes a band of the window to say it.
///
/// One `GlassEffectContainer` at the same spacing the `HStack` uses, because the
/// container's spacing *is* the merge distance: two numbers here would merge the
/// plates at a gap the eye does not see, or fail to merge at the one it does.
/// Nothing wraps the capsules — a capsule inside a capsule is not a doubled rim,
/// it is Liquid Glass silently auto-converted to a vibrant fill, which is a
/// failure with nothing on screen to announce it.
struct SessionCapsuleCluster: View {
  let elapsed: TimeInterval
  let level: MicLevelFeed
  let controls: LiveMeetingControls
  let markers: [SessionMarker]
  let onMark: () -> Void
  let onStop: () -> Void

  /// The popover is **this view's** state and not the pane's. A press on Mark
  /// may not invalidate `LiveMeetingView`'s body: that body draws the
  /// transcript, and XIA-432 is this file's whole account of what a frequent
  /// change costs when a broad observer is watching.
  @State private var showingMoments = false

  private var isStoppable: Bool { controls == .stop }

  var body: some View {
    GlassEffectContainer(spacing: RecordingPaneMetrics.capsuleGap) {
      HStack(spacing: RecordingPaneMetrics.capsuleGap) {
        SessionTimerCapsule(elapsed: elapsed, level: level)
        markCapsule
        stopCapsule
      }
      .background(markShortcut)
    }
  }

  /// The flag, the tally past zero, and the popover a press opens.
  private var markCapsule: some View {
    Button {
      showingMoments.toggle()
    } label: {
      HStack(spacing: CraftTokens.spacing4) {
        Image(systemName: "bookmark.fill")
        if let count = RecordingPaneCopy.markerCount(markers) {
          Text(count)
            .monospacedDigit()
            .frame(minWidth: RecordingPaneMetrics.markerCountWidth)
        }
      }
    }
    .buttonStyle(RecordingCapsuleButtonStyle(tint: CraftTokens.primaryBlue))
    .accessibilityLabel(RecordingPaneCopy.markersHeading)
    .help(RecordingPaneCopy.markersHeading)
    .popover(isPresented: $showingMoments, arrowEdge: .top) {
      SessionMarkerList(markers: markers)
    }
  }

  /// ⌘K still flags a moment, and it cannot live on the capsule: a press there
  /// opens the list, so the shortcut on that button would open a list instead
  /// of marking. It is a zero-sized button behind the row rather than a
  /// `commands` entry because the affordance belongs to a session that is
  /// running — it goes away with the cluster, and it is disabled with it.
  private var markShortcut: some View {
    Button(RecordingPaneCopy.markTitle, action: onMark)
      .keyboardShortcut("k", modifiers: .command)
      .disabled(!isStoppable)
      .frame(width: 0, height: 0)
      .opacity(0)
      .accessibilityHidden(true)
  }

  /// The loudest control on the surface, and the last one in the row.
  ///
  /// Red rather than the ember, which is the owner's call taken with the
  /// measurement in hand (see `CraftTokens.stopRed`). What defuses the old
  /// objection — that a warm Stop sits a hundred points from a warm "we are
  /// recording" — is the timer capsule the same call chose: with the ember dot
  /// gone the only ember left in the cluster is the meter's thin moving bars,
  /// which no filled capsule can be read as.
  private var stopCapsule: some View {
    Button(action: onStop) {
      Image(systemName: "stop.fill")
    }
    .buttonStyle(RecordingCapsuleButtonStyle(tint: CraftTokens.stopRed))
    .disabled(!isStoppable)
    .accessibilityLabel(RecordingPaneCopy.stopTitle)
    .help(RecordingPaneCopy.stopTitle)
  }
}

// MARK: - Transcript

/// The live transcript: gutter timestamps, a speaker slot above each turn, the
/// volatile tail dimmed, newest text always in view.
struct LiveTranscriptView: View {
  /// Flat: every row here is a **direct** child of the `LazyVStack` below, which
  /// is the only arrangement in which the stack's laziness is worth anything.
  let rows: [LiveTranscriptRow]
  /// Chased separately from the row ids: the tail is rewritten on every interim
  /// result and the row's identity does not change when it does.
  let volatileID: UUID?
  /// Room kept clear at the bottom for the capsule cluster floating over this
  /// view (XIA-445). It is scroll **content** padding rather than a frame inset,
  /// which is the half that matters: `scrollToNewest` pins the newest row to
  /// `.bottom`, so an overlay that merely covered the last line would leave the
  /// text the owner is reading permanently behind glass. Zero for a transcript
  /// with nothing over it — the failed session's, which wears a banner instead.
  var bottomReserve: CGFloat = 0

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: RecordingPaneMetrics.lineSpacing) {
          if rows.isEmpty {
            listeningPlaceholder
          }
          ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            rowView(row, isFirst: index == 0).id(row.id)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, RecordingPaneMetrics.transcriptPaddingH)
        .padding(.top, RecordingPaneMetrics.transcriptPaddingV)
        .padding(.bottom, RecordingPaneMetrics.transcriptPaddingV + bottomReserve)
      }
      .onChange(of: rows.count) { _, _ in
        scrollToNewest(proxy)
      }
      .onChange(of: rows.last) { _, _ in
        scrollToNewest(proxy)
      }
    }
  }

  private func scrollToNewest(_ proxy: ScrollViewProxy) {
    if let volatileID {
      proxy.scrollTo(LiveTranscriptRow.ID.line(volatileID), anchor: .bottom)
    } else if let last = rows.last {
      proxy.scrollTo(last.id, anchor: .bottom)
    }
  }

  private var listeningPlaceholder: some View {
    HStack(spacing: CraftTokens.spacing8) {
      Image(systemName: "waveform")
        .symbolEffect(.pulse, isActive: true)
        .foregroundStyle(.ground(.speaker))
      Text(RecordingPaneCopy.listening)
        .font(RecordingPaneMetrics.transcriptFont)
        .foregroundStyle(.ground(.speaker))
    }
  }

  /// One row: the gutter cell, then either a speaker name or a line of text.
  ///
  /// The speaker slot is a real row rather than a comment about a future one.
  /// Today no line carries a speaker and no such row is ever emitted; the day
  /// the pipeline fills the labels in, names appear and not one number in
  /// `RecordingPaneMetrics` moves.
  private func rowView(_ row: LiveTranscriptRow, isFirst: Bool) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: RecordingPaneMetrics.gutterGap) {
      // The cell is reserved on every row and filled only where a turn starts,
      // so a continuation never steps left under the line above it.
      Text(row.gutter.map(LiveTranscript.timestamp) ?? "")
        .font(RecordingPaneMetrics.gutterFont)
        .foregroundStyle(.ground(.timestamp))
        .frame(width: RecordingPaneMetrics.gutterWidth, alignment: .trailing)

      switch row.content {
      case .speaker(let name):
        Text(name)
          .font(RecordingPaneMetrics.speakerFont)
          .foregroundStyle(.ground(.speaker))
          .frame(maxWidth: .infinity, alignment: .leading)
      case .line(let line):
        // The volatile tail is **a tier, not an `.opacity()` on the body tier**.
        // It used to be body at 55%, which is a number nobody measured — a hair
        // under the timestamp tier's 56% and off the table entirely. It cleared
        // 3.0:1 (the solve needs 54% light, 40% dark); what it did not have was
        // a measurement, on the one line that is being read while it is written.
        // The tier is visually the same dimming and is on the swept side of it.
        Text(line.text)
          .font(RecordingPaneMetrics.transcriptFont)
          .foregroundStyle(.ground(line.isVolatile ? .timestamp : .body))
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    // A flat stack has no blocks left to space apart, so the gap between turns
    // is paid by the row that opens one.
    .padding(.top, row.startsTurn && !isFirst
      ? RecordingPaneMetrics.blockSpacing - RecordingPaneMetrics.lineSpacing
      : 0)
  }
}

// MARK: - Previews

#if DEBUG
private func previewRows() -> [LiveTranscriptRow] {
  LiveTranscript.rows(previewBlocks())
}

private func previewBlocks() -> [LiveTranscriptBlock] {
  LiveTranscript.blocks([
    LiveTranscriptLine(id: UUID(), text: "Right, so the migration lands next Tuesday.", endTime: 12, speaker: "Amara"),
    LiveTranscriptLine(id: UUID(), text: "We still owe the rollback note.", endTime: 19, speaker: "Amara"),
    LiveTranscriptLine(id: UUID(), text: "I can write that this afternoon.", endTime: 27, speaker: "Kenny"),
    LiveTranscriptLine(id: LiveTranscript.volatileLineID, text: "and I'll ping the on-call", endTime: 31, speaker: "Kenny", isVolatile: true),
  ])
}

private struct RecordingPaneGallery: View {
  let kind: HistoryKind

  var body: some View {
    CraftWashBackground()
      .overlay(
        ZStack(alignment: .bottom) {
          LiveTranscriptView(
            rows: previewRows(),
            volatileID: LiveTranscript.volatileLineID,
            bottomReserve: RecordingPaneMetrics.transcriptBottomReserve
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)

          SessionCapsuleCluster(
            elapsed: 754,
            level: MicLevelFeed(level: 0.6),
            controls: .stop,
            markers: [SessionMarker(at: 612), SessionMarker(at: 208)],
            onMark: {},
            onStop: {}
          )
          .padding(.bottom, RecordingPaneMetrics.clusterBottomInset)
        }
      )
  }
}

#Preview("recording pane – light") {
  RecordingPaneGallery(kind: .meeting)
    .frame(width: 980, height: 620)
    .preferredColorScheme(.light)
}

#Preview("recording pane – dark") {
  RecordingPaneGallery(kind: .meeting)
    .frame(width: 980, height: 620)
    .preferredColorScheme(.dark)
}

/// Past the hour, and with no moments flagged: the clock steps to `h:mm:ss`
/// inside a plate that was reserved for it, and the Mark capsule is square.
#Preview("recording cluster – past the hour") {
  CraftWashBackground()
    .overlay(
      SessionCapsuleCluster(
        elapsed: 3754,
        level: MicLevelFeed(level: 0.6),
        controls: .stop,
        markers: [],
        onMark: {},
        onStop: {}
      )
    )
    .frame(width: 980, height: 240)
    .preferredColorScheme(.dark)
}
#endif
