import SwiftUI

// MARK: - Live meeting presentation helpers

/// Pure local formatting rules for the live meeting pane: the elapsed timer
/// and the session-state label. Deterministic and I/O-free so the mapping can
/// be asserted without a microphone or network.
enum LiveMeetingFormat {
  /// "mm:ss" under an hour, "h:mm:ss" beyond — the meeting-timer convention.
  /// Fractional seconds truncate; negative intervals clamp to zero.
  static func duration(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%02d:%02d", minutes, seconds)
  }

  /// Short state label for the pane header. `.failed` carries its own message
  /// (rendered by the error banner), so the label stays generic here.
  ///
  /// `isStarting` wins over `.idle`, and that is the point: the session stays
  /// `.idle` across the microphone prompt and the whole realtime open + Begin
  /// round trip, so a pane that showed "Ready" for those seconds was telling
  /// the user their press had not registered — and a second press is what lost
  /// a meeting's transcript (XIA-430).
  static func stateLabel(
    _ state: LiveMeetingSession.SessionState,
    isStarting: Bool = false
  ) -> String {
    if isStarting, state == .idle { return "Starting…" }
    switch state {
    case .idle: return "Ready"
    case .recording: return "Recording"
    case .stopping: return "Finalizing…"
    case .failed: return "Recording failed"
    }
  }
}

/// Which affordances the live pane offers, as a pure decision.
///
/// The rule that matters is the failed one: a session that dropped mid-meeting
/// keeps everything it heard, and `LiveMeetingSession.stop()` accepts a failed
/// session precisely so that transcript can still be sealed. A pane that
/// offered only Try Again and Discard there was a dead end with no route to
/// the seal at all, and the record stayed `recording` for the rest of the run.
enum LiveMeetingControls: Equatable {
  /// Nothing is running: the big Start button.
  case start
  /// A press has been accepted but the session is not live yet.
  case starting
  /// Recording: Stop, enabled.
  case stop
  /// Stopping: Stop, disabled.
  case finalizing
  /// Failed with something to keep: Save Transcript, Try Again, Discard.
  case saveOrDiscard
  /// Failed with nothing to keep: Try Again, Discard.
  case retryOrDiscard

  static func make(
    state: LiveMeetingSession.SessionState,
    isStarting: Bool,
    hasTranscript: Bool
  ) -> LiveMeetingControls {
    switch state {
    case .recording: return .stop
    case .stopping: return .finalizing
    case .failed: return hasTranscript ? .saveOrDiscard : .retryOrDiscard
    case .idle: return isStarting ? .starting : .start
    }
  }
}

/// Live dictation pane: records from the microphone, streams to AssemblyAI,
/// and renders the transcript as it lands. Owns no session state — it renders
/// `session` and forwards the record/stop affordances through `onStart` /
/// `onStop` so the model stays the single owner of the lifecycle.
struct LiveMeetingView: View {
  @ObservedObject var session: LiveMeetingSession
  /// Session kind drives the pane's own title: memo sessions say "Memo".
  var kind: HistoryKind = .meeting
  /// A Start press has been accepted but the session has not gone live yet
  /// (mic permission, then the realtime open + Begin round trip). The pane
  /// says so and withdraws the Start button — the seconds when nothing on
  /// screen changed are the seconds a second press arrived in.
  var isStarting: Bool = false
  let onStart: () -> Void
  let onStop: () -> Void
  /// Throw a failed session away. Not `session.cancel()` from the view: the
  /// record on disk has to be settled to a terminal status, and only the model
  /// owns it.
  var onDiscard: () -> Void = {}

  /// Stable id for the volatile partial-text tail, so the scroll reader can
  /// chase it as it rewrites on every interim recognition update.
  private static let partialTailID = "live-meeting-partial-tail"

  private var paneTitle: String {
    kind == .memo ? "Memo" : "Live Meeting"
  }

  private var paneSubtitle: String {
    kind == .memo
      ? "Record a quick note and get a cleaned write-up."
      : "Record from your microphone and transcribe in real time."
  }

