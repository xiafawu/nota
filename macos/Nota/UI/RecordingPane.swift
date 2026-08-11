import SwiftUI

// MARK: - Metrics

/// Everything about the recording bar that is arithmetic, kept out of the views
/// for the reason `SessionTimerMetrics` and `HUDPrompterMetrics` are: a test can
/// then answer "how much taller is the bloom" without a window server.
enum RecordingPaneMetrics {
  // MARK: The bar

  /// The bar is a full-width row above the transcript (XIA-444). It replaced a
  /// 288pt trailing column, and the reason is arithmetic rather than taste: the
  /// column charged the transcript a quarter of every window for an indicator
  /// that is three glyphs, a meter and two buttons wide. A band across the top
  /// charges it height instead, and height is the axis a transcript has most of.
  ///
  /// What went with the column is the **fold**. There were two forms because a
  /// fixed-width column could starve the text at a narrow window; a bar takes
  /// the width it is given at every window this app allows, so there is one
  /// arrangement and no threshold to be wrong about.
  static let barPaddingH: CGFloat = CraftTokens.spacing24
  static let barPaddingV: CGFloat = CraftTokens.spacing12

  /// The clock's `mm:ss` size at rest and while the bar is bloomed.
  ///
  /// 22 is a caption on a row; 58 is the session's *object*, which is what the
  /// column made it and what the bloom gives back on demand. `SessionTimerMetrics`
  /// derives the hour form from whichever of these is in force and reserves the
  /// wider of the two, so crossing the hour costs no reflow in either state
  /// (XIA-431); nothing here re-derives it.
  static let restTimerBase: CGFloat = 22
  static let bloomTimerBase: CGFloat = 58

  /// The ember ring is a breathing **dot** in both states, and it stays a dot
  /// through the bloom deliberately. A circle sized to contain the 58pt clock —
  /// the arithmetic the column used — is ~225pt across, which would make the
  /// bloomed bar taller than the transcript under it: a balloon around a clock
  /// rather than a ring on one, at pane scale. The folded strip this replaces
  /// refused the same thing for a 26pt timer. What the bloom is *for* is the
  /// clock, so the clock is what grows.
  static let dotDiameter: CGFloat = 20
  static let dotLineWidth: CGFloat = 1.5

  /// The floor under the bar's content height: the Stop capsule, which is a
  /// 14pt label with `spacing12` above and below it. Named because it is what
  /// sets the resting height — the 22pt clock and the compact meter are both
  /// shorter than the buttons beside them — and because a bar whose height came
  /// from whichever child happened to be tallest would step whenever a control
  /// changed font.
  static let controlRowHeight: CGFloat = 40

  /// The tallest thing the bar has to hold in a given state. Derived from the
  /// clock's own reserved plate rather than typed in, so the bloom's height
  /// follows `bloomTimerBase` and a future change to it cannot silently clip
  /// the digits.
  ///
  /// **Measured once each**, and that is not premature: `plateHeight` builds an
  /// `NSFont` and measures a string, the bar's body re-runs on every tick of
  /// the clock, and there are exactly two answers — a `static let` is computed
  /// lazily and kept, so the derivation survives and the per-tick cost does not.
  static func barContentHeight(bloomed: Bool) -> CGFloat {
    bloomed ? bloomedContentHeight : restingContentHeight
  }

  private static let restingContentHeight: CGFloat = contentHeight(bloomed: false)
  private static let bloomedContentHeight: CGFloat = contentHeight(bloomed: true)

  private static func contentHeight(bloomed: Bool) -> CGFloat {
    max(
      controlRowHeight,
      SessionTimerMetrics.plateHeight(base: RecordingPaneLayout.timerBase(bloomed: bloomed)),
      RecordingPaneLayout.meterVariant(bloomed: bloomed).maxBarHeight
    )
  }

