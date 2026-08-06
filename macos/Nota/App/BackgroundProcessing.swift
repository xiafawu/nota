import Foundation

/// Stop is a handoff, not a wait (XIA-435).
///
/// Everything a record still owes after the microphone closes — finalizing the
/// realtime stream, sealing the transcript, running the summary — happens on a
/// detached task while the window is already home. This file is the part of
/// that with no AppKit, no `NotaModel`, and no subprocess in it: which records
/// are being worked on, what a row says about one, when a notification is owed,
/// and what ⌘Q must ask. `NotaModel` is a thin delegator over it, because
/// `NotaModel.init` sweeps the real `~/.nota` and cannot be built in a test.
///
/// The anti-pattern this exists to kill is GoPro Quik's *"Stay on this screen
/// with the app open to ensure your downloads complete"*: if the work needs the
/// window open, it is not in the background. A job-queue library was evaluated
/// and rejected — the state that matters must live in the history record the
/// CLI reads, not in a library's private store. What follows takes the
/// semantics and keeps the record as the authority: a `ProcessingJob` is a
/// *view* of `~/.nota/history/<id>.json`, never a second source of truth.

// MARK: - A record being worked on

/// One record the app is still working on after Stop.
///
/// Addressed by `recordID` and by nothing else. That is the whole answer to
/// "what stops a summary that returns after the owner has started a new
/// recording from landing on the live session": there is no *current* record
/// for a completion to be applied to, so a late result has nowhere to go but
/// the id it was started for — and if that id has left the ledger, nowhere at
/// all. See `ProcessingLedger.advance`.
struct ProcessingJob: Equatable, Identifiable {
  var id: String { recordID }

  /// The history record id — `~/.nota/history/<id>.json`.
  let recordID: String
  let kind: HistoryKind
  /// Where the record's `.summary.md` is, standardized. This is the key the
  /// drawer row is found by: rows come from the output directory, records come
  /// from the history directory, and `outputPath` is the join.
  ///
  /// Absent until the transcript is sealed, because until then the record has
  /// written no markdown and there is no row in the drawer to join to. That
  /// stretch is not invisible — it is exactly what the menu bar's warm slot is
  /// for.
  var outputPath: String?
  /// Where the record has got to. A mirror of the record's own `status` — the
  /// record is written first and this is updated from it.
  var status: HistoryStatus
  /// True when the launch sweep resolved this record's failure. Carried so a
  /// row can say "Interrupted" rather than naming a stage that never got the
  /// chance to fail on its own.
  var interrupted: Bool
  /// When the status last moved. The row's freshness stamp counts from here,
  /// and a stamp that stops advancing is the only signal a stuck pipeline
  /// gives — which is exactly why there is no percentage anywhere in this file.
  var updatedAt: Date
  /// True once this record's completion has been announced. **One per record,
  /// never per stage** — a record finishes once, so it may interrupt once.
  var notified: Bool = false
}

// MARK: - The ledger

/// Every record being worked on right now.
///
/// Rows are independent by construction: this is a dictionary keyed by record
/// id, so two records process at once with no ordering, no queue, and no
/// shared "current" anything. Nothing here spends money, spawns a process, or
/// draws a pixel — it records what is happening so the drawer, the menu bar,
/// the notifier and ⌘Q can all read one answer.
@MainActor
final class ProcessingLedger: ObservableObject {
  /// The app's ledger. A singleton for exactly one reason: `AppDelegate`'s
  /// `applicationShouldTerminate` has no route to `NotaModel`, and ⌘Q must be
  /// able to ask what is in flight. Tests build their own instance.
  static let shared = ProcessingLedger()

  /// Every job, newest first. Published so the drawer and the menu bar redraw.
  @Published private(set) var jobs: [ProcessingJob] = []

  /// Advances once a second while anything is in flight, and never otherwise.
  /// The freshness stamp is relative to *now*, so something has to say when now
  /// changed; a timer that ran with an empty ledger would wake the main actor
  /// forever for a line nobody is reading.
  @Published private(set) var tick: Date = Date()

  private var byID: [String: ProcessingJob] = [:]
  private var ticker: Timer?

  /// How often the freshness stamp is recomputed. One second: the stamp's
  /// finest unit is seconds, so anything faster redraws for nothing.
  static let tickInterval: TimeInterval = 1

  init() {}

  deinit { ticker?.invalidate() }

  var inFlight: [ProcessingJob] { jobs.filter { $0.status.isInFlight } }

  var isBusy: Bool { !inFlight.isEmpty }

  func job(recordID: String) -> ProcessingJob? { byID[recordID] }

  /// The job whose record wrote this output file, or nil. The drawer row's
  /// only lookup.
  func job(outputPath: String) -> ProcessingJob? {
    let key = URL(fileURLWithPath: outputPath).standardizedFileURL.path
    return jobs.first { $0.outputPath == key }
  }

