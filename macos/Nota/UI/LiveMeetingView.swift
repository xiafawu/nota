import SwiftUI

// MARK: - Live meeting presentation helpers

/// Pure local formatting rules for the live meeting pane: the elapsed clock and
/// the session-state label. Deterministic and I/O-free so the mapping can be
/// asserted without a microphone or network.
enum LiveMeetingFormat {
  /// "mm:ss" under an hour, "h:mm:ss" beyond — the meeting-timer convention.
  /// Fractional seconds truncate; negative intervals clamp to zero.
  ///
  /// This *is* `SessionTimerMetrics.text` and delegates to it rather than
  /// keeping a second copy of the same arithmetic. They were written
  /// independently and agreed by luck; the gutter timestamp beside a transcript
  /// line and the big clock in the column name the same instant, and two
  /// implementations of "the same instant" is a disagreement waiting for a
  /// rounding change.
  static func duration(_ interval: TimeInterval) -> String {
    SessionTimerMetrics.text(elapsed: interval)
  }

  /// Short state label. `.failed` carries its own message (rendered by the
  /// error banner), so the label stays generic here.
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
enum LiveMeetingControls: Equatable, CaseIterable {
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

  /// Whether the two-column recording pane is what this state shows. A failed
  /// session is deliberately **not** on it: the column is the indicator that a
  /// session is flowing, and nothing is. What that state needs is the
  /// transcript it heard and one decision about it, which is the banner.
  var showsRecordingPane: Bool {
    self == .stop || self == .finalizing
  }
}

/// Live dictation pane, in the locked B2 arrangement (XIA-423 / XIA-432): a
/// trailing session column beside a full-height transcript.
///
/// **Trailing**, because ⌘L — the history drawer — owns this window's left
/// edge. **A column** rather than a band across the top, because in a
/// conversation what matters is the indicator that things are flowing, and a
/// band takes that out of the transcript's height to say it. The timer inside
/// the ring is the session's *object*, not a caption on it; the meter beside it
/// is information rather than decoration, which is why Reduce Motion stops the
/// ring breathing and never stops the meter (`RecordingMotion`).
///
/// Owns no session state — it renders `session` and forwards the affordances
/// through `onStart` / `onStop` / `onDiscard` so the model stays the single
/// owner of the lifecycle.
struct LiveMeetingView: View {
  @ObservedObject var session: LiveMeetingSession
  /// Session kind. It reaches the surface as **one word** and nothing else:
  /// no mode chrome, no toggle, no segmented control, and above all no change
  /// to the accent — a kind is relabelable after the fact, and a color that
  /// moved with it would be lying about a record the owner reclassified.
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

  /// The session's flagged moments. Session-local and not persisted — the UI
  /// slot is this ticket's, the plumbing is XIA-433's. See `SessionMarkerLog`.
  @StateObject private var markerLog = SessionMarkerLog()

  /// What the pane offers right now. One decision, read by the column, the
  /// transcript and the banner, so they cannot disagree about which state
  /// this is.
  private var controls: LiveMeetingControls {
    LiveMeetingControls.make(
      state: session.state,
      isStarting: isStarting,
      hasTranscript: !session.segments.isEmpty
    )
  }

  private var blocks: [LiveTranscriptBlock] {
    LiveTranscript.blocks(
      LiveTranscript.lines(
        segments: session.segments,
        partial: session.partialText,
        elapsed: session.elapsed
      )
    )
  }

  private var volatileID: UUID? {
    (session.partialText?.isEmpty ?? true) ? nil : LiveTranscript.volatileLineID
  }