  /// What the bar measures, at rest and bloomed. **This** is what the bloom
  /// animates — the card — never the digits: the clock steps between two
  /// reserved plates, each already independent of `elapsed`, so nothing inside
  /// is re-measured while the height is in flight.
  static func barHeight(bloomed: Bool) -> CGFloat {
    barContentHeight(bloomed: bloomed) + 2 * barPaddingV
  }

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

  /// The volatile tail's opacity — the same 55% the HUD prompter dims its
  /// in-flight run to, so "not final yet" means one thing across the app.
  static let volatileOpacity: Double = 0.55
}

// MARK: - Layout decisions

/// The pure half of "what the bar looks like right now". One input — whether
/// the pointer is over it — and every per-state number comes from here rather
/// than from the view, so a change reaches the screen instead of only the test
/// that reads it.
enum RecordingPaneLayout {
  /// The timer's `mm:ss` size. The bloom is a **size step**, not a scale: a
  /// `scaleEffect` interpolates a rendered layer instead of re-typesetting it,
  /// so the clock would be a stretched image of itself for the length of the
  /// animation. Two plates reserved up front are typeset at both ends, which is
  /// also what keeps `SessionTimerMetrics`' hour step honest in either state.
  static func timerBase(bloomed: Bool) -> CGFloat {
    bloomed ? RecordingPaneMetrics.bloomTimerBase : RecordingPaneMetrics.restTimerBase
  }

  /// The meter grows with the clock: the bloom is the state in which the bar is
  /// being *read*, and the meter is the only thing on it that is information.
  static func meterVariant(bloomed: Bool) -> SessionMeterMetrics.Variant {
    bloomed ? .tall : .compact
  }
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

  static let markTitle = "Mark"
  static let markShortcut = "⌘K"
  static let stopTitle = "Stop"
  static let listening = "Listening…"
  static let markersHeading = "Moments"
  static let noMarkers = "No moments yet"

  /// The count beside the flag in the bar — **nil at zero**, not "0".
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

/// Ghost control: the recording surface's default. Glass, a hairline, no fill.
///
/// Internal for the same reason `RecordingStopButtonStyle` is: it is the
/// control in the test that distinguishes a material from a fill.
struct RecordingGhostButtonStyle: ButtonStyle {
  @Environment(\.colorScheme) private var colorScheme

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(.primary)
      .padding(.horizontal, CraftTokens.spacing16)
      .padding(.vertical, CraftTokens.spacing8)
      .frame(maxWidth: .infinity)
      .craftGlassPanel(in: Capsule(style: .continuous))
      .opacity(configuration.isPressed ? 0.7 : 1)
  }
}

/// The **only** filled control on the recording surface (reference sweep, do
/// #8/#10: the one thing you will definitely do is the one thing you cannot
/// miss). Solid ember, so it reads identically under Reduce Transparency — a
/// glass Stop would go quiet exactly where the material degrades.
/// Internal rather than private so a test can render it under both settings of
/// `accessibilityReduceTransparency` — the claim "Stop survives the material
/// degrading" is about pixels and cannot be asserted about a constant.
struct RecordingStopButtonStyle: ButtonStyle {
  @Environment(\.colorScheme) private var colorScheme

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 14, weight: .semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, CraftTokens.spacing24)
      .padding(.vertical, CraftTokens.spacing12)
      .frame(maxWidth: .infinity)
      .background(CraftTokens.ember(colorScheme), in: Capsule(style: .continuous))
      .opacity(configuration.isPressed ? 0.85 : 1)
  }
}

// MARK: - Session controls

/// Mark and Stop. One definition, both states of the bar — the bloom changes
/// how much room the clock takes, it does not give the owner a different set of
/// buttons.
private struct SessionControls: View {
  let isStoppable: Bool
  let onMark: () -> Void
  let onStop: () -> Void

