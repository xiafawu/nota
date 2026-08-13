import Foundation

// MARK: - SessionClock

/// A live session's clock, as arithmetic (XIA-447).
///
/// **`elapsed` is audio time, not wall-clock time.** Pause two minutes inside a
/// twenty-minute meeting and the recording is eighteen minutes long, because
/// `recording.caf` is a concatenation of the audio that was kept with the paused
/// spans simply absent — one continuous playable file, no gap of silence, no
/// second file. Every consumer of `elapsed` names an offset *into that file*:
/// a marker's `atSeconds`, a segment's `endTime`, the transcript's gutter
/// timestamps, the record's `durationMinutes`. A wall-clock elapsed would put
/// every one of them two minutes past the audio it names — silently, and worse
/// the longer the pause.
///
/// The fix is at the **producer**, which is why this type exists and why no
/// consumer had to learn that pause is a thing: `LiveMeetingSession`'s ticker
/// publishes `elapsed(now:)` and every row above inherits it.
///
/// It is a pure value for the reason `SessionTimerMetrics` and
/// `RecordingPaneMetrics` are: "the clock stops while paused, and a marker
/// pressed after a resume names the right second of the recording" is then
/// asserted without a microphone, a socket or a window server.
struct SessionClock: Equatable {
  /// When the session went live (after `Begin`, or after the Apple analyzer
  /// started). Never moved by a pause — the pauses are accrued instead, so
  /// `startedAt` stays the wall-clock fact it was and nothing has to reason
  /// about a start time that walks forward.
  let startedAt: Date
  /// Every second already spent paused, in total.
  private(set) var pausedTotal: TimeInterval = 0
  /// When the current pause began, or nil when the microphone is open.
  private(set) var pausedAt: Date?

  init(startedAt: Date, pausedTotal: TimeInterval = 0, pausedAt: Date? = nil) {
    self.startedAt = startedAt
    self.pausedTotal = pausedTotal
    self.pausedAt = pausedAt
  }

  var isPaused: Bool { pausedAt != nil }

  /// Whether this session has ever been paused. Read by the duration choice
  /// below — a session that never paused is unaffected by any of this.
  var everPaused: Bool { pausedTotal > 0 || pausedAt != nil }

  /// Seconds of **kept audio** at `now`.
  ///
  /// While paused the reference is the instant the pause began rather than
  /// `now`, so the clock genuinely stops rather than being frozen by a ticker
  /// that happens not to run: a surface that reads this once, late, during a
  /// pause gets the same answer as one that read it at the press.
  func elapsed(now: Date) -> TimeInterval {
    let reference = pausedAt ?? now
    return max(0, reference.timeIntervalSince(startedAt) - pausedTotal)
  }

  /// Begin a pause. Idempotent — a second Pause press while paused must not
  /// re-stamp the start and lose the seconds already accrued.
  mutating func pause(now: Date) {
    guard pausedAt == nil else { return }
    pausedAt = now
  }

  /// End a pause, banking what it cost. Idempotent for the same reason.
  /// A `now` before the pause began (a clock that went backwards) banks zero
  /// rather than *rewinding* the recording past audio that exists.
  mutating func resume(now: Date) {
    guard let pausedAt else { return }
    pausedTotal += max(0, now.timeIntervalSince(pausedAt))
    self.pausedAt = nil
  }
}

// MARK: - Which duration a record is sealed with

/// The duration that goes on the record, when the two sources disagree.
///
/// On the AssemblyAI path `Termination` carries `audio_duration_seconds`, and
/// that value normally wins over our own clock because it counts exactly the
/// frames the server received. **A paused session breaks that**, and it breaks
/// it because of the socket decision (see `LiveMeetingSession.pauseKeepAlive`):
/// the stream is kept alive across a pause by sending zeroed frames, so the
/// server's count includes every silent second of every pause — it is wall
/// clock, which is the one thing `elapsed` deliberately is not.
///
/// So the server's figure is used exactly when it still means what it says: a
/// session that was never paused. Otherwise the record is sealed with the
/// paused-corrected clock, which is also the length of the audio file the
/// record points at.
enum SessionDurationChoice {
  static func duration(
    serverReported: TimeInterval?,
    elapsed: TimeInterval,
    everPaused: Bool
  ) -> TimeInterval {
    guard !everPaused, let serverReported else { return elapsed }
    return serverReported
  }
}