  /// What the pane offers right now. One decision, read by the header, the
  /// body and the banner, so they cannot disagree about which state this is.
  private var controls: LiveMeetingControls {
    LiveMeetingControls.make(
      state: session.state,
      isStarting: isStarting,
      hasTranscript: !session.segments.isEmpty
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      if controls != .start {
        header
        Divider()
      }

      if case .failed(let message) = session.state {
        errorBanner(message: message)
      }

      switch controls {
      case .start:
        idleView
      case .starting:
        startingView
      case .stop, .finalizing, .saveOrDiscard, .retryOrDiscard:
        transcriptView
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .animation(Tokens.animFast, value: session.state)
    .animation(Tokens.animFast, value: isStarting)
  }

  // MARK: - Header (recording / stopping / failed)

  private var header: some View {
    HStack(spacing: Metrics.liveMeetingHeaderSpacing) {
      HStack(spacing: Metrics.liveMeetingRowSpacing) {
        stateIndicator
        Text(LiveMeetingFormat.stateLabel(session.state, isStarting: isStarting))
          .font(Tokens.liveMeetingStateFont)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Text(LiveMeetingFormat.duration(session.elapsed))
        .font(Tokens.liveMeetingTimerFont)
        .foregroundStyle(.primary)
        .monospacedDigit()

      Spacer()

      stopControl
    }
    .padding(.horizontal, Metrics.liveMeetingOuterPadding)
    .padding(.vertical, Metrics.docHeaderTopPadding)
  }

  @ViewBuilder
  private var stateIndicator: some View {
    switch session.state {
    case .idle where isStarting:
      ProgressView()
        .controlSize(.small)
    case .recording:
      Image(systemName: "record.circle.fill")
        .font(.system(size: 16))
        .foregroundStyle(.red)
        .symbolEffect(.pulse, isActive: true)
    case .stopping:
      ProgressView()
        .controlSize(.small)
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 16))
        .foregroundStyle(.red)
    case .idle:
      EmptyView()
    }
  }

  @ViewBuilder
  private var stopControl: some View {
    switch controls {
    case .stop:
      Button {
        onStop()
      } label: {
        Label("Stop", systemImage: "stop.fill")
          .foregroundStyle(.red)
      }
      .liquidGlassButton()
    case .starting, .finalizing:
      Button {} label: {
        Label("Stop", systemImage: "stop.fill")
          .foregroundStyle(.red)
      }
      .disabled(true)
      .liquidGlassButton()
    case .start, .saveOrDiscard, .retryOrDiscard:
      // A failed session's affordances live in the banner, next to the reason
      // they are being offered.
      EmptyView()
    }
  }

  // MARK: - Starting (press accepted, session not live yet)

  private var startingView: some View {
    VStack(spacing: Metrics.emptyMainSpacing) {
      Spacer()
      ProgressView()
        .controlSize(.large)
      Text("Starting…")
        .font(Tokens.liveMeetingCaptionFont)
        .foregroundStyle(.secondary)
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(Metrics.emptyMainOuterPadding)
  }

  // MARK: - Idle (disabled / empty state)

  private var idleView: some View {
    VStack(spacing: Metrics.emptyMainSpacing) {
      Spacer()

      Image(systemName: "mic")
        .font(Tokens.liveMeetingIconFont)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(Tokens.emptyIconColor)

      VStack(spacing: Metrics.emptyTextSpacing) {
        Text(paneTitle)
          .font(Tokens.liveMeetingTitleFont)
          .fontWeight(.bold)
          .foregroundStyle(.primary)

        Text(paneSubtitle)
          .font(Tokens.liveMeetingCaptionFont)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }

      Button {
        onStart()
      } label: {
        Label("Start Recording", systemImage: "mic.fill")
          .padding(.horizontal, Metrics.liveMeetingControlSpacing)
      }
      .controlSize(.large)
      .liquidGlassButton()

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(Metrics.emptyMainOuterPadding)
  }

  // MARK: - Transcript (final segments + volatile partial tail)

  private var transcriptView: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: Metrics.liveMeetingRowSpacing) {
          if session.segments.isEmpty && (session.partialText?.isEmpty ?? true) {
            listeningPlaceholder
          }

          ForEach(session.segments) { segment in
            segmentRow(
              text: segment.text,
              timestamp: LiveMeetingFormat.duration(segment.endTime),
              style: .primary
            )
            .id(segment.id)
          }

          if let partial = session.partialText, !partial.isEmpty {
            segmentRow(
              text: partial,
              timestamp: LiveMeetingFormat.duration(session.elapsed),
              style: .tertiary
            )
            .id(Self.partialTailID)
          }
        }
        .padding(.horizontal, Metrics.richTextInsetX)
        .padding(.vertical, Metrics.richTextInsetY)
      }
      .onChange(of: session.segments.count) { _, _ in
        guard let last = session.segments.last else { return }
        proxy.scrollTo(last.id, anchor: .bottom)
      }
      .onChange(of: session.partialText) { _, _ in
        proxy.scrollTo(Self.partialTailID, anchor: .bottom)
      }
    }
  }

  private var listeningPlaceholder: some View {
    HStack(spacing: Metrics.liveMeetingRowSpacing) {
      Image(systemName: "waveform")
        .symbolEffect(.pulse, isActive: true)
        .foregroundStyle(.secondary)
      Text("Listening…")
        .font(Tokens.liveMeetingCaptionFont)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, Metrics.liveMeetingRowSpacing)
  }

  /// One transcript row: a gutter timestamp mirroring the rich document pane,
  /// then the text. `style` distinguishes final segments (primary) from the
  /// volatile partial tail (tertiary, dimmed).
  private func segmentRow(
    text: String,
    timestamp: String,
    style: HierarchicalShapeStyle
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Metrics.tsGutterTrailingGap) {
      Text(timestamp)
        .font(.caption.monospacedDigit())
        .foregroundStyle(style)
        .frame(width: Metrics.gutterWidth, alignment: .trailing)
      Text(text)
        .font(.body)
        .foregroundStyle(style)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - Failed banner

  private func errorBanner(message: String) -> some View {
    HStack(alignment: .top, spacing: Metrics.liveMeetingBannerSpacing) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)

      VStack(alignment: .leading, spacing: Metrics.tightStackSpacing) {
        Text("Recording failed")
          .font(Tokens.liveMeetingStateFont)
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: Metrics.liveMeetingBannerSpacing)

      HStack(spacing: Metrics.liveMeetingBannerSpacing) {
        if controls == .saveOrDiscard {
          // The session heard something before it dropped, and `stop()`
          // accepts a failed session so that transcript can still be sealed.
          // Without this the pane was a dead end: no Stop in the header, no
          // route to the seal, and a record left saying `recording`.
          Button {
            onStop()
          } label: {
            Text("Save Transcript")
          }
          .liquidGlassButton()
        }
        Button {
          onStart()
        } label: {
          Text("Try Again")
        }
        .liquidGlassButton()
        Button {
          // Not `session.cancel()`: the record on disk has to come to rest at
          // a terminal status (keeping its audio), and only the model owns it.
          onDiscard()
        } label: {
          Text("Discard")
        }
        .liquidGlassButton()
      }
    }
    .padding(Metrics.liveMeetingBannerPadding)
    .background(
      .red.opacity(Tokens.liveMeetingErrorWashOpacity),
      in: RoundedRectangle(cornerRadius: Metrics.cardCornerRadius)
    )
    .padding(.horizontal, Metrics.liveMeetingOuterPadding)
    .padding(.top, Metrics.liveMeetingBannerPadding)
  }
}

#if DEBUG
#Preview("live meeting idle") {
  LiveMeetingView(
    session: NotaModel().liveSession,
    onStart: {},
    onStop: {}
  )
  .frame(width: 720, height: 540)
}
#endif
