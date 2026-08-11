import SwiftUI

// MARK: - Form

/// Which shape the session controls take. Two values, not a spectrum: the
/// column and the strip are different arrangements of the *same* elements, and
/// a continuously-resizing third thing would have no baseline to pin.
enum RecordingPaneForm: Equatable, CaseIterable {
  /// The trailing session column beside a full-height transcript.
  case column
  /// A one-row strip above the transcript, for a window too narrow to give the
  /// column its width without starving the text.
  case strip
}

// MARK: - Metrics

/// Everything about the B2 recording pane that is arithmetic, kept out of the
/// views for the reason `SessionTimerMetrics` and `HUDPrompterMetrics` are: a
/// test can then answer "does the ring fit the column" without a window server.
enum RecordingPaneMetrics {
  // MARK: The column

  /// The trailing session column.
  ///
  /// **Trailing** is XIA-423's locked visual direction, and it is worth being
  /// precise about what does *not* justify it: the original rationale said ⌘L
  /// owns this window's left edge, and it does not — `ContentView
  /// .historyDrawerLayer` is a `ZStack(alignment: .topTrailing)`, so the drawer
  /// opens on the **right**, exactly over this column. See "the drawer and the
  /// column share an edge" in CLAUDE.md for the options and the call.
  static let columnWidth: CGFloat = 288
  static let columnPadding: CGFloat = CraftTokens.spacing24

  /// The hairline between the two panes. Named because the fold arithmetic
  /// spends it.
  static let dividerWidth: CGFloat = 1

  /// What the transcript needs to still be a transcript.
  ///
  /// 520 leaves 408pt of text once the gutter (52), its gap (12) and the two
  /// 24pt margins are paid — about 56 characters at 14pt, the low end of a
  /// readable measure. Under it the transcript is a column of fragments, and a
  /// column of fragments is worse than no session column.
  static let transcriptMinWidth: CGFloat = 520

  /// The pane width below which the column folds. **Derived** from what the
  /// transcript needs rather than typed in, and that is the whole correction:
  /// the previous hand-picked 720 was measured against the *pane*, and since
  /// `Metrics.windowMinWidth` is 780 and the ⌘L drawer is an overlay that
  /// consumes no width, no window this app allows could ever reach it — the
  /// fold was unreachable code with a test that said otherwise.
  ///
  /// 288 + 1 + 520 = 809, so the fold is what happens at the narrowest window
  /// the app permits, which is precisely the case it exists for: at 780 the
  /// column would leave the transcript 491pt.
  static var foldWidth: CGFloat { columnWidth + dividerWidth + transcriptMinWidth }

  /// The timer's `mm:ss` size in each form. 58 is the column's headline — the
  /// timer is the session's *object*, not a caption on it. `SessionTimerMetrics`
  /// derives the hour form from this and reserves the wider of the two, so the
  /// step at the hour costs no reflow (XIA-431); nothing here re-derives it.
  static let columnTimerBase: CGFloat = 58
  static let stripTimerBase: CGFloat = 26

  /// Breathing room between the ring's stroke and the timer's reserved plate.
  static let ringInset: CGFloat = 8

  /// How much of the timer's point size the ring actually has to clear.
  ///
  /// Not 1.0 and not the line height: the timer draws **monospaced digits and
  /// a colon**, which have neither ascenders nor descenders, so a ring sized to
  /// the line box would be sized to whitespace. Measured against SF Mono's cap
  /// height with room to spare — the consequence of getting it wrong is a ring
  /// 30pt larger than the thing it encircles, which reads as a balloon around a
  /// clock rather than a ring on one.
  static let ringGlyphHeightRatio: CGFloat = 0.75

  /// The ring is sized to **contain** the timer's reserved plate at its widest
  /// form, so crossing the hour changes the glyphs and not the circle. Derived
  /// rather than typed in: a hand-picked diameter goes stale the first time the
  /// base size moves, and the failure mode is a clipped clock.
  static var ringDiameter: CGFloat {
    min(ringDiameterNeeded, columnWidth - 2 * columnPadding)
  }

  /// What a circle would have to be to hold the plate — before the column's own
  /// width gets a say. `ringDiameter` clamps to the column; this is the number
  /// the clamp is checked against.
  static var ringDiameterNeeded: CGFloat {
    // The reserved plate, at its widest form — never the current elapsed time,
    // or crossing the hour would resize the circle.
    let width = SessionTimerMetrics.plateWidth(base: columnTimerBase)
    let height = (columnTimerBase * ringGlyphHeightRatio).rounded(.up)
    // The diagonal *is* the diameter: the box's corner sits on the circle.
    return ((width * width + height * height).squareRoot() + 2 * ringInset).rounded(.up)
  }

  static let ringLineWidth: CGFloat = 2

  // MARK: The strip