  // MARK: Mutation

  /// Take a record into the background. Returns false when this record is
  /// already in the ledger — a second Stop for one record is not two jobs.
  @discardableResult
  func begin(
    recordID: String,
    kind: HistoryKind,
    outputPath: String?,
    status: HistoryStatus,
    at now: Date = Date()
  ) -> Bool {
    guard byID[recordID] == nil else { return false }
    byID[recordID] = ProcessingJob(
      recordID: recordID,
      kind: kind,
      outputPath: outputPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
      status: status,
      interrupted: false,
      updatedAt: now
    )
    republish()
    return true
  }

  /// Move a record along, stamping the moment it moved.
  ///
  /// **Refuses an id the ledger does not hold**, and that refusal is the
  /// construction the session-epoch rule asks for. A detached task carries the
  /// id it was started for and can name no other; a record that has already
  /// been forgotten (or one a live session still owns, which was never
  /// admitted) cannot be written by a result that arrives late. There is
  /// deliberately no "advance whatever is current" entry point to get wrong.
  @discardableResult
  func advance(
    recordID: String,
    to status: HistoryStatus,
    interrupted: Bool = false,
    at now: Date = Date()
  ) -> Bool {
    guard var job = byID[recordID] else { return false }
    guard job.status != status || job.interrupted != interrupted else { return false }
    job.status = status
    job.interrupted = interrupted
    job.updatedAt = now
    byID[recordID] = job
    republish()
    return true
  }

  /// Point a job at the markdown its seal just wrote, so the drawer row can
  /// find it. Ownership-checked exactly like `advance` — an id the ledger does
  /// not hold is refused rather than created.
  @discardableResult
  func attachOutput(recordID: String, outputPath: String) -> Bool {
    guard var job = byID[recordID] else { return false }
    job.outputPath = URL(fileURLWithPath: outputPath).standardizedFileURL.path
    byID[recordID] = job
    republish()
    return true
  }

  /// Mark a record's completion as announced. Returns false when it was
  /// already announced (or is unknown) — the caller uses that to keep the
  /// one-notification-per-record promise without a second bookkeeping store.
  @discardableResult
  func markNotified(recordID: String) -> Bool {
    guard var job = byID[recordID], !job.notified else { return false }
    job.notified = true
    byID[recordID] = job
    republish()
    return true
  }

  /// Forget a record. Called once its terminal state has been shown — the
  /// ledger is about work in flight, not a history of it (the records are the
  /// history). Nothing on disk is touched.
  func forget(recordID: String) {
    guard byID.removeValue(forKey: recordID) != nil else { return }
    republish()
  }

  private func republish() {
    jobs = byID.values.sorted { $0.updatedAt > $1.updatedAt }
    syncTicker()
  }

  private func syncTicker() {
    if isBusy {
      guard ticker == nil else { return }
      let timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { _ in
        Task { @MainActor [weak self] in self?.tick = Date() }
      }
      timer.tolerance = Self.tickInterval / 4
      RunLoop.main.add(timer, forMode: .common)
      ticker = timer
    } else {
      ticker?.invalidate()
      ticker = nil
    }
  }
}

// MARK: - What a row says

/// The drawer row's progress line: a named stage and a freshness stamp, and
/// **never a percentage**.
///
/// There is no honest percentage for a model call — a summary is one request
/// that either has not answered yet or has — and a fake one is worse than
/// nothing, because it turns a wedged pipeline into a bar that looks like it is
/// moving. A stamp that stops advancing is the one signal that reveals a stuck
/// record, so the stamp is the progress indicator. Note there is no numeric
/// argument anywhere in this API: a percentage cannot be passed in by mistake.
enum ProcessingFreshness {
  /// The stage, as words. Nil for anything at rest — a finished record's row
  /// shows its ordinary title and time, not a status line.
  static func stageLabel(_ status: HistoryStatus) -> String? {
    switch status {
    case .recording: return "Recording…"
    case .transcribing: return "Transcribing…"
    case .summarizing: return "Summarizing…"
    case .transcribed, .done, .failed: return nil
    }
  }

  /// `updated 8s ago`. Whole seconds under a minute, whole minutes under an
  /// hour, then `1h 4m`. Clock skew (a stamp in the future) reads as `just
  /// now` rather than as a negative age.
  static func stamp(since: Date, now: Date) -> String {
    let elapsed = now.timeIntervalSince(since)
    guard elapsed >= 1 else { return "updated just now" }
    let seconds = Int(elapsed)
    if seconds < 60 { return "updated \(seconds)s ago" }
    let minutes = seconds / 60
    if minutes < 60 { return "updated \(minutes)m ago" }
    let hours = minutes / 60
    let remainder = minutes % 60
    return remainder == 0
      ? "updated \(hours)h ago"
      : "updated \(hours)h \(remainder)m ago"
  }

