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

  /// Whether the recording cluster is what this state shows. A failed session
  /// is deliberately **not** on it: the cluster is the indicator that a session
  /// is flowing, and nothing is. What that state needs is the transcript it
  /// heard and one decision about it, which is the banner.
  var showsRecordingPane: Bool {
    self == .stop || self == .finalizing
  }
}

/// Live dictation pane (XIA-423 / XIA-432, rearranged by XIA-444, rebuilt by
/// XIA-445): a **cluster of three glass capsules** floating at the bottom of a
/// full-window transcript.
///
/// It was a 288pt trailing column, then a full-width bar, and each step gave
/// the transcript back an axis the indicator had been charging it for — first
/// width, now height. The column's argument survives both: in a conversation
/// what matters is the indicator that things are flowing, which is why the
/// cluster still carries the clock and the meter. What did not survive is
/// spending any of the reading surface on it. The transcript runs the whole
/// window and reserves the cluster's footprint at the bottom, so the words are
/// never behind glass and the glass never pushes the words.
///
/// The meter is information rather than decoration, which is why Reduce Motion
/// stops the ring breathing and never stops the meter (`RecordingMotion`).
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
  /// Throw a failed session away. Not `session.cancel()` from the view: only
  /// the model owns the record on disk, and Discard now DELETES it — the
  /// record, its assets folder and the recording (XIA-436). Asked for
  /// confirmation first, by `discardConfirmation`.
  var onDiscard: () -> Void = {}
  /// Bytes recorded so far, for that confirmation. A closure because the size
  /// is a stat of a file the model owns, and it is read when the dialog opens
  /// rather than on every render of a pane that redraws per transcript turn.
  var discardAudioBytes: () -> Int? = { nil }

  @State private var confirmingDiscard = false

  /// The session's flagged moments. Session-local and not persisted — the UI
  /// slot is this ticket's, the plumbing is XIA-433's. See `SessionMarkerLog`.
  @StateObject private var markerLog = SessionMarkerLog()

  /// The transcript's row model, memoized. It maps every segment of the
  /// session, so it may not be rebuilt by a render the transcript did not
  /// cause. Deliberately a plain `@State` reference and not a `@StateObject`:
  /// it publishes nothing, it only remembers.
  @State private var rowCache = LiveTranscriptRowCache()

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

  private var rows: [LiveTranscriptRow] {
    rowCache.rows(
      segments: session.segments,
      partial: session.partialText,
      elapsed: session.elapsed
    )
  }

  private var volatileID: UUID? {
    (session.partialText?.isEmpty ?? true) ? nil : LiveTranscript.volatileLineID
  }

  var body: some View {
    // No `GeometryReader`: the only thing that ever read the pane's width was
    // the fold, and a bar has no fold — it takes the width it is given at every
    // window this app allows (XIA-444).
    Group {
      // `showsRecordingPane` rather than a second list of cases here: which
      // states wear the bar is a decision a test can reach, and a switch that
      // answered it again would be free to drift from the one that did.
      if controls.showsRecordingPane {
        recordingPane
      } else if controls == .start {
        idleView
      } else if controls == .starting {
        startingView
      } else {
        failedView
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(FieldBackground())
    // A marker belongs to the session that flagged it; a new one starts empty.
    .onChange(of: session.state) { old, new in
      if new == .recording, old != .recording { markerLog.reset() }
    }
  }

  // MARK: - The recording pane

  /// The cluster floating over the transcript, which takes the whole window.
  ///
  /// The **rail** went with the bar (XIA-445). It was the measured `.rail` tier
  /// rather than a `Divider()`, and that argument was the ink argument and is
  /// untouched — what it separated is simply no longer two stacked things. A
  /// hairline under a floating capsule would be a rule between a surface and
  /// itself.
  ///
  /// A `ZStack` and not a `VStack`: the cluster costs the transcript no layout
  /// height at all. What it does cost is the bottom of the *scroll content*,
  /// reserved by `transcriptBottomReserve` — an overlay alone would sit on the
  /// newest line, which is precisely the line `scrollToNewest` pins to `.bottom`.
  private var recordingPane: some View {
    ZStack(alignment: .bottom) {
      transcript(bottomReserve: RecordingPaneMetrics.transcriptBottomReserve)

      SessionCapsuleCluster(
        elapsed: session.elapsed,
        level: session.level,
        controls: controls,
        markers: markerLog.markers,
        onMark: mark,
        onStop: onStop
      )
      .padding(.bottom, RecordingPaneMetrics.clusterBottomInset)
    }
  }

  private func transcript(bottomReserve: CGFloat = 0) -> some View {
    LiveTranscriptView(rows: rows, volatileID: volatileID, bottomReserve: bottomReserve)
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
        .foregroundStyle(.ground(.speaker))
    }
  }

  // MARK: - Idle (nothing running)

  /// **No ember here, and no ring.** `CraftTokens.ember(_:)` means exactly one
  /// thing — the microphone is open — and idle is the state every owner sees
  /// before every recording, so it is the state that teaches them what the
  /// colour means. A breathing ember ring over a closed microphone would be the
  /// same lie `showsRecordingPane` withholds the bar from a failed session to
  /// avoid, told to more people more often.
  ///
  /// The buttons here and on the failed banner keep `.liquidGlassButton()`
  /// deliberately: the ghost/solid-ember pair is the *recording pane's*
  /// vocabulary, and these are not recording surfaces. "All of it goes" was
  /// only ever true of the pane.
  private var idleView: some View {
    centeredState {
      Text(RecordingPaneCopy.kindLine(kind: kind, controls: .start))
        .font(RecordingPaneMetrics.kindLineFont)
        .foregroundStyle(.ground(.speaker))
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
      // No reserve: nothing floats over a failed session's transcript. The
      // cluster is the indicator that a session is *flowing*, and nothing is.
      transcript()
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
        Button {
          // Not `session.cancel()`: only the model owns the record on disk,
          // and since XIA-436 Discard DELETES it — the record, the assets
          // folder and the recording. Hence the confirmation below rather than
          // a straight call: this is the most destructive verb in the app,
          // it sits between two harmless ones, and it reads as "dismiss this
          // banner". Audio is the one artifact that cannot be re-made.
          confirmingDiscard = true
        } label: {
          Text("Discard")
        }
        .liquidGlassButton()
      }
      .fixedSize(horizontal: true, vertical: false)
    }
    .confirmationDialog(
      RecordingDeletionCopy.discardTitle,
      isPresented: $confirmingDiscard,
      titleVisibility: .visible
    ) {
      Button("Discard Recording", role: .destructive) { onDiscard() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        RecordingDeletionCopy.discardMessage(
          seconds: session.elapsed,
          bytes: discardAudioBytes(),
          hasTranscript: !session.segments.isEmpty
        )
      )
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