  var body: some View {
    GeometryReader { geometry in
      let form = RecordingPaneLayout.form(width: geometry.size.width)
      Group {
        // `showsRecordingPane` rather than a second list of cases here: which
        // states wear the column is a decision a test can reach, and a switch
        // that answered it again would be free to drift from the one that did.
        if controls.showsRecordingPane {
          recordingPane(form: form)
        } else if controls == .start {
          idleView
        } else if controls == .starting {
          startingView
        } else {
          failedView
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(CraftWashBackground())
    // A marker belongs to the session that flagged it; a new one starts empty.
    .onChange(of: session.state) { old, new in
      if new == .recording, old != .recording { markerLog.reset() }
    }
  }

  // MARK: - The recording pane (B2)

  @ViewBuilder
  private func recordingPane(form: RecordingPaneForm) -> some View {
    switch form {
    case .column:
      HStack(spacing: 0) {
        transcript
        Divider()
        SessionColumnView(
          elapsed: session.elapsed,
          level: session.micLevel,
          kind: kind,
          controls: controls,
          markers: markerLog.markers,
          onMark: mark,
          onStop: onStop
        )
      }
    case .strip:
      VStack(spacing: 0) {
        SessionStripView(
          elapsed: session.elapsed,
          level: session.micLevel,
          kind: kind,
          controls: controls,
          onMark: mark,
          onStop: onStop
        )
        Divider()
        transcript
      }
    }
  }

  private var transcript: some View {
    LiveTranscriptView(blocks: blocks, volatileID: volatileID)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func mark() {
    markerLog.mark(at: session.elapsed)
  }

  // MARK: - Starting (press accepted, session not live yet)

  private var startingView: some View {
    centeredState {
      ProgressView().controlSize(.large)
      Text(LiveMeetingFormat.stateLabel(session.state, isStarting: true))
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Idle (nothing running)

  private var idleView: some View {
    centeredState {
      SessionRing(
        diameter: RecordingPaneMetrics.stripRingDiameter,
        lineWidth: RecordingPaneMetrics.stripRingLineWidth
      )
      Text(RecordingPaneCopy.kindLine(kind: kind, controls: .start))
        .font(RecordingPaneMetrics.kindLineFont)
        .foregroundStyle(.secondary)
      Button(action: onStart) {
        Label("Start Recording", systemImage: "mic.fill")
          .padding(.horizontal, CraftTokens.spacing12)
      }
      .controlSize(.large)
      .liquidGlassButton()
    }
  }

  private func centeredState<Content: View>(
    @ViewBuilder _ content: () -> Content
  ) -> some View {
    VStack(spacing: CraftTokens.spacing16) {
      Spacer()
      content()
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(CraftTokens.spacing32)
  }

  // MARK: - Failed (banner over whatever was heard)

  private var failedView: some View {
    VStack(spacing: 0) {
      if case .failed(let message) = session.state {
        errorBanner(message: message)
      }
      transcript
    }
  }

  private func errorBanner(message: String) -> some View {
    HStack(alignment: .top, spacing: CraftTokens.spacing12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)

      VStack(alignment: .leading, spacing: CraftTokens.spacing4) {
        Text(LiveMeetingFormat.stateLabel(.failed(message)))
          .font(.system(size: 13, weight: .medium))
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: CraftTokens.spacing12)

      HStack(spacing: CraftTokens.spacing8) {
        if controls == .saveOrDiscard {
          // The session heard something before it dropped, and `stop()`
          // accepts a failed session so that transcript can still be sealed.
          // Without this the pane was a dead end: no Stop, no route to the
          // seal, and a record left saying `recording`.
          Button("Save Transcript", action: onStop).liquidGlassButton()
        }
        Button("Try Again", action: onStart).liquidGlassButton()
        // Not `session.cancel()`: the record on disk has to come to rest at a
        // terminal status (keeping its audio), and only the model owns it.
        Button("Discard", action: onDiscard).liquidGlassButton()
      }
      .fixedSize(horizontal: true, vertical: false)
    }
    .padding(CraftTokens.spacing16)
    .craftGlassPanel(
      in: RoundedRectangle(cornerRadius: CraftTokens.spacing12, style: .continuous),
      tint: .red
    )
    .padding(CraftTokens.spacing16)
  }
}

#if DEBUG
#Preview("live meeting idle") {
  LiveMeetingView(
    session: NotaModel().liveSession,
    onStart: {},
    onStop: {}
  )
  .frame(width: 980, height: 620)
}
#endif