  var body: some View {
    Group {
      Button(action: onMark) {
        HStack(spacing: CraftTokens.spacing8) {
          Text(RecordingPaneCopy.markTitle)
          Text(RecordingPaneCopy.markShortcut)
            .font(CraftTokens.shortcutFont)
            .foregroundStyle(.secondary)
        }
      }
      .buttonStyle(RecordingGhostButtonStyle())
      .keyboardShortcut("k", modifiers: .command)
      .disabled(!isStoppable)

      Button(action: onStop) {
        Text(RecordingPaneCopy.stopTitle)
      }
      .buttonStyle(RecordingStopButtonStyle())
      .disabled(!isStoppable)
    }
  }
}

// MARK: - Marker list

/// The flagged moments, newest first — the contents of the bar's popover
/// (owner's call, 2026-08-10: "markers are a count in the bar that opens a
/// popover", not hairlines down the transcript).
///
/// The list used to sit at the bottom of the session column, and a bar has no
/// bottom to put it at. The popover is what the column's height was buying:
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
        .foregroundStyle(.secondary)
        .textCase(.uppercase)

      if markers.isEmpty {
        Text(RecordingPaneCopy.noMarkers)
          .font(RecordingPaneMetrics.markerLabelFont)
          .foregroundStyle(.tertiary)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: CraftTokens.spacing8) {
            ForEach(markers) { marker in
              HStack(spacing: CraftTokens.spacing8) {
                Text(LiveTranscript.timestamp(marker.at))
                  .font(RecordingPaneMetrics.markerTimeFont)
                  .foregroundStyle(.secondary)
                if let label = RecordingPaneCopy.markerLabel(marker) {
                  Text(label)
                    .font(RecordingPaneMetrics.markerLabelFont)
                    .foregroundStyle(.primary)
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

// MARK: - The session bar

/// The recording bar: everything the session column held, in one full-width row
/// above the transcript (XIA-444).
///
/// Reading order left to right is the session, then what to do about it — the
/// breathing dot, the meter, the clock, the kind line, then past the gap the
/// moment count, `Mark ⌘K` and `Stop`. That is the column's own top-to-bottom
/// order laid on its side, deliberately: the column was not wrong about what
/// matters, it was wrong about spending a quarter of every window to say it.
///
/// Two things it does that the column did not:
///
/// - **The moments are a count that opens a popover**, not a list the surface
///   has to find room for. A bar has no bottom to accumulate at, and "a list
///   that grows must not push the fixed things around" was the column's own
///   reason for putting the list last.
/// - **The clock blooms on hover.** At rest it is a 22pt caption on a row; with
///   the pointer over the bar the whole bar grows into a taller card carrying
///   the 58pt clock the column made the session's object. Nothing is *only*
///   available bloomed — the clock is legible in both states and every control
///   keeps its place — so a pointer that never arrives costs the owner nothing.
struct SessionBarView: View {
  let elapsed: TimeInterval
  /// The meter's own object. Passed rather than a `Float` so the level's ~15 Hz
  /// feed is observed by `SessionMeterFeedView` alone — see `MeterPublishGate`.
  let level: MicLevelFeed
  let kind: HistoryKind
  let controls: LiveMeetingControls
  let markers: [SessionMarker]
  let onMark: () -> Void
  let onStop: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// The bloom, and the popover, are **this view's** state and not the pane's.
  /// A pointer crossing the bar may not invalidate `LiveMeetingView`'s body:
  /// that body draws the transcript, and XIA-432 is this file's whole account
  /// of what a frequent change costs when a broad observer is watching.
  @State private var bloomed = false
  @State private var showingMoments = false

  var body: some View {
    HStack(spacing: CraftTokens.spacing16) {
      SessionRing(
        diameter: RecordingPaneMetrics.dotDiameter,
        lineWidth: RecordingPaneMetrics.dotLineWidth
      )
      SessionMeterFeedView(
        feed: level,
        variant: RecordingPaneLayout.meterVariant(bloomed: bloomed)
      )
      SessionTimer(elapsed: elapsed, base: RecordingPaneLayout.timerBase(bloomed: bloomed))

      Text(RecordingPaneCopy.kindLine(kind: kind, controls: controls))
        .font(RecordingPaneMetrics.kindLineFont)
        .foregroundStyle(.secondary)
        .lineLimit(1)

      Spacer(minLength: CraftTokens.spacing16)

      momentsButton

      HStack(spacing: CraftTokens.spacing12) {
        SessionControls(
          isStoppable: controls == .stop,
          onMark: onMark,
          onStop: onStop
        )
      }
      .fixedSize(horizontal: true, vertical: false)
    }
    .padding(.horizontal, RecordingPaneMetrics.barPaddingH)
    .padding(.vertical, RecordingPaneMetrics.barPaddingV)
    // `minHeight`, not `height`: the arithmetic says how tall the bar means to
    // be, and a control that ever measured taller than that would be clipped by
    // a hard frame instead of being given its row.
    .frame(maxWidth: .infinity, minHeight: RecordingPaneMetrics.barHeight(bloomed: bloomed))
    .onHover { inside in
      // Reduce Motion is answered by `RecordingMotion`, which hands back nil —
      // and `withAnimation(nil)` is a snap. The decision belongs there beside
      // the ring's and the meter's, not in an `if` here, or the next surface
      // that blooms would have to rediscover which way this one went.
      withAnimation(RecordingMotion.bloomAnimation(reduceMotion: reduceMotion)) {
        bloomed = inside
      }
    }
  }

  /// The flag, its count, and the popover the count opens. A ghost control like
  /// Mark: Stop is still the only filled thing on the surface.
  private var momentsButton: some View {
    Button {
      showingMoments.toggle()
    } label: {
      HStack(spacing: CraftTokens.spacing8) {
        Image(systemName: "flag")
        if let count = RecordingPaneCopy.markerCount(markers) {
          Text(count).monospacedDigit()
        }
      }
    }
    .buttonStyle(RecordingGhostButtonStyle())
    .fixedSize(horizontal: true, vertical: false)
    .accessibilityLabel(RecordingPaneCopy.markersHeading)
    .popover(isPresented: $showingMoments, arrowEdge: .bottom) {
      SessionMarkerList(markers: markers)
    }
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
        .padding(.vertical, RecordingPaneMetrics.transcriptPaddingV)
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
        .foregroundStyle(.secondary)
      Text(RecordingPaneCopy.listening)
        .font(RecordingPaneMetrics.transcriptFont)
        .foregroundStyle(.secondary)
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
        .foregroundStyle(.tertiary)
        .frame(width: RecordingPaneMetrics.gutterWidth, alignment: .trailing)

      switch row.content {
      case .speaker(let name):
        Text(name)
          .font(RecordingPaneMetrics.speakerFont)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      case .line(let line):
        Text(line.text)
          .font(RecordingPaneMetrics.transcriptFont)
          .foregroundStyle(.primary)
          .opacity(line.isVolatile ? RecordingPaneMetrics.volatileOpacity : 1)
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
        VStack(spacing: 0) {
          SessionBarView(
            elapsed: 754,
            level: MicLevelFeed(level: 0.6),
            kind: kind,
            controls: .stop,
            markers: [SessionMarker(at: 612), SessionMarker(at: 208)],
            onMark: {},
            onStop: {}
          )
          Divider()
          LiveTranscriptView(rows: previewRows(), volatileID: LiveTranscript.volatileLineID)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// The bloom is a hover state, so a preview cannot show it — this is the card
/// it grows into, drawn at the size `barHeight(bloomed: true)` reserves.
#Preview("recording bar – bloomed") {
  CraftWashBackground()
    .overlay(
      VStack(spacing: 0) {
        SessionBarView(
          elapsed: 3754,
          level: MicLevelFeed(level: 0.6),
          kind: .memo,
          controls: .stop,
          markers: [],
          onMark: {},
          onStop: {}
        )
        .frame(height: RecordingPaneMetrics.barHeight(bloomed: true))
        Divider()
        LiveTranscriptView(rows: previewRows(), volatileID: LiveTranscript.volatileLineID)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    )
    .frame(width: 980, height: 520)
    .preferredColorScheme(.dark)
}
#endif
