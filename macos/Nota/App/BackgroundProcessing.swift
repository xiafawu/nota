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

  /// Every job the ledger is holding — all of them, and that is the point.
  ///
  /// "Still in the ledger" and "still being worked on" are the same fact:
  /// `begin` takes a record in when Stop is pressed or Retry is pressed, and
  /// `forget` lets it go once its landing has been shown. Deriving this from
  /// the *status* instead left a blind window between the seal (which puts the
  /// job at `transcribed`, a rest state) and the summary claiming it — a Task
  /// hop and a file write later. A ⌘Q arriving in that window found nothing in
  /// flight, terminated with no prompt, and the summary that was about to start
  /// never did. The status says which stage; the ledger says whether there is
  /// still work, and only the ledger can know about work that has not started.
  var inFlight: [ProcessingJob] { jobs }

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
        //
        // The two stages are named apart: a session that recorded fine and
        // then could not be turned into a transcript (a dead realtime socket,
        // an empty result) did not fail to *record*, and telling the owner it
        // did sends them looking for audio that is exactly where it should be.
        let what = stage == .recording ? "Recording" : "Transcription"
        return ProcessingRowStatus(
          text: interrupted ? "Interrupted · audio saved" : "\(what) failed · audio saved",
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
///
/// This names the record (the markdown's `# title`, which the drawer row reads)
/// and **not** the file. The output file keeps the durable base name
/// `sealTranscript` has always given it: a filename is never rewritten when the
/// summary lands, so "Untitled meeting-<ts>.summary.md" would still be sitting
/// in the owner's Finder a year after the record was titled.
///
/// An `isProvisional`/`all` pair used to live here for asking "has the title
/// arrived?". Nothing ever asked — the completion signal is the row re-reading
/// the `.md`, which needs no predicate — so it is gone rather than kept as
/// coverage for a question no caller has.
enum ProvisionalTitle {
  static func forKind(_ kind: HistoryKind) -> String {
    switch kind {
    case .memo: return "Untitled memo"
    case .meeting: return "Untitled meeting"
    case .file: return "Untitled transcript"
    }
  }
}

// MARK: - Asking for a summary

/// Why a summary is being asked for.
///
/// The distinction exists because **Skip summary is a standing preference about
/// work Nota starts on its own**, and a press on one record's "Retry summary"
/// is not that. Reading the setting for both is what erased a failure: the
/// retry rewrote `failed:summarizing` to `transcribed`, then the setting sent
/// it home without running anything — and `transcribed` offers no Retry, so the
/// only recovery path the record had disappeared for good.
enum SummaryTrigger: Equatable {
  /// The stop path, following a live session. Honours Skip summary.
  case automatic
  /// The owner pressed Retry on this record (in the drawer row, or on a failure
  /// notification). An explicit press for one named record overrides a standing
  /// "don't summarize by yourself" — it is still manual, which is the rule that
  /// matters (nothing here ever runs without a press).
  case manualRetry

  func shouldRun(skipSummary: Bool) -> Bool {
    switch self {
    case .automatic: return !skipSummary
    case .manualRetry: return true
    }
  }
}

/// What a Retry press must do — decided **before** anything is written.
///
/// The order is the fix: the old path rewrote the record's status first and
/// asked whether the work would run afterwards, so a refusal left a record that
/// had lost its failure, its Retry and its only recovery path. Nothing is
/// mutated until this says `run` or `reopenThenRun`.
enum RetrySummaryPlan: Equatable {
  /// The ledger already holds this record: the work is under way.
  case alreadyRunning
  /// Not a record a summary retry can re-run. The stage that is re-run has to
  /// be the stage that failed.
  case refuse
  /// A `transcribed` record: ask for the summary as it stands.
  case run
  /// A `failed:summarizing` record. It is terminal, and `canAdvance` refuses
  /// everything from a terminal state, so it is reopened at the rest state it
  /// fell out of first.
  case reopenThenRun

  static func make(current: HistoryStatus, isInLedger: Bool) -> RetrySummaryPlan {
    if isInLedger { return .alreadyRunning }
    if current == .transcribed { return .run }
    if current.failureStage == .summarizing { return .reopenThenRun }
    return .refuse
  }
}

// MARK: - Where a record got to when the work stopped

/// The status a landed job settles at, read back off the record on disk.
///
/// The record is the authority — the CLI writes `done` itself — so the ledger
/// is updated *from* it rather than from what the app thinks happened. A record
/// that cannot be read at all is the one case with no authority to consult:
/// the audio is on disk (nothing ever deletes it) and the transcript may or may
/// not be, so it resolves to the failure of the earliest stage that could still
/// be true. It is deliberately not `done`.
enum ProcessingLanding {
  static func resolve(record: [String: Any]?) -> (status: HistoryStatus, interrupted: Bool) {
    guard let record else { return (.failed(stage: .transcribing), false) }
    return (
      HistoryStatus.normalized(fromRecord: record),
      record["interrupted"] as? Bool ?? false
    )
  }
}

// MARK: - The menu bar's warm slot

/// What the status item says while records are processing.
///
/// A pure function rather than a computed property on the view, because the
/// ticket's acceptance item is about the words: the menu bar names the *stage*,
/// so the stage has to be assertable without a status item.
enum ProcessingMenuBar {
  /// The stage to show, with a count when more than one record is in flight.
  ///
  /// More than one: the **earliest** stage wins, because it is the work with
  /// the furthest still to go. A job between stages (the ledger holds it but
  /// its status names no stage) contributes nothing to the wording and still
  /// keeps the slot warm through the count.
  static func stageText(inFlight: [ProcessingJob]) -> String? {
    guard !inFlight.isEmpty else { return nil }
    let order: [HistoryStatus] = [.recording, .transcribing, .summarizing]
    let earliest = order.first { status in inFlight.contains { $0.status == status } }
    guard let earliest, let label = ProcessingFreshness.stageLabel(earliest) else { return nil }
    return inFlight.count > 1 ? "\(label) (\(inFlight.count))" : label
  }
}

// MARK: - The completion notice

/// The facts under a completion notification's title: `18:42 · 2 speakers ·
/// 3 moments`. Absent and zero parts are dropped rather than printed as zero —
/// "0 speakers" is not a fact about a meeting, it is a gap in the record.
///
/// **It is not a fact list of its own** (XIA-429). It builds a `RecordFacts`
/// and prints that model's strip, so the notification, the receipt that rises
/// at Stop and the document's own header say the same things in the same words.
/// It used to say `19 min` and `4 markers` where the other two said `18:42` and
/// `4 moments` — one record, three formats of the duration and two nouns for the
/// same object, reachable by simply not being frontmost when a meeting landed.
///
/// What it leaves out of the strip is the kind, the audio size and the cost: a
/// notification is a glance, and those three are what a *document* owes.
enum CompletionFacts {
  static func line(duration: TimeInterval?, speakerCount: Int?, markerCount: Int?) -> String {
    RecordFacts(
      duration: (duration ?? 0) > 0 ? duration : nil,
      speakerCount: speakerCount,
      momentCount: markerCount
    ).stripText
  }

  /// The same line, read straight off a decoded record.
  ///
  /// Speakers are **counted from the segments**, not taken from a field: the
  /// record carries no speaker count of its own, and a name that appears in
  /// twenty segments is one speaker. Blank labels are not people.
  ///
  /// The length comes from `durationSeconds`, falling back to the rounded
  /// `durationMinutes` for records written before it existed — the same
  /// preference `HistoryRecordInfo.detailsByOutputPath` makes, for the same
  /// reason: the seconds are what the clock said.
  static func line(fromRecord record: [String: Any]?) -> String {
    guard let record else { return "" }
    let segments = record["segments"] as? [[String: Any]] ?? []
    var speakers = Set<String>()
    for segment in segments {
      if let speaker = segment["speaker"] as? String, !speaker.isEmpty { speakers.insert(speaker) }
    }
    let minutes = record["durationMinutes"] as? Int
    let seconds = (record["durationSeconds"] as? NSNumber)?.doubleValue
    return line(
      duration: seconds ?? minutes.map { TimeInterval($0) * 60 },
      speakerCount: speakers.isEmpty ? nil : speakers.count,
      markerCount: (record["markers"] as? [Any])?.count
    )
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
/// 1. **Only when Nota is not frontmost — unless the record has no row.** With
///    the window in front, the row's identity changing from "Untitled meeting"
///    to its real title is already the signal; a banner on top of it is the
///    same news twice. That reasoning rests entirely on a row *existing*, and
///    a record that failed before its markdown was written has none: rows are
///    built from the output directory, so a live session that ends at
///    `failed:transcribing` leaves nothing on screen at all. Suppressing there
///    made a whole meeting disappear in silence, so the suppression is
///    conditional on `outputPath` rather than unconditional.
/// 2. **One per record, never per stage.** A record moving `transcribing →
///    summarizing → done` is one piece of news, not three.
enum CompletionNotifierPolicy {
  /// What a failure says, named by the stage it actually failed in.
  ///
  /// `recording` and `transcribing` are deliberately not one sentence: a
  /// session whose audio is on disk and whose realtime stream then died did not
  /// fail to record, and saying it did sends the owner looking for audio that
  /// is exactly where it should be.
  static func failureBody(_ stage: HistoryStage) -> String {
    switch stage {
    case .recording: return "Recording failed. The audio is saved."
    case .transcribing: return "Transcription failed. The audio is saved."
    case .summarizing: return "Summary failed. The transcript is saved."
    }
  }

  static func decide(
    job: ProcessingJob,
    title: String,
    facts: String,
    appIsFrontmost: Bool
  ) -> CompletionNotice? {
    guard !job.notified else { return nil }
    guard job.status.isTerminal || job.status == .transcribed else { return nil }
    // A row exists exactly when the record wrote its markdown. With one on
    // screen the app has already said this; without one it has said nothing.
    if appIsFrontmost && job.outputPath != nil { return nil }

    if let stage = job.status.failureStage {
      let retry: ProcessingRowStatus.Retry? = stage == .summarizing ? .summary : nil
      return CompletionNotice(
        title: title,
        body: failureBody(stage),
        recordID: job.recordID,
        retry: retry
      )
    }
    return CompletionNotice(title: title, body: facts, recordID: job.recordID, retry: nil)
  }
}

// MARK: - A failure with nowhere to appear

/// What the *window* says when a handed-off record ends without a row.
///
/// Stop leaves the live pane on the press, which is the whole point of this
/// lane — and it took with it the last surface that acknowledged a session that
/// then failed. A record that never wrote markdown has no drawer row (rows come
/// from the output directory), no title to change, and its `status` string is
/// rendered nowhere once the live pane is gone. So the toolbar says it, in the
/// same pill a file run uses.
///
/// A record that DID write its markdown says nothing here: its row carries the
/// failure and its Retry, and two surfaces for one failure is the doubling this
/// lane's notification policy already refuses.
enum HandoffFailureNotice {
  static func message(status: HistoryStatus, hasRow: Bool) -> String? {
    guard let stage = status.failureStage, !hasRow else { return nil }
    switch stage {
    case .recording: return "Recording failed — the audio is saved."
    case .transcribing: return "Transcription failed — the audio is saved."
    case .summarizing: return "Summary failed — the transcript is saved."
    }
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
///
/// Which record is "open" is `NotaModel.lastOutputURL`, and only
/// `performOpenHistory` sets it. So `.reloadOpenDocument` is reached by the
/// **retry** path — the owner opens a record whose summary failed, presses
/// Retry, and the summary lands in the pane they are reading — and never by the
/// live-stop path. That is the design, not an oversight: the stop path used to
/// end with `lastOutputURL = saved.outputURL`, i.e. Stop opened the transcript
/// it had just sealed. A lane whose whole claim is that Stop gives the window
/// back may not then take it for a document the owner did not ask for.
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

// MARK: - Where Stop lands

/// **THE ONE PLACE STOP'S DESTINATION IS DECIDED** (XIA-429).
///
/// XIA-435 made Stop hand the record off and come home; the window then fell
/// through to `.home` for the ordinary reason that `markdown` was still empty.
/// XIA-429 routes a *successfully sealed* session to `.document` on that record
/// instead, so Stop lands on what was just recorded rather than on the front
/// door. The receipt then rises over that document.
///
/// **The owner may reverse this after living with it for a day.** Flipping
/// `routesToDocument` to `false` restores XIA-435's behaviour exactly — Stop
/// goes home — and nothing else in the app has to change: the gate above is
/// untouched, `isLiveSessionHandedOff` is still set before any `await`, there
/// is still no length test, and all the work still runs detached.
///
/// Three things this may never do, each of which is a real failure mode:
///
/// - **A seal that failed routes nowhere.** There is no document, so opening
///   one would be opening nothing; the owner goes home and the orphan toolbar
///   pill says what happened (`NotaModel.backgroundFailure`).
/// - **A discarded session routes nowhere.** Discard sets the same
///   `isLiveSessionHandedOff` flag Stop does (XIA-434 already found the two
///   sharing it) and deletes the whole record; routing on that flag rather than
///   on a sealed session would open a document for a session the owner said
///   they did not want.
/// - **A session that is already recording again wins.** The seal completes
///   asynchronously, so a Start press that beat it must not have the window
///   yanked out from under it. Same rule `CompletionEffect.decide` keeps.
/// - **Whatever the owner has since opened wins too**, and this is the rule the
///   first cut did not have. Stop comes home *immediately* (XIA-435) while the
///   seal can take up to the 5s AssemblyAI watchdog, so there is a real window
///   in which the owner opens yesterday's meeting from the drawer, or starts a
///   file transcription — and a routing decision made without asking would
///   overwrite the document under them seconds later. `CompletionEffect.decide`
///   already compares the job's output path against the open one for exactly
///   this reason; this asks the same question by comparing what was open when
///   the press landed against what is open now.
enum StopLanding {
  /// The owner-facing switch. `false` restores "Stop goes home".
  ///
  /// A **parameter with this as its default**, not a constant read inside, so
  /// the off state is a case a test can drive: asserting `routesToDocument`
  /// is true proves nothing about the switch and turns flipping it into a red
  /// suite, which is the opposite of an escape hatch.
  static let routesToDocument = true

  static func opensSealedDocument(
    routes: Bool = routesToDocument,
    sealed: Bool,
    discarded: Bool,
    isLiveSessionActive: Bool,
    isTranscribingAFile: Bool = false,
    openDocumentChanged: Bool = false
  ) -> Bool {
    guard routes else { return false }
    guard sealed, !discarded, !isLiveSessionActive else { return false }
    // A file transcription that started in the gap owns the pane: `ContentView`
    // tests `hasContent` before `isRunning`, so writing markdown here would take
    // its `.running` phase away outright.
    guard !isTranscribingAFile else { return false }
    guard !openDocumentChanged else { return false }
    return true
  }
}