  /// `Summarizing… · updated 8s ago`, or nil when nothing is in flight.
  static func line(status: HistoryStatus, updatedAt: Date, now: Date) -> String? {
    guard let stage = stageLabel(status) else { return nil }
    return "\(stage) · \(stamp(since: updatedAt, now: now))"
  }
}

/// How a row's status line reads and what, if anything, the owner may do about
/// it. A value rather than a view so the wording is asserted without a window.
struct ProcessingRowStatus: Equatable {
  enum Tone: Equatable {
    case progress
    case failure
  }

  /// Retry is **manual, always** — an automatic one silently spends the
  /// owner's money twice. This names which stage a retry would re-run, and
  /// only a stage that can honestly be re-run alone appears.
  enum Retry: Equatable {
    /// The transcript is on disk and only the summary is missing. Re-runs
    /// `nota history summarize <id>` and nothing else.
    case summary
  }

  var text: String
  var tone: Tone
  var retry: Retry?

  /// The line a drawer row shows for a record, or nil for a record with
  /// nothing to say (`done`, and a `transcribed` record that was never asked
  /// for a summary).
  ///
  /// Failure wording splits on `interrupted`, which is the launch sweep's own
  /// flag: a record the process abandoned reads as interrupted — its transcript
  /// is saved and the summary can be run whenever — where a summary that
  /// genuinely failed says so.
  static func make(
    status: HistoryStatus,
    interrupted: Bool,
    updatedAt: Date,
    now: Date
  ) -> ProcessingRowStatus? {
    if let stage = status.failureStage {
      switch stage {
      case .summarizing:
        return ProcessingRowStatus(
          text: interrupted
            ? "Interrupted · transcript saved"
            : "Summary failed · transcript saved",
          tone: .failure,
          retry: .summary
        )
      case .transcribing, .recording:
        // No retry is offered, and that is a fact about live capture rather
        // than a gap: the realtime stream cannot be replayed, so there is no
        // single stage to re-run. The audio is still in the record's assets
        // folder — nothing here ever deletes it — and it can be transcribed as
        // a file whenever the owner chooses.
        return ProcessingRowStatus(
          text: interrupted ? "Interrupted · audio saved" : "Recording failed · audio saved",
          tone: .failure,
          retry: nil
        )
      }
    }
    guard let line = ProcessingFreshness.line(status: status, updatedAt: updatedAt, now: now)
    else {
      return nil
    }
    return ProcessingRowStatus(text: line, tone: .progress, retry: nil)
  }

  static func make(job: ProcessingJob, now: Date) -> ProcessingRowStatus? {
    make(status: job.status, interrupted: job.interrupted, updatedAt: job.updatedAt, now: now)
  }
}

// MARK: - The title arrives last

/// What a live session's record is called before a summary has named it.
///
/// The title is the completion signal when Nota is frontmost: the row says
/// "Untitled meeting" while the work runs and takes the summary's title when it
/// lands, and a row's identity changing under the owner's eye is a better
/// announcement than any badge. Which is also why nothing else may claim to be
/// the title in the meantime — "Live Meeting" was a name, and a name that never
/// changes announces nothing.
enum ProvisionalTitle {
  static func forKind(_ kind: HistoryKind) -> String {
    switch kind {
    case .memo: return "Untitled memo"
    case .meeting: return "Untitled meeting"
    case .file: return "Untitled transcript"
    }
  }

  /// Every placeholder, so "has the title arrived?" is one lookup.
  static let all: Set<String> = [
    forKind(.meeting),
    forKind(.memo),
    forKind(.file)
  ]

  /// True when a title is still the placeholder — i.e. the completion signal
  /// has not fired yet.
  static func isProvisional(_ title: String) -> Bool { all.contains(title) }
}

// MARK: - The completion notice

/// The facts under a completion notification's title: `41 min · 2 speakers ·
/// 3 markers`. Absent and zero parts are dropped rather than printed as zero —
/// "0 speakers" is not a fact about a meeting, it is a gap in the record.
enum CompletionFacts {
  static func line(durationMinutes: Int?, speakerCount: Int?, markerCount: Int?) -> String {
    var parts: [String] = []
    if let minutes = durationMinutes, minutes > 0 { parts.append("\(minutes) min") }
    if let speakers = speakerCount, speakers > 0 {
      parts.append("\(speakers) speaker\(speakers == 1 ? "" : "s")")
    }
    if let markers = markerCount, markers > 0 {
      parts.append("\(markers) marker\(markers == 1 ? "" : "s")")
    }
    return parts.joined(separator: " · ")
  }
}

