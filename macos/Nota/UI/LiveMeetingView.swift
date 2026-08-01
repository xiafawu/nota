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
  static func stateLabel(_ state: LiveMeetingSession.SessionState) -> String {
    switch state {
    case .idle: return "Ready"
    case .recording: return "Recording"
    case .stopping: return "Finalizing…"
    case .failed: return "Recording failed"
    }
  }
}

/// Live dictation pane: records from the microphone, streams to AssemblyAI,
/// and renders the transcript as it lands. Owns no session state — it renders
/// `session` and forwards the record/stop affordances through `onStart` /
/// `onStop` so the model stays the single owner of the lifecycle.
struct LiveMeetingView: View {
  @ObservedObject var session: LiveMeetingSession
  let onStart: () -> Void
  let onStop: () -> Void

  /// Stable id for the volatile partial-text tail, so the scroll reader can
  /// chase it as it rewrites on every interim recognition update.
  private static let partialTailID = "live-meeting-partial-tail"

  var body: some View {
    VStack(spacing: 0) {
      if session.state != .idle {
        header
        Divider()
      }

      if case .failed(let message) = session.state {
        errorBanner(message: message)
      }

      if session.state == .idle {
        idleView
      } else {
        transcriptView
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .animation(Tokens.animFast, value: session.state)
  }

  // MARK: - Header (recording / stopping / failed)

  private var header: some View {
    HStack(spacing: Metrics.liveMeetingHeaderSpacing) {
      HStack(spacing: Metrics.liveMeetingRowSpacing) {
        stateIndicator
        Text(LiveMeetingFormat.stateLabel(session.state))
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
    switch session.state {
    case .recording:
      Button {
        onStop()
      } label: {
        Label("Stop", systemImage: "stop.fill")
          .foregroundStyle(.red)
      }
      .liquidGlassButton()
    case .stopping:
      Button {} label: {
        Label("Stop", systemImage: "stop.fill")
          .foregroundStyle(.red)
      }
      .disabled(true)
      .liquidGlassButton()
    case .idle, .failed:
      // Failed sessions get their retry/discard affordances from the banner.
      EmptyView()
    }
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
        Text("Live Meeting")
          .font(Tokens.liveMeetingTitleFont)
          .fontWeight(.bold)
          .foregroundStyle(.primary)

        Text("Record from your microphone and transcribe in real time.")
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
        Button {
          onStart()
        } label: {
          Text("Try Again")
        }
        .liquidGlassButton()
        Button {
          // Not start/stop: the model's two lifecycle verbs keep ownership of
          // live sessions; cancel is the session's own reset for a failed run.
          session.cancel()
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
