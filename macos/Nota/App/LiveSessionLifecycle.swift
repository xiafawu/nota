import Foundation

/// Who owns the record a live session is recording into, and the rules about
/// who may take one, clear one, and settle one (XIA-430).
///
/// This is `NotaModel`'s live-session bookkeeping, extracted so the races it
/// exists to prevent can be driven in a test: `NotaModel.init` sweeps the real
/// `~/.nota/history` and runs preflight, so a test may not build one, and the
/// call sites were where every defect of the first attempt lived.
///
/// Three rules, and each of them is a bug that happened:
///
/// 1. **One record at a time, and a press is accepted the moment it is seen.**
///    `LiveMeetingSession.start` stays `.idle` across the mic-permission
///    prompt and the whole WebSocket open + `Begin` round trip. A guard that
///    asks only "is the session recording?" therefore admits a second Start
///    press during that window — and the second press wrote a second record,
///    took ownership, and cancelled the first task, whose cleanup then
///    cleared the *new* owner's record. Stop found nothing to fill in and the
///    whole meeting's transcript was never sealed. `isStarting` closes the
///    window in the model; the UI closes it on screen.
/// 2. **A task may only clean up after itself.** `release`/`settle` take the
///    record they were started for and do nothing unless it is still the one
///    that is owned. An unconditional `record = nil` is precisely how a
///    cancelled task disowned a live session.
/// 3. **Nothing is abandoned in an in-flight status.** Every way out of a
///    session — clean stop, mid-session failure, server termination, discard,
///    a Try Again that starts over — goes through `settle`, which fails the
///    record in the stage it is actually in. What the process cannot settle
///    (because it went away) is what the launch sweep is for.
@MainActor
final class LiveSessionOwner {
  /// What a Start press resolved to.
  enum StartDecision: Equatable {
    /// A session is already starting or live; the press does nothing.
    case ignored
    /// A record exists on disk and the session must record into it.
    case started(LiveSessionPersistence.StartedRecord)
    /// The record could not be written. Recording into nowhere is the failure
    /// the whole record-first inversion exists to remove, so this is a hard
    /// stop rather than a session that runs anyway.
    case unwritable(String)
  }

  /// The record the in-flight live session is recording INTO. Non-nil is
  /// exactly "a live session owns a record on disk right now".
  private(set) var record: LiveSessionPersistence.StartedRecord?

  /// True from the moment a Start press is accepted until the session is
  /// recording or has failed to start. The window this covers is invisible on
  /// screen and seconds long, which is what made it pressable twice.
  private(set) var isStarting = false

  /// True while the stop path is running. The session settles itself to
  /// `.idle` partway through `stop()`, and without this the state observer
  /// that rescues a *server*-ended session would race the seal for it.
  private(set) var isStopping = false

  /// Read lazily so a test can point the whole type at a temp directory and
  /// the app can keep reading `~/.nota/history`.
  private let historyDirectory: () -> URL

  init(historyDirectory: @escaping () -> URL) {
    self.historyDirectory = historyDirectory
  }

  /// True when there is a record and the process still owes it a terminal
  /// status — i.e. something has to happen before this session is over.
  var isOwning: Bool { record != nil }

  // MARK: - Starting

  /// Accept or refuse a Start press, creating the record the session must
  /// record into.
  ///
  /// `sessionIsLive` is the recognizer's own answer to "am I recording or
  /// stopping". It is deliberately not the whole guard: the seconds between
  /// the press and `.recording` are exactly when a second press arrives.
  ///
  /// A record left over from a session that has already ended — the failure
  /// banner's Try Again is the route — is settled and released first. It is
  /// abandoned, not thrown away: its audio and whatever it holds stay on disk
  /// under a `failed(stage:)` status.
  func start(
    kind: HistoryKind,
    diarize: Bool,
    identify: Bool,
    sessionIsLive: Bool
  ) -> StartDecision {
    guard !isStarting, !isStopping, !sessionIsLive else { return .ignored }
    if let leftover = record {
      _ = settle(leftover)
    }

    let directory = historyDirectory()
    do {
      let started = try LiveSessionPersistence.beginRecording(
        kind: kind,
        diarize: diarize,
        identify: identify,
        historyDirectory: directory
      )
      record = started
      isStarting = true
      return .started(started)
    } catch {
      return .unwritable(error.localizedDescription)
    }
  }

  /// The start attempt is over, however it went. Clears only the starting
  /// window — a session that started successfully keeps its record.
  func finishedStarting() {
    isStarting = false
  }

  // MARK: - Stopping

  /// Claim the stop path for the record this session owns, or nil when there
  /// is nothing to stop. Also ends the starting window: a Stop pressed during
  /// the start round trip is a stop of that session.
  func beginStop() -> LiveSessionPersistence.StartedRecord? {
    guard let started = record else { return nil }
    isStarting = false
    isStopping = true
    return started
  }

  /// The stop path is over, however it went.
  func finishedStopping() {
    isStopping = false
  }

  // MARK: - Ownership-checked cleanup

  /// Give up ownership of `started`, but only if it is still the record that
  /// is owned. Returns whether it was.
  ///
  /// This is rule 2, and the check is the whole method: a task that is
  /// cleaning up after a `CancellationError` cannot know whether the thing
  /// that cancelled it has already taken over.
  @discardableResult
  func release(_ started: LiveSessionPersistence.StartedRecord) -> Bool {
    guard record?.historyID == started.historyID else { return false }
    record = nil
    return true
  }

  /// Fail `started` in the stage it is actually in and give up ownership —
  /// ownership-checked, exactly like `release`. Returns whether this call
  /// owned the record; whether the write itself landed is logged by
  /// `settleAsFailed`.
  @discardableResult
  func settle(_ started: LiveSessionPersistence.StartedRecord) -> Bool {
    guard record?.historyID == started.historyID else { return false }
    _ = LiveSessionPersistence.settleAsFailed(
      id: started.historyID,
      historyDirectory: historyDirectory()
    )
    record = nil
    return true
  }
}