/// One notification about one record.
struct CompletionNotice: Equatable {
  /// The record's own title — the notification is *about* the record, so its
  /// title is the record's, not "Nota".
  let title: String
  /// The facts line, or the failure's explanation.
  let body: String
  /// The record to open when it is clicked.
  let recordID: String
  /// Present only on a failure: the manual retry, offered where the failure is
  /// reported so the owner never has to go looking for it.
  let retry: ProcessingRowStatus.Retry?
}

/// When a finished record is allowed to interrupt.
///
/// Two rules, and they are the whole policy:
///
/// 1. **Only when Nota is not frontmost.** With the window in front, the row's
///    identity changing from "Untitled meeting" to its real title is already
///    the signal; a banner on top of it is the same news twice.
/// 2. **One per record, never per stage.** A record moving `transcribing →
///    summarizing → done` is one piece of news, not three.
enum CompletionNotifierPolicy {
  static func decide(
    job: ProcessingJob,
    title: String,
    facts: String,
    appIsFrontmost: Bool
  ) -> CompletionNotice? {
    guard !appIsFrontmost else { return nil }
    guard !job.notified else { return nil }
    guard job.status.isTerminal || job.status == .transcribed else { return nil }

    if let stage = job.status.failureStage {
      let retry: ProcessingRowStatus.Retry? = stage == .summarizing ? .summary : nil
      let body = stage == .summarizing
        ? "Summary failed. The transcript is saved."
        : "Recording failed. The audio is saved."
      return CompletionNotice(title: title, body: body, recordID: job.recordID, retry: retry)
    }
    return CompletionNotice(title: title, body: facts, recordID: job.recordID, retry: nil)
  }
}

// MARK: - Quitting with work in flight

/// What ⌘Q asks when something is still processing.
///
/// It asks **once**, and only while work is in flight, and the honest thing it
/// has to say is that nothing is at risk: the audio and the transcript are
/// already on disk under the record. What quitting costs is the summary, and
/// that is retriable from the drawer at any time — including on the next
/// launch, where the sweep in `LiveSessionPersistence.resolveInterruptedRecords`
/// leaves the record reading "Interrupted · transcript saved".
enum QuitPrompt {
  struct Ask: Equatable {
    let messageText: String
    let informativeText: String
    let quitButtonTitle: String
    let cancelButtonTitle: String
  }

  /// Nil means quit immediately — an empty ledger asks nothing.
  static func decide(inFlight: [ProcessingJob]) -> Ask? {
    guard !inFlight.isEmpty else { return nil }
    let count = inFlight.count
    let subject = count == 1 ? "1 recording is" : "\(count) recordings are"
    return Ask(
      messageText: "\(subject) still processing.",
      informativeText: """
        The audio and transcript are already saved either way. Quitting now \
        leaves \(count == 1 ? "it" : "them") unsummarized — you can retry the \
        summary from History at any time.
        """,
      quitButtonTitle: "Quit Anyway",
      cancelButtonTitle: "Keep Processing"
    )
  }
}

// MARK: - Where a completion is allowed to land

/// What a finished background job may change on screen.
///
/// The rule the dictation code learned the hard way (`DictationController`'s
/// session epoch) restated for records: a result that arrives after the owner
/// has moved on may update the list it belongs to and nothing else. It may
/// never rewrite the pane, because the pane may be a *different* record — or a
/// live session that is recording right now.
enum CompletionEffect: Equatable {
  /// Refresh the drawer. The record is not what the window is showing.
  case listOnly
  /// The record IS the open document: reload its text and title too.
  case reloadOpenDocument

  static func decide(
    jobOutputPath: String?,
    openOutputPath: String?,
    isLiveSessionActive: Bool
  ) -> CompletionEffect {
    // A live session outranks everything: the window belongs to the microphone
    // and a summary from a previous record may not touch it, whatever it is
    // holding.
    guard !isLiveSessionActive else { return .listOnly }
    guard let jobOutputPath, let openOutputPath else { return .listOnly }
    let job = URL(fileURLWithPath: jobOutputPath).standardizedFileURL.path
    let open = URL(fileURLWithPath: openOutputPath).standardizedFileURL.path
    return job == open ? .reloadOpenDocument : .listOnly
  }
}

// MARK: - When the window comes home

/// Whether the window still belongs to the live session.
///
/// Stop hands the record to the background and the window comes home
/// **immediately** — before the realtime stream has finished finalizing, before
/// the transcript is sealed, and long before any summary. `handedOff` is what
/// makes that true regardless of transcript length: it is set the instant Stop
/// is accepted, so a 20-minute meeting and a 20-second memo leave the live pane
/// at exactly the same moment. There is no duration threshold anywhere in this
/// decision, and there is nowhere to add one.
enum LivePhaseGate {
  static func showsLiveSession(
    isStarting: Bool,
    sessionIsIdle: Bool,
    handedOff: Bool
  ) -> Bool {
    if handedOff { return false }
    if isStarting { return true }
    return !sessionIsIdle
  }
}