  /// The folded form's ring is a breathing **dot**, not a circle around the
  /// clock: a ring that contained a 26pt timer would be ~114pt tall and a strip
  /// is not. The element survives the fold — including its Reduce Motion rule —
  /// at the size the compact recording composition already uses.
  static let stripRingDiameter: CGFloat = 20
  static let stripRingLineWidth: CGFloat = 1.5
  static let stripMinHeight: CGFloat = 64
  static let stripPaddingH: CGFloat = CraftTokens.spacing24
  static let stripPaddingV: CGFloat = CraftTokens.spacing12

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
  // match the HUD prompter, and over the ground that is an unmeasured alpha one
  // point under `GroundInk.Tier.timestamp` — so the transcript draws the tail at
  // that tier instead, and every alpha the transcript spends is one the sweep
  // solved. The HUD keeps its own 55%: that is white text on a dark glass plate,
  // not ink on the field, and it was never in this measurement.
}

// MARK: - Layout decisions

/// The pure half of "what shape is the pane in". A `GeometryReader` supplies
/// the width and nothing else decides anything.
enum RecordingPaneLayout {
  /// What the transcript is left with once the column and the divider are paid.
  static func transcriptWidth(paneWidth: CGFloat) -> CGFloat {
    paneWidth - RecordingPaneMetrics.columnWidth - RecordingPaneMetrics.dividerWidth
  }

  /// The fold, stated as the thing it is protecting: the column folds exactly
  /// when keeping it would starve the transcript.
  static func form(width: CGFloat) -> RecordingPaneForm {
    transcriptWidth(paneWidth: width) < RecordingPaneMetrics.transcriptMinWidth ? .strip : .column
  }

  /// The timer's `mm:ss` size in this form. Read by the views — a metric only a
  /// test consults is a metric the views are free to disagree with, which is
  /// what these three were.
  static func timerBase(_ form: RecordingPaneForm) -> CGFloat {
    switch form {
    case .column: return RecordingPaneMetrics.columnTimerBase
    case .strip: return RecordingPaneMetrics.stripTimerBase
    }
  }

