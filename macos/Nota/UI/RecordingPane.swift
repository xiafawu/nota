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

  /// The trailing session column. **Trailing** rather than leading because ⌘L
  /// (the history drawer) owns the left edge of this window, and two surfaces
  /// competing for one edge is a surface the owner has to think about.
  static let columnWidth: CGFloat = 288
  static let columnPadding: CGFloat = CraftTokens.spacing24

  /// The width below which the column stops being worth its 288pt. Under it the
  /// transcript is paying for the session indicator, and the transcript is what
  /// the owner is reading.
  static let foldWidth: CGFloat = 720

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

  /// The volatile tail's opacity — the same 55% the HUD prompter dims its
  /// in-flight run to, so "not final yet" means one thing across the app.
  static let volatileOpacity: Double = 0.55
}

// MARK: - Layout decisions

/// The pure half of "what shape is the pane in". A `GeometryReader` supplies
/// the width and nothing else decides anything.
enum RecordingPaneLayout {
  static func form(width: CGFloat) -> RecordingPaneForm {
    width < RecordingPaneMetrics.foldWidth ? .strip : .column
  }

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

  /// The one thing the fold gives up. Everything else — timer, ring, meter,
  /// kind line, Mark, Stop — survives it, which is why this is a single
  /// predicate rather than a per-element table.
  static func showsMarkerList(_ form: RecordingPaneForm) -> Bool {
    form == .column
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

  /// "mm:ss" / "h:mm:ss" for the gutter — the same clock the timer runs, so a
  /// marker at 12:04 and a transcript line at 12:04 name the same instant.
  static func timestamp(_ interval: TimeInterval) -> String {
    SessionTimerMetrics.text(elapsed: interval)
  }
}

// MARK: - Controls

/// Ghost control: the recording surface's default. Glass, a hairline, no fill.
private struct RecordingGhostButtonStyle: ButtonStyle {
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
private struct RecordingStopButtonStyle: ButtonStyle {
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
        .foregroundStyle(.secondary)
        .textCase(.uppercase)

      if markers.isEmpty {
        Text(RecordingPaneCopy.noMarkers)
          .font(RecordingPaneMetrics.markerLabelFont)
          .foregroundStyle(.tertiary)
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
                .foregroundStyle(.secondary)
              Text(marker.label ?? RecordingPaneCopy.markersHeading)
                .font(RecordingPaneMetrics.markerLabelFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
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
  let level: Float
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
  let elapsed: TimeInterval
  let level: Float
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
      .overlay(SessionTimer(elapsed: elapsed, base: RecordingPaneMetrics.columnTimerBase))

      SessionMeter(level: level, variant: .tall)

      Text(RecordingPaneCopy.kindLine(kind: kind, controls: controls))
        .font(RecordingPaneMetrics.kindLineFont)
        .foregroundStyle(.secondary)

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
struct SessionStripView: View {
  let elapsed: TimeInterval
  let level: Float
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
      SessionMeter(level: level, variant: .compact)
      SessionTimer(elapsed: elapsed, base: RecordingPaneMetrics.stripTimerBase)

      Text(RecordingPaneCopy.kindLine(kind: kind, controls: controls))
        .font(RecordingPaneMetrics.kindLineFont)
        .foregroundStyle(.secondary)
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
  let blocks: [LiveTranscriptBlock]
  /// Chased separately from the block ids: the tail is rewritten on every
  /// interim result and its block's id does not change when it does.
  let volatileID: UUID?

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: RecordingPaneMetrics.blockSpacing) {
          if blocks.isEmpty {
            listeningPlaceholder
          }
          ForEach(blocks) { block in
            blockView(block).id(block.id)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, RecordingPaneMetrics.transcriptPaddingH)
        .padding(.vertical, RecordingPaneMetrics.transcriptPaddingV)
      }
      .onChange(of: blocks.last?.lines.count) { _, _ in
        scrollToNewest(proxy)
      }
      .onChange(of: blocks.last?.lines.last?.text) { _, _ in
        scrollToNewest(proxy)
      }
    }
  }

  private func scrollToNewest(_ proxy: ScrollViewProxy) {
    if let volatileID {
      proxy.scrollTo(volatileID, anchor: .bottom)
    } else if let last = blocks.last {
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

  /// A turn: gutter timestamp, then the speaker name over the text.
  ///
  /// The speaker slot is a real row in this hierarchy rather than a comment
  /// about a future one. Today `block.speaker` is always nil and the row is
  /// simply absent; the day the pipeline fills it, names appear and not one
  /// number in `RecordingPaneMetrics` moves.
  private func blockView(_ block: LiveTranscriptBlock) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: RecordingPaneMetrics.gutterGap) {
      Text(LiveTranscript.timestamp(block.startedAt))
        .font(RecordingPaneMetrics.gutterFont)
        .foregroundStyle(.tertiary)
        .frame(width: RecordingPaneMetrics.gutterWidth, alignment: .trailing)

      VStack(alignment: .leading, spacing: RecordingPaneMetrics.lineSpacing) {
        if let speaker = block.speaker {
          Text(speaker)
            .font(RecordingPaneMetrics.speakerFont)
            .foregroundStyle(.secondary)
        }
        ForEach(block.lines) { line in
          Text(line.text)
            .font(RecordingPaneMetrics.transcriptFont)
            .foregroundStyle(.primary)
            .opacity(line.isVolatile ? RecordingPaneMetrics.volatileOpacity : 1)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(line.id)
        }
      }
    }
  }
}

// MARK: - Previews

#if DEBUG
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
        LiveTranscriptView(blocks: previewBlocks(), volatileID: LiveTranscript.volatileLineID)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        Divider()
        SessionColumnView(
          elapsed: 754,
          level: 0.6,
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
          level: 0.6,
          kind: .memo,
          controls: .stop,
          onMark: {},
          onStop: {}
        )
        Divider()
        LiveTranscriptView(blocks: previewBlocks(), volatileID: LiveTranscript.volatileLineID)
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