  static func meterVariant(_ form: RecordingPaneForm) -> SessionMeterMetrics.Variant {
    switch form {
    case .column: return .tall
    case .strip: return .compact
    }
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

// MARK: - Session controls (shared by both forms)

/// Mark and Stop. One definition, both forms — the fold rearranges the pane, it
/// does not give the owner a different set of buttons.
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

/// The flagged moments, newest first, at the bottom of the column.
struct SessionMarkerList: View {
  let markers: [SessionMarker]

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
        // Deliberately not its own `ScrollView`: the column already scrolls
        // (`SessionColumnView`), and two scroll views nested on the same axis
        // fight over every wheel event. The list simply grows and the column
        // carries it.
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
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - Session column (the unfolded form)

/// The trailing session column: timer in the ring, meter, kind line, controls,
/// markers.
///
/// The order is the argument. The timer is at the top and it is the largest
/// thing on the surface because it is the session's *object* — in a
/// conversation what matters is the indicator that things are flowing, and the
/// transcript should not have to pay for it. The meter under it is
/// **information**, not decoration: it is the only proof the microphone is
/// actually open. The markers are at the bottom because they accumulate, and a
/// list that grows must not push the fixed things around.
struct SessionColumnView: View {
  let elapsed: TimeInterval
  /// The meter's own object. Passed rather than a `Float` so the level's ~15 Hz
  /// feed is observed by `SessionMeterFeedView` alone — see `MeterPublishGate`.
  let level: MicLevelFeed
  let kind: HistoryKind
  let controls: LiveMeetingControls
  let markers: [SessionMarker]
  let onMark: () -> Void
  let onStop: () -> Void

  /// The column is **taller than the smallest window this app allows**
  /// (`SessionColumnContent`'s natural height against
  /// `Metrics.windowMinHeight`), which is the arithmetic this wrapper exists
  /// for and the reason it is not a plain `VStack`.
  ///
  /// Shrinking the design to fit 560pt was the alternative and it was worse:
  /// the ring is sized from the timer's reserved plate, so the only way to buy
  /// the height back is to make the timer smaller — and the timer being the
  /// largest thing on the surface is the whole argument for the column. So the
  /// column keeps its size and a window too short for it **scrolls**, rather
  /// than clipping the marker list to a half-drawn heading. `minHeight` is what
  /// keeps the ordinary case identical to the design: with room to spare the
  /// content fills the container and the `Spacer` still pins the markers to the
  /// bottom, exactly as if the scroll view were not there.
  var body: some View {
    GeometryReader { proxy in
      ScrollView {
        SessionColumnContent(
          elapsed: elapsed,
          level: level,
          kind: kind,
          controls: controls,
          markers: markers,
          onMark: onMark,
          onStop: onStop
        )
        .frame(minHeight: proxy.size.height, alignment: .top)
      }
      .scrollIndicators(.never)
      .scrollBounceBehavior(.basedOnSize)
    }
    .frame(width: RecordingPaneMetrics.columnWidth)
  }
}

/// The column's contents, un-scrolled. Separate so its natural height is a
/// thing a test can measure — that measurement is what justifies the wrapper.
struct SessionColumnContent: View {
  /// This view's form, so every per-form number comes from
  /// `RecordingPaneLayout` rather than being restated here. The two used to be
  /// independent — the layout knew the timer base and the meter variant, and
  /// the views hardcoded them, so the helpers were true only for the tests that
  /// read them.
  private let form: RecordingPaneForm = .column

  let elapsed: TimeInterval
  let level: MicLevelFeed
  let kind: HistoryKind
  let controls: LiveMeetingControls
  let markers: [SessionMarker]
  let onMark: () -> Void
  let onStop: () -> Void

  var body: some View {
    VStack(spacing: CraftTokens.spacing24) {
      SessionRing(
        diameter: RecordingPaneMetrics.ringDiameter,
        lineWidth: RecordingPaneMetrics.ringLineWidth
      )
      .overlay(SessionTimer(elapsed: elapsed, base: RecordingPaneLayout.timerBase(form)))

      SessionMeterFeedView(feed: level, variant: RecordingPaneLayout.meterVariant(form))

      Text(RecordingPaneCopy.kindLine(kind: kind, controls: controls))
        .font(RecordingPaneMetrics.kindLineFont)
        .foregroundStyle(.ground(.speaker))

      VStack(spacing: CraftTokens.spacing12) {
        SessionControls(
          isStoppable: controls == .stop,
          onMark: onMark,
          onStop: onStop
        )
      }

      Spacer(minLength: CraftTokens.spacing16)

      SessionMarkerList(markers: markers)
    }
    .padding(RecordingPaneMetrics.columnPadding)
    .frame(width: RecordingPaneMetrics.columnWidth, alignment: .top)
  }
}

// MARK: - Session strip (the folded form)

/// The folded form: one row, everything the column had except the marker list.
///
/// It has **no `markers` parameter**, and that is the fold's one loss written
/// where the compiler enforces it. A `showsMarkerList(_:)` predicate used to
/// say the same thing in a place only a test read, which made it a claim rather
/// than a constraint.
struct SessionStripView: View {
  private let form: RecordingPaneForm = .strip

  let elapsed: TimeInterval
  let level: MicLevelFeed
  let kind: HistoryKind
  let controls: LiveMeetingControls
  let onMark: () -> Void
  let onStop: () -> Void

  var body: some View {
    HStack(spacing: CraftTokens.spacing16) {
      SessionRing(
        diameter: RecordingPaneMetrics.stripRingDiameter,
        lineWidth: RecordingPaneMetrics.stripRingLineWidth
      )
      SessionMeterFeedView(feed: level, variant: RecordingPaneLayout.meterVariant(form))
      SessionTimer(elapsed: elapsed, base: RecordingPaneLayout.timerBase(form))

      Text(RecordingPaneCopy.kindLine(kind: kind, controls: controls))
        .font(RecordingPaneMetrics.kindLineFont)
        .foregroundStyle(.ground(.speaker))
        .lineLimit(1)

      Spacer(minLength: CraftTokens.spacing16)

      HStack(spacing: CraftTokens.spacing12) {
        SessionControls(
          isStoppable: controls == .stop,
          onMark: onMark,
          onStop: onStop
        )
      }
      .fixedSize(horizontal: true, vertical: false)
    }
    .padding(.horizontal, RecordingPaneMetrics.stripPaddingH)
    .padding(.vertical, RecordingPaneMetrics.stripPaddingV)
    .frame(maxWidth: .infinity, minHeight: RecordingPaneMetrics.stripMinHeight)
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
        // It used to be body at 55%, which is a number nobody measured: against
        // the solved table it lands a hair under the timestamp tier's 56% —
        // i.e. just below the 3.0:1 bar the dimmest readable text is held to,
        // on the one line that is being read while it is written. The tier is
        // visually the same dimming and is on the measured side of it.
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
  let form: RecordingPaneForm

  var body: some View {
    CraftWashBackground()
      .overlay(content)
  }

  @ViewBuilder
  private var content: some View {
    switch form {
    case .column:
      HStack(spacing: 0) {
        LiveTranscriptView(rows: previewRows(), volatileID: LiveTranscript.volatileLineID)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        Divider()
        SessionColumnView(
          elapsed: 754,
          level: MicLevelFeed(level: 0.6),
          kind: .meeting,
          controls: .stop,
          markers: [SessionMarker(at: 612), SessionMarker(at: 208)],
          onMark: {},
          onStop: {}
        )
      }
    case .strip:
      VStack(spacing: 0) {
        SessionStripView(
          elapsed: 754,
          level: MicLevelFeed(level: 0.6),
          kind: .memo,
          controls: .stop,
          onMark: {},
          onStop: {}
        )
        Divider()
        LiveTranscriptView(rows: previewRows(), volatileID: LiveTranscript.volatileLineID)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }
}

#Preview("recording pane – column, light") {
  RecordingPaneGallery(form: .column)
    .frame(width: 980, height: 620)
    .preferredColorScheme(.light)
}

#Preview("recording pane – column, dark") {
  RecordingPaneGallery(form: .column)
    .frame(width: 980, height: 620)
    .preferredColorScheme(.dark)
}

#Preview("recording pane – folded strip") {
  RecordingPaneGallery(form: .strip)
    .frame(width: 640, height: 520)
    .preferredColorScheme(.dark)
}
#endif
