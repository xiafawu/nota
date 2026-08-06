import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

let supportedExtensions: Set<String> = [
  "mp3", "wav", "m4a", "aac", "caf", "aif", "aiff", "ogg", "webm", "flac", "qta", "mov", "mp4"
]

// MARK: - Summary rail dismissal policy (decisions 7/13)

/// What dismissing the summary rail with unsaved edits does. One setting
/// governs every dismissal — click-outside, Escape, Close, record switch, and
/// phase leave (decision 13: "one switch, no per-gesture split").
enum SummaryRailDismissalBehavior: String, CaseIterable {
  /// Commit the draft and close (default).
  case save
  /// Confirm first: save / discard / keep editing.
  case ask

  static let defaultsKey = "summaryRailDismissalBehavior"

  var label: String {
    switch self {
    case .save: return "Save it"
    case .ask: return "Ask me"
    }
  }

  /// Unknown or missing stored values fall back to the default rather than
  /// throwing — a payload written without the key decodes to Save it.
  static func load(from defaults: UserDefaults) -> SummaryRailDismissalBehavior {
    guard
      let raw = defaults.string(forKey: defaultsKey),
      let behavior = SummaryRailDismissalBehavior(rawValue: raw)
    else {
      return .save
    }
    return behavior
  }
}

/// The three answers to an Ask-me dismissal confirm (decision 13).
enum SummaryRailDismissalChoice {
  case save
  case discard
  case keepEditing
}

/// The pure dismissal decision, given whether a draft is being edited and the
/// setting. Unit-tested; `NotaModel.requestSummaryRailDismissal` applies it.
func summaryRailDismissalDecision(
  editing: Bool,
  behavior: SummaryRailDismissalBehavior
) -> SummaryRailDismissalDecision {
  guard editing else { return .close }
  switch behavior {
  case .save: return .commitAndClose
  case .ask: return .ask
  }
}

enum SummaryRailDismissalDecision: Equatable {
  /// No draft in flight: close immediately.
  case close
  /// Save it: commit the draft, then close.
  case commitAndClose
  /// Ask me: defer the close until the user answers.
  case ask
}

// MARK: - History drawer tab (decision 14)

/// Which tab the history drawer shows. Owned on the model so the popover's
/// "Show all N in Nota →" route (decision 26) can land on the Dictation tab
/// without reaching into the drawer view, and so ⌘L keeps the last tab.
enum HistoryDrawerTab: String, CaseIterable, Identifiable {
  case transcripts
  case dictation

  var id: String { rawValue }

  var title: String {
    switch self {
    case .transcripts: return "Transcripts"
    case .dictation: return "Dictation"
    }
  }
}

@MainActor
final class NotaModel: ObservableObject {
  @Published var selectedURL: URL?
  @Published var originalSelectedURL: URL?
  @Published var markdown = ""
  @Published var status = "Drop audio to transcribe"
  @Published var isRunning = false
  @Published var isDropTargeted = false
  @Published var identifySpeakers: Bool = (UserDefaults.standard.object(forKey: "identifySpeakers") as? Bool) ?? true {
    didSet { UserDefaults.standard.set(identifySpeakers, forKey: "identifySpeakers") }
  }
  @Published var skipSummary: Bool = (UserDefaults.standard.object(forKey: "skipSummary") as? Bool) ?? false {
    didSet { UserDefaults.standard.set(skipSummary, forKey: "skipSummary") }
  }
  @Published var lastOutputURL: URL?
  @Published var displayName = "Drop Audio"
  @Published var displayPath = "MP3, M4A, WAV, CAF, QTA, MOV, MP4"
  /// Live pipeline stage shown under the title while a run is in flight,
  /// parsed from the CLI's `##NOTA_PHASE:` markers (see runNota). Empty when idle.
  @Published var phase = ""
  @Published var history: [HistoryEntry] = []
  @Published var selectedHistoryID: HistoryEntry.ID?
  /// Speaker chips derived from the current document's label set + sidecar.
  @Published var speakerChips: [SpeakerChip] = []

  /// Preflight health for the home screen. `nil` until the first check returns.
  @Published var preflight: PreflightResult?
  @Published var isCheckingPreflight = false

  /// History-record facts per output path (standardized): status, kind
  /// (meeting/file/memo with legacy inference), duration, speaker count —
  /// from one background scan. Feeds the dashboard's transcript pill, kind
  /// chips, and row subtitles.
  @Published private(set) var historyDetails: [String: HistoryRecordInfo.HistoryDetail] = [:]

  /// Enrichment state for the open document (summary slot, tag editing).
  /// All of its mutations go through the CLI contract verbs.
  let enrichment = EnrichmentController.shared

  /// Live dictation/transcription session (mic → AssemblyAI realtime). Owned
  /// here so the toolbar and main pane share one lifecycle. Not `@Published`:
  /// the session publishes its own changes and ContentView observes it
  /// directly (via `@ObservedObject`) to switch the pane on state changes.
  let liveSession = LiveMeetingSession()

  private let projectDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NOTA_PROJECT_DIR"] ?? "/Users/xiafawu/Developer/Nota")
  private let outputDirectory = notaOutputDirectory()

  /// Enrichment generations append usage entries to the record; the dashboard
  /// consumes this flag to invalidate the usage-stats cache on next show.
  private var usageStatsStale = false
  private var enrichmentSink: AnyCancellable?

  /// The history record whose `outputPath` matches the current `lastOutputURL`,
  /// cached on document open so the enroll queue can look up `historyId` and
  /// `sourcePath` without re-scanning history every rename.
  private var cachedHistoryRecord: HistoryRecordInfo?

  /// Rich text for the document view. While the slot actually renders the
  /// summary section (record is truth), the whole summary block (narrative +
  /// key topics + decisions + action items) is stripped from the body — the
  /// slot renders it and the body stays transcript-only. During an in-flight
  /// generation the slot shows only the progress row, so the body keeps the
  /// full markdown rather than hiding the summary content everywhere.
  /// Copy/export use `fullRichText`.
  var richText: NSAttributedString {
    let slotState = enrichmentSlotState(
      record: enrichment.record,
      activity: enrichment.activity,
      modelID: enrichment.generatingModelID
    )
    let display: String
    if case .summary = slotState {
      display = strippingEnrichmentSections(markdown)
    } else {
      display = markdown
    }
    return renderMarkdownAsRichText(display, overrides: speakerNameOverrides)
  }

  /// The complete document (summary included) for copy and export.
  private var fullRichText: NSAttributedString {
    renderMarkdownAsRichText(markdown, overrides: speakerNameOverrides)
  }

  private var speakerNameOverrides: [String: String] {
    Dictionary(
      uniqueKeysWithValues: speakerChips
        .filter { !$0.name.isEmpty }
        .map { ($0.label, $0.name) }
    )
  }

  var hasContent: Bool {
    !markdown.isEmpty
  }

  init() {
    NotificationCenter.default.addObserver(
      forName: .notaOpenURLs,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard
        let self,
        let urls = notification.object as? [URL],
        let first = urls.first
      else {
        return
      }
      Task { @MainActor in
        self.accept(first)
      }
    }
    // The menu-bar popover's "Show all N in Nota →" (decision 26) posts this
    // to land the main window's drawer on the Dictation tab without a view
    // reaching into the drawer.
    NotificationCenter.default.addObserver(
      forName: .notaShowHistoryDrawer,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.showHistoryDrawer(tab: .dictation)
      }
    }
    // Re-render whenever enrichment state changes: the document view's summary
    // slot, header tag chips, and stripped body all derive from the controller.
    enrichmentSink = enrichment.objectWillChange.sink { [weak self] in
      self?.objectWillChange.send()
    }
    enrichment.onRecordUpdated = { [weak self] record, kind in
      self?.handleEnrichmentUpdate(record, kind: kind)
    }
    // Nothing of ours is running yet, so a record still claiming a live stage
    // belongs to a process that went away — a crash, a force quit, a logout
    // mid-sentence. Resolve those to `failed(stage:)` + `interrupted` BEFORE
    // the first `refreshHistory()`, so the dashboard never shows a session as
    // recording when nothing is. Their audio is untouched and playable; that
    // is the entire point of having written the record first (XIA-430).
    LiveSessionPersistence.resolveInterruptedRecords(
      historyDirectory: notaHistoryDirectory()
    )
    observeLiveSessionState()
    refreshHistory()
    // Run the readiness check on launch so the home shows health immediately.
    runPreflight()
  }

  /// After the CLI applied a generation or edit: the record was updated first
  /// and the `.md` rewritten second, so reload the open document from disk,
  /// refresh the dashboard (the "transcript" pill clears on completion), and
  /// mark usage stats stale when new spend landed on the record.
  private func handleEnrichmentUpdate(_ record: EnrichmentRecord, kind: EnrichmentController.UpdateKind) {
    if kind == .generated {
      usageStatsStale = true
    }
    if let outputPath = record.outputPath {
      let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
      if lastOutputURL?.standardizedFileURL == outputURL,
         let content = try? String(contentsOf: outputURL, encoding: .utf8) {
        markdown = content
      }
    }
    refreshHistory()
  }

  /// One-shot read of the usage-stale flag (dashboard invalidates its cache
  /// when this returns true).
  func consumeUsageStatsStale() -> Bool {
    defer { usageStatsStale = false }
    return usageStatsStale
  }

  /// Typed lifecycle status for a dashboard entry, nil when no record matches
  /// (e.g. imported markdown). Every record that exists has a status — legacy
  /// spellings are normalized on the way in — so nil means "no record", never
  /// "status unknown".
  func recordStatus(for entry: HistoryEntry) -> HistoryStatus? {
    historyDetails[entry.url.standardizedFileURL.path]?.status
  }

  /// History-record kind for a dashboard entry, `.file` when no record
  /// matches (imported markdown) or the record predates the kind field and
  /// carries no inferable source.
  func recordKind(for entry: HistoryEntry) -> HistoryKind {
    historyDetails[entry.url.standardizedFileURL.path]?.kind ?? .file
  }

  /// Full record facts for a dashboard entry (nil when no record matches).
  func recordDetail(for entry: HistoryEntry) -> HistoryRecordInfo.HistoryDetail? {
    historyDetails[entry.url.standardizedFileURL.path]
  }

  // MARK: - History drawer

  /// Whether the slide-over history drawer (⌘L) is presented. Owned here so
  /// the toolbar button, the ⌘L command, and the overlay host share one
  /// source of truth across phases.
  @Published var isHistoryDrawerPresented = false

  /// The drawer's active tab (decision 14). Binding source for the drawer's
  /// segmented control; the popover's "Show all in Nota" route sets it.
  @Published var historyDrawerTab: HistoryDrawerTab = .transcripts

  func toggleHistoryDrawer() {
    isHistoryDrawerPresented.toggle()
  }

  /// Open the drawer on a specific tab. The only in-app route that needs this
  /// is the menu-bar popover's "Show all N in Nota →" (decision 26); ⌘L keeps
  /// the last-used tab.
  func showHistoryDrawer(tab: HistoryDrawerTab) {
    historyDrawerTab = tab
    isHistoryDrawerPresented = true
  }

  // MARK: - Summary rail

  /// Whether the summary rail overlay is presented (decision 1). Owned here
  /// so the Summary button (MainPaneView), the overlay host (ContentView),
  /// and the record/phase transitions share one source of truth.
  @Published var isSummaryRailPresented = false
  /// True while the rail's summary editor is active. The draft below is that
  /// record's text, so ANY close — click-outside, Escape, Close, record
  /// switch, phase leave — commits (or asks) per `summaryDismissalBehavior`
  /// rather than dropping it (decisions 7/13).
  @Published var isSummaryEditing = false
  @Published var summaryDraft = ""
  /// Editing-dismissal policy (decision 13), UserDefaults-backed like
  /// `identifySpeakers`. Defaults to Save it.
  @Published var summaryDismissalBehavior: SummaryRailDismissalBehavior =
    SummaryRailDismissalBehavior.load(from: .standard) {
    didSet {
      UserDefaults.standard.set(
        summaryDismissalBehavior.rawValue,
        forKey: SummaryRailDismissalBehavior.defaultsKey
      )
    }
  }
  /// True while an Ask-me dismissal confirm is up (the rail presents it).
  @Published private(set) var isSummaryRailDismissalPending = false
  /// The work deferred behind the Ask-me confirm — the record switch or phase
  /// change that requested the dismissal. Runs only once the draft resolves,
  /// so it never races the commit.
  private var pendingRailDismissalCompletion: (() -> Void)?

  /// Close the rail unconditionally — no draft policy. Used by the
  /// Cancel-generation path (no draft can be in flight while generating) and
  /// as the close step of a resolved dismissal.
  func closeSummaryRail() {
    isSummaryRailPresented = false
    isSummaryEditing = false
    isSummaryRailDismissalPending = false
    pendingRailDismissalCompletion = nil
  }

  /// Every dismissal of the rail with a dirty draft goes through this policy
  /// (decisions 7/13): not editing → close; Save it → commit + close; Ask me
  /// → defer until the user answers via `resolveSummaryRailDismissal`.
  /// `completion` runs only after the draft is resolved; record-switch and
  /// phase-leave callers pass their switch work here so it never races the
  /// commit (the record is still installed while the draft commits).
  func requestSummaryRailDismissal(completion: (() -> Void)? = nil) {
    guard isSummaryRailPresented else {
      completion?()
      return
    }
    switch summaryRailDismissalDecision(
      editing: isSummaryEditing,
      behavior: summaryDismissalBehavior
    ) {
    case .close:
      closeSummaryRail()
      completion?()
    case .commitAndClose:
      commitSummaryDraft()
      closeSummaryRail()
      completion?()
    case .ask:
      guard !isSummaryRailDismissalPending else { return }
      isSummaryRailDismissalPending = true
      pendingRailDismissalCompletion = completion
    }
  }

  /// The Ask-me confirm's three answers (decision 13). Keep Editing cancels
  /// the dismissal — and therefore the record switch / phase change that
  /// requested it.
  func resolveSummaryRailDismissal(_ choice: SummaryRailDismissalChoice) {
    guard isSummaryRailDismissalPending else { return }
    let completion = pendingRailDismissalCompletion
    switch choice {
    case .save:
      commitSummaryDraft()
      closeSummaryRail()
      completion?()
    case .discard:
      closeSummaryRail()
      completion?()
    case .keepEditing:
      isSummaryRailDismissalPending = false
      pendingRailDismissalCompletion = nil
    }
  }

  private func commitSummaryDraft() {
    let trimmed = summaryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    enrichment.saveSummaryEdit(trimmed)
  }

  /// Persist the pinned flag on the entry's history record (a no-op for
  /// imported markdown with no record) and refresh the details map so the
  /// drawer's Pinned section reorders live.
  func setPinned(_ pinned: Bool, for entry: HistoryEntry) {
    let historyDir = notaHistoryDirectory()
    let outputPath = entry.url.standardizedFileURL.path
    Task { @MainActor [weak self] in
      guard let self else { return }
      await Task.detached(priority: .utility) {
        HistoryRecordInfo.setPinned(pinned, outputPath: outputPath, historyDir: historyDir)
      }.value
      self.refreshHistoryStatuses()
    }
  }

  /// Run the preflight readiness check and publish the result for the home
  /// screen. `refresh` bypasses the CLI's short-lived cache. A failure to run
  /// the checker keeps any prior result (the home shows "Not checked yet" only
  /// when nothing has ever returned) rather than interrupting the user.
  func runPreflight(refresh: Bool = false) {
    guard !isCheckingPreflight else { return }
    isCheckingPreflight = true
    Task { [projectDirectory] in
      defer { self.isCheckingPreflight = false }
      do {
        self.preflight = try await PreflightRunner.run(
          projectDirectory: projectDirectory,
          refresh: refresh
        )
      } catch {
        NSLog("Nota preflight failed: \(error.localizedDescription)")
      }
    }
  }

  func chooseFile() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = [
      .audio,
      .movie,
      UTType(filenameExtension: "qta") ?? .data,
      UTType(filenameExtension: "caf") ?? .audio,
      UTType(filenameExtension: "webm") ?? .movie,
      UTType(filenameExtension: "flac") ?? .audio
    ]

    if panel.runModal() == .OK, let url = panel.url {
      accept(url)
    }
  }

  func accept(_ url: URL) {
    // Decisions 6/7: a new file is a record switch — close the rail, resolving
    // any dirty draft first, before the incoming file replaces the record.
    requestSummaryRailDismissal { [weak self] in
      self?.performAccept(url)
    }
  }

  private func performAccept(_ url: URL) {
    // The share extension can't open a file in another sandboxed app directly,
    // so it hands the staged copy over as nota://import?path=<abs path>.
    // Normalise that back to a file URL; plain file opens pass through.
    let fileURL = Self.resolveSharedURL(url)
    // Shared files arrive as a synthetic ".nota-share-<epoch>-<uuid>" staging
    // copy; the share extension forwards the real filename via the URL's `name`
    // query item. Prefer that for display, falling back to the basename for
    // plain drag-drop (where it's already the real name).
    let friendlyName = Self.sharedDisplayName(from: url) ?? fileURL.lastPathComponent

    guard isSupportedAudio(fileURL) else {
      status = "Unsupported file type"
      return
    }

    markdown = ""
    lastOutputURL = nil
    enrichment.setRecord(nil)
    displayName = friendlyName
    displayPath = fileURL.path
    status = "Copying audio..."

    do {
      selectedURL = try makeStableInputCopy(from: fileURL)
      originalSelectedURL = fileURL
      // Staged shares live in ~/.nota/inbox and never reach runNota's reaper (that one only
      // sees the stable copy). Drop the staged file here so the inbox doesn't accumulate
      // ~78 MB per share. Both conditions matter: `resolveSharedURL` will hand back ANY
      // absolute path carried in a nota: URL, and a user can drag-drop a file that merely
      // happens to be named .nota-share-*, so a prefix check alone would delete user data.
      // `resolvingSymlinksInPath` (not `standardizedFileURL`) on BOTH sides: lexical
      // standardization collapses `..` without following symlinks, so a path like
      // <inbox>/sub/../.nota-share-x where `sub` is a symlink would compare equal to the
      // inbox while the kernel resolves it somewhere else entirely.
      let parent = fileURL.deletingLastPathComponent().resolvingSymlinksInPath()
      if let inbox = try? notaInboxDirectory(),
         parent == inbox.resolvingSymlinksInPath(),
         fileURL.lastPathComponent.hasPrefix(".nota-share-") {
        try? FileManager.default.removeItem(at: fileURL)
      }
      status = fileURL.lastPathComponent
    } catch {
      selectedURL = nil
      originalSelectedURL = nil
      markdown = failureMarkdown("Could not copy audio", details: error.localizedDescription)
      status = "Could not copy audio"
      return
    }

    transcribe()
  }

  func transcribe() {
    requestSummaryRailDismissal { [weak self] in
      self?.performTranscribe()
    }
  }

  private func performTranscribe() {
    guard let selectedURL, !isRunning else {
      return
    }
    let displayURL = originalSelectedURL ?? selectedURL

    isRunning = true
    markdown = ""
    lastOutputURL = nil
    status = "Preparing audio..."
    phase = "Preparing…"

    Task {
      do {
        let result = try await runNota(for: selectedURL, displayURL: displayURL, skipSummary: skipSummary) { [weak self] label in
          Task { @MainActor in self?.phase = label }
        }
        markdown = result.markdown
        lastOutputURL = result.outputURL
        status = "Complete"
        refreshHistory()
        if let entry = history.first(where: { $0.url.standardizedFileURL == result.outputURL.standardizedFileURL }) {
          selectedHistoryID = entry.id
        }
        loadChips(for: result.outputURL)
      } catch {
        markdown = failureMarkdown("Transcription failed", details: error.localizedDescription)
        status = "Transcription failed"
      }
      phase = ""
      isRunning = false
    }
  }

  // MARK: - Live meeting

  /// Kind of the in-flight live session — written to the history record on
  /// stop (meeting/memo); drives the pane title and the memo summarize step.
  /// Memo sessions preset diarization and speaker identity off unless the
  /// memo-diarization setting is enabled.
  private(set) var activeSessionKind: HistoryKind = .meeting

  /// Effective diarize/identify flags for a live session: only memo sessions
  /// can turn them on, and only when the memo-diarization setting is enabled.
  /// Meeting live sessions stay diarization-free (today's behavior).
  private var activeSessionDiarize: Bool {
    activeSessionKind == .memo && NotaSettingsStore.memoDiarizationEnabled
  }

  /// The live session's record bookkeeping: which record is owned, whether a
  /// start is in flight, and the ownership-checked cleanup every exit path
  /// goes through. The rules (and the races they exist to prevent) live in
  /// `LiveSessionOwner` so they can be driven without building a NotaModel.
  private let liveRecords = LiveSessionOwner(historyDirectory: notaHistoryDirectory)

  /// Published mirror of `liveRecords.isStarting` so the pane can show that a
  /// session is starting. It is the on-screen half of the double-press fix:
  /// the window between the press and `.recording` covers a permission prompt
  /// and a WebSocket round trip, and with nothing on screen changing, a user
  /// who sees nothing presses Start again.
  @Published private(set) var isStartingLiveSession = false

  /// Watches the session's own state so a session that ended without anyone
  /// pressing Stop still settles its record. See `observeLiveSessionState`.
  private var liveStateSink: AnyCancellable?

  /// Backend for a live session: memos fall back to the on-device Apple
  /// engine when no AssemblyAI key exists (the memo card stays alive with
  /// only the Apple engine); meetings always use AssemblyAI. Pure — testable
  /// without the model.
  nonisolated static func engine(for kind: HistoryKind, hasAssemblyAIKey: Bool) -> LiveEngine {
    if kind == .memo && !hasAssemblyAIKey { return .apple }
    return .assemblyAI
  }

  /// Begin a live dictation/transcription session. The pane switches to the
  /// live view when the session enters `.recording` (ContentView reads
  /// `liveSession.state`); start failures surface through the session's own
  /// `.failed` state (rendered by the live pane's error banner) and are
  /// mirrored here for the status pill.
  func startLiveSession(kind: HistoryKind = .meeting) {
    // Decision 6: entering the live-meeting phase closes the rail. The draft
    // (if any) commits or asks first; the session starts only once resolved.
    requestSummaryRailDismissal { [weak self] in
      self?.performStartLiveSession(kind: kind)
    }
  }

  private func performStartLiveSession(kind: HistoryKind = .meeting) {
    activeSessionKind = kind
    // A new session takes the window back. Whatever the last one handed off is
    // still processing in the background — independently, keyed by its own
    // record id — and cannot follow it here.
    isLiveSessionHandedOff = false
    let engine = Self.engine(
      for: kind,
      hasAssemblyAIKey: ApiKeyStore.value(for: "ASSEMBLYAI_API_KEY") != nil
    )

    // The record comes FIRST (XIA-430): before the microphone opens, before a
    // single buffer is written, `~/.nota/history/<id>.json` exists saying
    // `recording` and its assets folder is the thing the session records into.
    // Synchronously, so no audio can reach disk ahead of the record that
    // claims it. A store that cannot be written to is a hard stop: recording
    // into nowhere is the failure this whole inversion exists to remove.
    //
    // The admission rule is the owner's, not this method's: whether a press is
    // a second one arriving during the (invisible, seconds-long) start window
    // is exactly the question that lost a meeting's transcript.
    let decision = liveRecords.start(
      kind: kind,
      diarize: activeSessionDiarize,
      identify: activeSessionDiarize,
      sessionIsLive: liveSession.state == .recording || liveSession.state == .stopping
    )
    syncLiveSessionFlags()
    let started: LiveSessionPersistence.StartedRecord
    switch decision {
    case .ignored:
      return
    case .unwritable(let message):
      status = "Could not start recording: \(message)"
      return
    case .started(let record):
      started = record
    }

    status = HistoryStatus.recording.presentation()
    Task {
      do {
        try await liveSession.start(
          diarize: activeSessionDiarize,
          engine: engine,
          audioDestination: started.audioURL
        )
        liveRecords.finishedStarting()
        syncLiveSessionFlags()
      } catch {
        // The record and whatever audio was captured stay exactly where they
        // are; only the lifecycle moves — and only if this task still owns the
        // record. A `CancellationError` here means another Start press took
        // over, and clearing unconditionally is what disowned the session that
        // went on to record the whole meeting.
        liveRecords.finishedStarting()
        if liveRecords.settle(started) {
          status = "Live session failed: \(error.localizedDescription)"
        }
        syncLiveSessionFlags()
      }
    }
  }

  /// Republish the owner's flags. `liveRecords` is a plain object so its rules
  /// stay testable without SwiftUI; this is the one line that makes them
  /// visible to the pane.
  private func syncLiveSessionFlags() {
    if isStartingLiveSession != liveRecords.isStarting {
      isStartingLiveSession = liveRecords.isStarting
    }
  }

  /// Stop the live session and persist the result like a regular meeting
  /// (audio + `.summary.md` in the output dir, record in `~/.nota/history`),
  /// then refresh history and select the new row — mirroring `transcribe()`.
  /// The transcript already exists from the realtime stream, so the CLI
  /// transcription pipeline is deliberately not re-run. Summary enrichment is
  /// a follow-up (see LiveSessionPersistence). An empty transcript skips
  /// persistence entirely (status shows why); the session itself settles back
  /// to `.idle` inside `liveSession.stop()`.
  func stopLiveSession() {
    // Every state a record can be owned in is stoppable, `.failed` included:
    // `LiveMeetingSession.stop()` accepts a failed session precisely so the
    // transcript it accumulated before the socket dropped can still be sealed,
    // and a guard that admitted only `.recording`/`.stopping` is what turned a
    // network blip into a record stuck at `recording` for the rest of the run.
    guard liveRecords.isOwning else { return }
    // Decision 6: stopping leaves the live-meeting phase; a rail left open by
    // a previous "Keep editing" resolves its draft before the stop proceeds.
    requestSummaryRailDismissal { [weak self] in
      self?.performStopLiveSession()
    }
  }

  private func performStopLiveSession() {
    guard let started = liveRecords.beginStop() else { return }
    let kind = activeSessionKind
    syncLiveSessionFlags()

    // STOP RETURNS HOME, NOW (XIA-435).
    //
    // This flag is set before a single `await`, so the window leaves the live
    // pane on the press itself — before the realtime stream finishes
    // finalizing, before the transcript is sealed, and long before any summary.
    // There is no length test anywhere on this path: a 20-minute meeting and a
    // 20-second memo hand off at exactly the same moment, because handing off
    // is what the press means and not something the work earns.
    //
    // What replaced "Saving live session…" is the drawer row and the menu
    // bar's warm slot. The record's own status is the progress, so the window
    // has nothing left to wait for.
    isLiveSessionHandedOff = true
    let historyDirectory = notaHistoryDirectory()

    // The job enters the ledger keyed by THIS record's id and nothing else.
    // That is the whole guard against a late result landing on the wrong
    // record: `ProcessingLedger` has no "current job" to write, and a task
    // carries the id it was started for from here to the end.
    backgroundJobs.begin(
      recordID: started.historyID,
      kind: kind,
      outputPath: nil,
      status: .transcribing
    )
    status = HistoryStatus.transcribing.presentation()

    Task {
      defer {
        liveRecords.finishedStopping()
        syncLiveSessionFlags()
      }
      let result: LiveMeetingSession.LiveMeetingResult
      do {
        result = try await liveSession.stop()
      } catch {
        // Nothing to seal — the session never became one (a Stop during the
        // start round trip), or it had already handed its result over. The
        // record is failed in the stage it is actually in: naming
        // `.transcribing` for a record still at `recording` is an illegal
        // transition, so it wrote nothing at all and left the record live.
        liveRecords.settle(started)
        status = "Live session failed: \(error.localizedDescription)"
        finishBackgroundJob(recordID: started.historyID, historyDirectory: historyDirectory)
        return
      }

      let saved: LiveSessionPersistence.SavedSession
      do {
        saved = try LiveSessionPersistence.sealTranscript(
          started: started,
          result: result,
          // The title arrives LAST. Until a summary names the record it is
          // "Untitled meeting"/"Untitled memo", and the row's identity
          // changing is the completion signal when Nota is frontmost — which
          // a fixed "Live Meeting" could never be.
          displayName: ProvisionalTitle.forKind(kind),
          title: ProvisionalTitle.forKind(kind),
          outputDirectory: outputDirectory,
          historyDirectory: historyDirectory
        )
      } catch {
        // `sealTranscript` has already failed the record in the stage it was
        // in, and has deleted nothing: the recording is still in the record's
        // assets folder either way. A `LiveSessionPersistenceError` is
        // released rather than settled, so a record that reported
        // `recordUnwritable` is not asked to take a second write it has
        // already refused; anything else (markdown unwritable, output
        // directory unmakeable) leaves the record failed where it got to.
        if let persistence = error as? LiveSessionPersistenceError {
          liveRecords.release(started)
          status = persistence.errorDescription ?? "Live session failed"
        } else {
          liveRecords.settle(started)
          status = "Could not save live session"
        }
        finishBackgroundJob(recordID: started.historyID, historyDirectory: historyDirectory)
        return
      }

      // Sealed: the record is at `transcribed` with its transcript and its
      // markdown in it, and the live session's ownership ends HERE. Everything
      // below is work on a record already at rest, which is exactly why it can
      // outlive the session.
      liveRecords.release(started)
      backgroundJobs.attachOutput(
        recordID: saved.historyID,
        outputPath: saved.outputURL.path
      )
      backgroundJobs.advance(recordID: saved.historyID, to: .transcribed)
      refreshHistory()

      // The stop path ENDS HERE, and the summary is a separate task on
      // purpose. `LiveSessionOwner.isStopping` refuses a Start press while it
      // is set — correctly, since one microphone cannot serve two sessions —
      // so keeping it set across a summary would make "stop and leave" mean
      // "wait minutes before you may record again", which is the wait this
      // ticket exists to remove.
      liveRecords.finishedStopping()
      syncLiveSessionFlags()

      Task {
        await runRecordSummary(
          recordID: saved.historyID,
          outputURL: saved.outputURL,
          historyDirectory: historyDirectory
        )
      }
    }
  }

  // MARK: - Background processing (XIA-435)

  /// Records still being worked on after their session ended. The app-wide
  /// ledger, because `AppDelegate` has to be able to ask it what is in flight
  /// when ⌘Q arrives and has no route to this model.
  var backgroundJobs: ProcessingLedger { ProcessingLedger.shared }

  /// Where completion notices go. Injectable so the decision path can be
  /// driven without a notification centre.
  var completionNotifier: CompletionNotifying = CompletionNotifier.shared

  /// True from the moment Stop is accepted until the next session starts.
  /// The one thing that brings the window home immediately — see
  /// `LivePhaseGate`.
  @Published private(set) var isLiveSessionHandedOff = false

  /// Run the record's summary in the background and land it.
  ///
  /// Both live kinds go through here, and through the *same* kind-aware CLI
  /// verb (`nota history summarize <id>` threads the record's `kind`, so a memo
  /// gets the memo template and a meeting the meeting one). "A 20-minute
  /// meeting and a 20-second memo behave identically" is a statement about this
  /// function having no branch on kind and no branch on length.
  ///
  /// `skipSummary` is honoured: an owner who has turned summaries off is not
  /// charged for one because the work moved to the background.
  private func runRecordSummary(
    recordID: String,
    outputURL: URL,
    historyDirectory: URL
  ) async {
    guard !skipSummary else {
      finishBackgroundJob(
        recordID: recordID,
        historyDirectory: historyDirectory,
        outputURL: outputURL
      )
      return
    }
    if !LiveSessionPersistence.updateStatus(
      id: recordID,
      to: .summarizing,
      historyDirectory: historyDirectory
    ) {
      // Logged by `updateStatus`. The summary still runs: the record is at
      // rest with its transcript, and refusing to summarize because a status
      // line would not move helps nobody.
      LiveSessionPersistence.logger.error(
        "summary starting on a record that would not move to summarizing"
      )
    }
    backgroundJobs.advance(recordID: recordID, to: .summarizing)

    let succeeded = await runSummaryProcess(historyID: recordID)

    // A failed summary is a `failed(summarizing)` record that still holds its
    // audio AND its transcript — the summary is the only thing missing, and it
    // is the only thing that can be regenerated. A summary that succeeded has
    // already written `done` through the CLI's own setRecordSummary.
    if !succeeded {
      _ = LiveSessionPersistence.settleAsFailed(
        id: recordID,
        historyDirectory: historyDirectory
      )
    }
    finishBackgroundJob(
      recordID: recordID,
      historyDirectory: historyDirectory,
      outputURL: outputURL
    )
  }

  /// Land a record: read back what it actually says, refresh the list, tell
  /// the owner if they are not looking, and let the job go.
  ///
  /// The status is re-read from the record rather than assumed, because the
  /// record is the authority (the CLI writes `done` itself) and a ledger that
  /// disagreed with disk would be a second source of truth — which is the
  /// reason a job-queue library was rejected for this in the first place.
  private func finishBackgroundJob(
    recordID: String,
    historyDirectory: URL,
    outputURL: URL? = nil
  ) {
    let record = LiveSessionPersistence.loadRecord(id: recordID, historyDirectory: historyDirectory)
    let resolved = record.map { HistoryStatus.normalized(fromRecord: $0) } ?? .failed(stage: .transcribing)
    let interrupted = record?["interrupted"] as? Bool ?? false
    backgroundJobs.advance(recordID: recordID, to: resolved, interrupted: interrupted)
    refreshHistory()

    if let outputURL {
      // A completion may update the list it belongs to; it may rewrite the
      // pane only when the pane IS this record and no session is live. The
      // rule the dictation code learned as a session epoch, restated for
      // records: a summary that returns after the owner started a new
      // recording must never touch the live one.
      let effect = CompletionEffect.decide(
        jobOutputPath: outputURL.path,
        openOutputPath: lastOutputURL?.path,
        isLiveSessionActive: liveRecords.isOwning || liveSession.state != .idle
      )
      if effect == .reloadOpenDocument,
         let content = try? String(contentsOf: outputURL, encoding: .utf8) {
        markdown = content
        if let entry = history.first(where: {
          $0.url.standardizedFileURL == outputURL.standardizedFileURL
        }) {
          displayName = entry.title
          displayPath = entry.url.path
          selectedHistoryID = entry.id
        }
        loadChips(for: outputURL)
      }
    }

    announceCompletion(recordID: recordID, record: record, outputURL: outputURL)
    backgroundJobs.forget(recordID: recordID)
  }

  /// Post the record's one notification, if the policy says one is owed.
  private func announceCompletion(
    recordID: String,
    record: [String: Any]?,
    outputURL: URL?
  ) {
    guard let job = backgroundJobs.job(recordID: recordID) else { return }
    let title = outputURL
      .flatMap { url in
        history.first { $0.url.standardizedFileURL == url.standardizedFileURL }?.title
      }
      ?? ProvisionalTitle.forKind(job.kind)
    let segments = record?["segments"] as? [[String: Any]] ?? []
    var speakers = Set<String>()
    for segment in segments {
      if let speaker = segment["speaker"] as? String, !speaker.isEmpty { speakers.insert(speaker) }
    }
    let facts = CompletionFacts.line(
      durationMinutes: record?["durationMinutes"] as? Int,
      speakerCount: speakers.isEmpty ? nil : speakers.count,
      markerCount: (record?["markers"] as? [Any])?.count
    )
    guard let notice = CompletionNotifierPolicy.decide(
      job: job,
      title: title,
      facts: facts,
      appIsFrontmost: completionNotifier.appIsFrontmost
    ) else {
      return
    }
    guard backgroundJobs.markNotified(recordID: recordID) else { return }
    completionNotifier.post(notice)
  }

  /// Everything a drawer row needs to draw its own progress, in one value.
  func processingSource(for entry: HistoryEntry) -> ProcessingRowSource {
    let detail = recordDetail(for: entry)
    return ProcessingRowSource(
      outputPath: entry.url.path,
      persistedStatus: detail?.status,
      persistedInterrupted: detail?.interrupted ?? false,
      onRetrySummary: { [weak self] in self?.retrySummary(for: entry) }
    )
  }

  /// Re-run the summary for a record whose summary failed — **the failed stage
  /// only**. Nothing re-transcribes, nothing re-records, and nothing here ever
  /// runs without a press: an automatic retry silently spends the owner's money
  /// twice.
  func retrySummary(for entry: HistoryEntry) {
    guard let recordID = recordDetail(for: entry)?.recordID, !recordID.isEmpty else { return }
    retrySummary(recordID: recordID, outputURL: entry.url)
  }

  func retrySummary(recordID: String, outputURL: URL) {
    let historyDirectory = notaHistoryDirectory()
    guard backgroundJobs.job(recordID: recordID) == nil else { return }
    guard let record = LiveSessionPersistence.loadRecord(
      id: recordID,
      historyDirectory: historyDirectory
    ) else {
      return
    }
    // Only a record that stopped at the summary may be retried this way: the
    // stage that is re-run has to be the stage that failed.
    let current = HistoryStatus.normalized(fromRecord: record)
    guard current == .transcribed || current.failureStage == .summarizing else { return }
    // A `failed(summarizing)` record is terminal, and `canAdvance` refuses
    // everything from a terminal state — so the retry reopens it at the rest
    // state it fell out of before asking for `summarizing` again.
    if current.failureStage == .summarizing {
      guard LiveSessionPersistence.mutateRecord(
        id: recordID,
        historyDirectory: historyDirectory,
        ["status": HistoryStatus.transcribed.rawValue, "interrupted": false]
      ) else {
        return
      }
    }
    backgroundJobs.begin(
      recordID: recordID,
      kind: HistoryRecordInfo.kind(from: record),
      outputPath: outputURL.path,
      status: .transcribed
    )
    Task {
      await runRecordSummary(
        recordID: recordID,
        outputURL: outputURL,
        historyDirectory: historyDirectory
      )
    }
  }

  /// Open a record by id (a completion notification was clicked).
  func openRecord(id recordID: String) {
    let historyDirectory = notaHistoryDirectory()
    guard
      let record = LiveSessionPersistence.loadRecord(id: recordID, historyDirectory: historyDirectory),
      let outputPath = record["outputPath"] as? String
    else {
      return
    }
    let url = URL(fileURLWithPath: outputPath).standardizedFileURL
    guard let entry = history.first(where: { $0.url.standardizedFileURL == url }) else { return }
    openHistory(entry)
  }

  /// Retry a record's summary by id (a failure notification's Retry).
  func retrySummary(recordID: String) {
    let historyDirectory = notaHistoryDirectory()
    guard
      let record = LiveSessionPersistence.loadRecord(id: recordID, historyDirectory: historyDirectory),
      let outputPath = record["outputPath"] as? String
    else {
      return
    }
    retrySummary(recordID: recordID, outputURL: URL(fileURLWithPath: outputPath))
  }

  /// Throw a live session away without sealing it (the failure banner's
  /// Discard). Nothing is deleted: the record comes to rest as
  /// `failed(stage:)` with its audio — and whatever transcript it had — still
  /// in it, because audio is the one artifact that cannot be regenerated.
  /// Settling BEFORE `cancel()` is what makes this deterministic rather than
  /// leaving it to the state observer below.
  func discardLiveSession() {
    // Discard is also a way out of the live pane, and it hands nothing off.
    isLiveSessionHandedOff = true
    if let started = liveRecords.beginStop() {
      liveRecords.settle(started)
      liveRecords.finishedStopping()
      status = "Recording discarded"
    }
    liveSession.cancel()
    syncLiveSessionFlags()
  }

  /// Settle a record whose session ended without anyone pressing Stop.
  ///
  /// Two routes end a session from the outside: AssemblyAI sends
  /// `Termination`, or the socket closes cleanly mid-session. Both run
  /// `finalizeSession`, which stashes the result and returns the session to
  /// `.idle` — at which point the live pane disappears (ContentView leaves the
  /// live phase on `.idle`) and there is no button left anywhere that reaches
  /// `stopLiveSession()`. Without this the record would sit at `recording`
  /// until the next launch swept it, and the transcript the server did send
  /// would never be sealed at all.
  ///
  /// `.failed` is deliberately NOT handled here: that state keeps the error
  /// banner, and the banner keeps Save/Try Again/Discard — a decision is still
  /// the user's to make, and each of those routes settles the record.
  private func observeLiveSessionState() {
    liveStateSink = liveSession.$state.sink { [weak self] _ in
      // A published change is only the TRIGGER; the decision is made on the
      // state as it stands when this runs. `@Published` fires on willSet, so
      // the session's own property has not settled yet — and the hop means an
      // announced value can be stale by the time it lands. Acting on the
      // announced `.idle` that `start()`'s own `cancel()` publishes would stop
      // the session it was announcing the start of.
      Task { @MainActor [weak self] in
        guard let self, self.liveSession.state == .idle else { return }
        guard
          self.liveRecords.isOwning,
          !self.liveRecords.isStarting,
          !self.liveRecords.isStopping
        else {
          return
        }
        self.performStopLiveSession()
      }
    }
  }

  func refreshHistory() {
    let fileManager = FileManager.default
    // NOTE: do NOT pass .skipsHiddenFiles — every Nota output inherits a
    // leading-dot basename (.nota-input-/.nota-share- copies), so the summary
    // files are themselves dotfiles. .skipsHiddenFiles would drop the entire
    // history before the .summary.md filter below ever runs (issue #25).
    let contents = (try? fileManager.contentsOfDirectory(
      at: outputDirectory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: []
    )) ?? []

    let entries: [HistoryEntry] = contents.compactMap { url in
      let name = url.lastPathComponent
      guard name.hasSuffix(".summary.md") else {
        return nil
      }
      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
      let date = values?.contentModificationDate ?? Date.distantPast
      let kind = historyDetails[url.standardizedFileURL.path]?.kind ?? .file
      return HistoryEntry.make(url: url, modifiedAt: date, kind: kind)
    }
    history = entries.sorted { $0.modifiedAt > $1.modifiedAt }
    refreshHistoryStatuses()
  }

  /// Rebuild the outputPath → record-details map off the main thread
  /// (history records carry full transcripts, so parsing them inline would
  /// jank).
  private func refreshHistoryStatuses() {
    let historyDir = notaHistoryDirectory()
    Task { @MainActor [weak self] in
      let details = await Task.detached(priority: .utility) {
        HistoryRecordInfo.detailsByOutputPath(historyDir: historyDir)
      }.value
      self?.historyDetails = details
    }
  }

  func openHistory(_ entry: HistoryEntry) {
    guard !isRunning else {
      return
    }
    // Decision 6: opening a different transcript closes the rail; decision 7:
    // a dirty draft still commits (or asks) on that close, because it is that
    // record's text. The switch itself is deferred until the draft resolves.
    requestSummaryRailDismissal { [weak self] in
      self?.performOpenHistory(entry)
    }
  }

  private func performOpenHistory(_ entry: HistoryEntry) {
    do {
      markdown = try String(contentsOf: entry.url, encoding: .utf8)
      lastOutputURL = entry.url
      selectedURL = nil
      selectedHistoryID = entry.id
      displayName = entry.title
      displayPath = entry.url.path
      status = entry.title
      loadChips(for: entry.url)
    } catch {
      status = "Could not open transcript"
    }
  }

  func newTranscription() {
    guard !isRunning else {
      return
    }
    // Decisions 6/7: leaving the document phase closes the rail; the draft
    // commits (or asks) first — it is the outgoing record's text.
    requestSummaryRailDismissal { [weak self] in
      self?.performNewTranscription()
    }
  }

  private func performNewTranscription() {
    markdown = ""
    lastOutputURL = nil
    selectedURL = nil
    originalSelectedURL = nil
    selectedHistoryID = nil
    displayName = "Drop Audio"
    displayPath = "MP3, M4A, WAV, CAF, QTA, MOV, MP4"
    status = "Drop audio to transcribe"
    speakerChips = []
    cachedHistoryRecord = nil
    enrichment.setRecord(nil)
  }

  func deleteHistory(_ entry: HistoryEntry) {
    guard !isRunning else {
      return
    }
    try? FileManager.default.removeItem(at: entry.url)
    // Speaker clips live exactly as long as their history record (decision 2):
    // the per-speaker PCM clips sit in `<id>.assets/` beside the record JSON
    // and die with it. Deleting a record whose assets dir is already gone
    // must not error, hence try?.
    let assetsURL = entry.url
      .deletingPathExtension()
      .appendingPathExtension("assets")
    try? FileManager.default.removeItem(at: assetsURL)
    if selectedHistoryID == entry.id {
      newTranscription()
    }
    refreshHistory()
  }

  func copyMarkdown() {
    guard !markdown.isEmpty else {
      return
    }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(markdown, forType: .string)
    status = "Copied Markdown"
  }

  func copyRichText() {
    guard !markdown.isEmpty else {
      return
    }

    let attributedText = fullRichText
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    if let data = try? rtfData(from: attributedText) {
      pasteboard.setData(data, forType: .rtf)
    }
    pasteboard.setString(attributedText.string, forType: .string)
    status = "Copied Rich Text"
  }

  func exportMarkdown() {
    guard !markdown.isEmpty else {
      return
    }

    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    panel.nameFieldStringValue = defaultExportName(extensionName: "md")

    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }

    do {
      try markdown.write(to: url, atomically: true, encoding: .utf8)
      status = "Exported Markdown"
    } catch {
      status = "Export failed"
    }
  }

  func exportRichText() {
    guard !markdown.isEmpty else {
      return
    }

    let panel = NSSavePanel()
    panel.allowedContentTypes = [.rtf]
    panel.nameFieldStringValue = defaultExportName(extensionName: "rtf")

    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }

    do {
      try rtfData(from: fullRichText).write(to: url, options: .atomic)
      status = "Exported Rich Text"
    } catch {
      status = "Export failed"
    }
  }

  func revealOutput() {
    guard let lastOutputURL else {
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting([lastOutputURL])
  }

  private func runNota(
    for url: URL,
    displayURL: URL,
    skipSummary: Bool,
    onPhase: @escaping @Sendable (String) -> Void
  ) async throws -> NotaResult {
    try await Task.detached(priority: .userInitiated) { [identifySpeakers, projectDirectory, outputDirectory] in
      let fileManager = FileManager.default
      try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

      let shouldRemoveSharedInput = url.deletingLastPathComponent().standardizedFileURL == outputDirectory.standardizedFileURL
        && (url.lastPathComponent.hasPrefix(".nota-share-") || url.lastPathComponent.hasPrefix(".nota-input-"))

      let timestamp = notaTimestamp()
      let baseName = sanitizedBaseName(displayURL)
      let outputURL = outputDirectory.appendingPathComponent("\(baseName)-\(timestamp).summary.md")
      let runnerURL = projectDirectory
        .appendingPathComponent("scripts", isDirectory: true)
        .appendingPathComponent("nota-app-run.sh")

      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/bash")
      process.currentDirectoryURL = projectDirectory
      var arguments = [runnerURL.path, url.path, outputURL.path, "-v"]
      // Identify-by-default (decision 1): recognition auto-runs on every
      // diarized run when the store has >=1 enrolled speaker, so the toggle
      // only ever needs to opt OUT. On = omit the flag (auto-identify).
      if !identifySpeakers {
        arguments.append("--no-identify")
      }
      if skipSummary {
        arguments.append("--no-summary")
      }
      process.arguments = arguments

      // Ask the CLI to emit `##NOTA_PHASE:` markers (env-gated so plain CLI runs
      // stay clean). Inherit the parent environment so the runner script still
      // finds PATH etc. before it re-derives the login shell's values.
      var environment = ProcessInfo.processInfo.environment
      environment["NOTA_PROGRESS"] = "1"
      process.environment = environment

      let outputPipe = Pipe()
      let errorPipe = Pipe()
      process.standardOutput = outputPipe
      process.standardError = errorPipe

      try process.run()

      // Drain both pipes concurrently. stderr carries the phase markers that
      // drive the live label; both streams are captured in full for the final
      // error report. Reading to EOF completes when the process closes the
      // pipes on exit, so waitUntilExit then returns without blocking.
      async let stdoutData = Self.collect(outputPipe.fileHandleForReading)
      async let stderrData = Self.collect(errorPipe.fileHandleForReading) { @Sendable line in
        // Consume `##NOTA_PHASE:` markers: drive the live label, keep them out
        // of the captured text so they never leak into a failure's error report.
        guard let range = line.range(of: "##NOTA_PHASE:") else { return false }
        let stage = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if let label = Self.phaseLabel(stage) { onPhase(label) }
        return true
      }
      let stdout = String(data: await stdoutData, encoding: .utf8) ?? ""
      let stderr = String(data: await stderrData, encoding: .utf8) ?? ""

      process.waitUntilExit()
      let succeeded = process.terminationStatus == 0

      if shouldRemoveSharedInput && succeeded {
        try? fileManager.removeItem(at: url)
      }

      guard succeeded else {
        throw NotaAppError.pipelineFailed(
          process.terminationStatus,
          command: "/bin/bash \(arguments.map(shellQuoted).joined(separator: " "))",
          stdout: stdout,
          stderr: stderr
        )
      }

      let markdown = try String(contentsOf: outputURL, encoding: .utf8)
      return NotaResult(markdown: markdown, outputURL: outputURL)
    }.value
  }

  /// Stream a process pipe to EOF, delivering each complete line to `onLine` as
  /// its OS chunk arrives. Uses `readabilityHandler` rather than
  /// `FileHandle.bytes.lines`: the async-bytes sequence buffers, withholding a
  /// slow producer's lines until a large read fills or the pipe closes — which
  /// made live phase markers arrive only at the very end. `onLine` returns true
  /// to consume a line (kept out of the returned Data); the full text minus
  /// consumed lines is returned for the final error report.
  private static func collect(
    _ handle: FileHandle,
    onLine: (@Sendable (String) -> Bool)? = nil
  ) async -> Data {
    final class Box: @unchecked Sendable {
      var captured = Data()
      var pending = Data()
    }
    let box = Box()
    return await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
      handle.readabilityHandler = { fh in
        let chunk = fh.availableData
        guard !chunk.isEmpty else {
          fh.readabilityHandler = nil
          if !box.pending.isEmpty { box.captured.append(box.pending) }
          continuation.resume(returning: box.captured)
          return
        }
        box.pending.append(chunk)
        while let newline = box.pending.firstIndex(of: 0x0A) {
          let lineData = box.pending.subdata(in: box.pending.startIndex..<newline)
          box.pending.removeSubrange(box.pending.startIndex...newline)
          let line = String(data: lineData, encoding: .utf8) ?? ""
          if onLine?(line) == true { continue }
          box.captured.append(lineData)
          box.captured.append(0x0A)
        }
      }
    }
  }

  /// Map a pipeline stage id to the label shown under the title during a run.
  /// `nonisolated` so the background readability handler can call it directly.
  private nonisolated static func phaseLabel(_ stage: String) -> String? {
    switch stage {
    case "validating": return "Validating…"
    case "transcribing": return "Transcribing…"
    case "summarizing": return "Summarizing…"
    case "writing": return "Writing…"
    default: return nil
    }
  }

  /// Run the kind-aware CLI summary over a record: `nota history summarize
  /// <id>` (threads the record's `kind`, so a memo gets the memo template and
  /// its memo-length title, a meeting the meeting one). Environment mirrors
  /// `scripts/nota-app-run.sh`: the user's shell exports + `~/.secrets`, so
  /// provider keys resolve exactly as a CLI run would. Returns success; a
  /// failure keeps the transcript-only output (the recording is never lost).
  ///
  /// Named for what it is rather than for the one kind that used to reach it:
  /// since XIA-435 both live kinds summarize in the background through this
  /// one call, with no branch on kind and none on length.
  private func runSummaryProcess(historyID: String) async -> Bool {
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/bash")
    shell.currentDirectoryURL = projectDirectory

    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = [
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "/usr/bin",
      "/bin",
      "/usr/sbin",
      "/sbin",
      environment["PATH"] ?? "",
    ].joined(separator: ":")
    shell.environment = environment

    shell.arguments = [
      "-c",
      #"""
      cd "\#(projectDirectory.path)" || exit 1
      if [ -x /bin/zsh ]; then
        while IFS= read -r assignment; do
          case "$assignment" in
            *=*) export "$assignment" ;;
          esac
        done < <(/bin/zsh -lic 'for name in PATH OPENAI_API_KEY ASSEMBLYAI_API_KEY HUGGINGFACE_TOKEN; do value="${(P)name}"; if [[ -n "$value" ]]; then print -r -- "$name=$value"; fi; done' 2>/dev/null || true)
      fi
      if [ -f "$HOME/.secrets" ]; then
        set +u; set -a
        . "$HOME/.secrets" 2>/dev/null || true
        set +a; set -u
      fi
      if [ ! -f "dist/index.js" ]; then
        npm run build 2>/dev/null || exit 1
      fi
      exec node dist/index.js history summarize "\#(historyID)"
      """#,
    ]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    shell.standardOutput = outputPipe
    shell.standardError = errorPipe
    // Never inherit stdin (pty slave trap — see UsageStatsProvider).
    shell.standardInput = FileHandle.nullDevice

    do {
      try shell.run()
    } catch {
      NSLog("Nota background summary could not start: \(error.localizedDescription)")
      return false
    }
    outputPipe.fileHandleForReading.readDataToEndOfFile()
    let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    shell.waitUntilExit()

    guard shell.terminationStatus == 0 else {
      NSLog("Nota background summary failed: \(stderr.prefix(500))")
      return false
    }
    return true
  }

  /// Map an incoming open request to a file URL. Plain file URLs pass through;
  /// the share extension's `nota://import?path=<abs path>` is decoded back to
  /// the staged file in ~/.nota/inbox. Note this returns whatever absolute path
  /// the URL carries — callers that delete must verify the directory too, not
  /// just the `.nota-share-` basename (see `accept`).
  private static func resolveSharedURL(_ url: URL) -> URL {
    guard !url.isFileURL,
          url.scheme == "nota",
          let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let path = comps.queryItems?.first(where: { $0.name == "path" })?.value,
          !path.isEmpty
    else {
      return url
    }
    return URL(fileURLWithPath: path)
  }

  /// Original user-facing filename forwarded by the share extension as the
  /// `name` query item of `nota://import?path=…&name=…`. Display-only — it is
  /// never used to touch the filesystem, so a hostile value can only affect the
  /// title label. Returns nil for plain file URLs (drag-drop keeps its name).
  private static func sharedDisplayName(from url: URL) -> String? {
    guard !url.isFileURL,
          url.scheme == "nota",
          let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let name = comps.queryItems?.first(where: { $0.name == "name" })?.value,
          !name.isEmpty
    else {
      return nil
    }
    return name
  }

  private func isSupportedAudio(_ url: URL) -> Bool {
    supportedExtensions.contains(url.pathExtension.lowercased())
  }

  private func makeStableInputCopy(from url: URL) throws -> URL {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let extensionName = url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased()
    let destination = outputDirectory.appendingPathComponent(".nota-input-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).\(extensionName)")
    try fileManager.copyItem(at: url, to: destination)
    return destination
  }

  private func defaultExportName(extensionName: String) -> String {
    if let lastOutputURL {
      return "\(lastOutputURL.deletingPathExtension().lastPathComponent).\(extensionName)"
    }

    if let url = originalSelectedURL ?? selectedURL {
      return "\(sanitizedBaseName(url)).summary.\(extensionName)"
    }

    return "nota-summary.\(extensionName)"
  }

  // MARK: - Speaker chips

  /// Parse unique speaker labels (first-seen order) from the markdown body.
  private static func parseSpeakerLabels(from markdown: String) -> [String] {
    let pattern = #"^\[([0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?)\] \*\*(.+?):\*\*"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else {
      return []
    }
    var seen = Set<String>()
    var ordered: [String] = []
    let range = NSRange(markdown.startIndex..., in: markdown)
    for match in regex.matches(in: markdown, range: range) {
      if let labelRange = Range(match.range(at: 2), in: markdown) {
        let label = String(markdown[labelRange])
        if seen.insert(label).inserted {
          ordered.append(label)
        }
      }
    }
    return ordered
  }

  /// Load chips from the sidecar for `documentURL`, cache the history record,
  /// and set the initial indicator for each chip.
  private func loadChips(for documentURL: URL) {
    let labels = Self.parseSpeakerLabels(from: markdown)
    let sidecar = SpeakerSidecar.load(for: documentURL)

    // Cache history record (background task to avoid blocking main thread).
    // The same lookup loads the enrichment slice of the record, which drives
    // the summary slot and editable tag chips for the open document.
    cachedHistoryRecord = nil
    enrichment.setRecord(nil)
    let historyDir = notaHistoryDirectory()
    let docPath = documentURL.path
    Task { @MainActor [weak self] in
      guard let self else { return }
      let (info, record, enrolledNames) = await Task.detached(priority: .utility) { () -> (HistoryRecordInfo?, EnrichmentRecord?, Set<String>) in
        let info = HistoryRecordInfo.find(outputPath: docPath, historyDir: historyDir)
        let record = info.flatMap { EnrichmentRecord.load(from: $0.recordURL) }
        return (info, record, Set(SpeakerProfileStore.load().speakers.keys))
      }.value
      self.cachedHistoryRecord = info
      self.enrichment.setRecord(record)
      // Pending suggestions ride the record: attach them to the matching
      // chips (decided entries are dropped by the map).
      self.applySuggestions(record?.pendingSuggestions ?? [])
      // Reconcile indicators against the voiceprint store: the conservative
      // amber default only ever got cleared by an APP-side enroll, so a
      // speaker enrolled through the CLI (or auto-identified at run time)
      // wore "no history record" forever. Enrolled-in-store is the truth the
      // accessory is trying to report; say so.
      for idx in self.speakerChips.indices {
        let chip = self.speakerChips[idx]
        let display = chip.name.isEmpty ? chip.label : chip.name
        if enrolledNames.contains(display) {
          self.speakerChips[idx].indicator = .enrolled
        }
      }
    }

    speakerChips = labels.map { label in
      let name = sidecar.speakers[label] ?? ""
      // Initial indicator: if name is set but we don't know enroll status yet,
      // show .skipped(.noHistoryRecord) as a conservative default; it gets
      // overwritten when the history record lookup completes (via the enroll queue).
      let indicator: ChipIndicator = name.isEmpty ? .none : .skipped(reason: "no history record")
      return SpeakerChip(label: label, name: name, indicator: indicator)
    }
  }

  /// Called by the chip strip when the user commits a name for a label.
  func renameChip(label: String, newName: String) {
    guard let documentURL = lastOutputURL else { return }

    // Update in-memory chip immediately
    if let idx = speakerChips.firstIndex(where: { $0.label == label }) {
      speakerChips[idx].name = newName
      speakerChips[idx].indicator = newName.isEmpty ? .none : .pending
    }

    // Write sidecar (always, even for empty name = clear mapping)
    var sidecar = SpeakerSidecar.load(for: documentURL)
    if newName.isEmpty {
      sidecar.speakers.removeValue(forKey: label)
    } else {
      sidecar.speakers[label] = newName
    }
    try? SpeakerSidecar.save(sidecar, for: documentURL)

    // If empty name, nothing to enroll
    guard !newName.isEmpty else { return }

    // Enroll voiceprint if we have a history record
    guard let info = cachedHistoryRecord else {
      // Still waiting for the background lookup — indicator already set to
      // .skipped(.noHistoryRecord) which is the correct amber state.
      return
    }

    // Mark chip as enrolling
    if let idx = speakerChips.firstIndex(where: { $0.label == label }) {
      speakerChips[idx].indicator = .enrolling
    }

    let chipLabel = label
    Task {
      await EnrollQueue.shared.enqueue(
        historyID: info.historyID,
        label: chipLabel,
        name: newName
      ) { [weak self] result in
        guard let self else { return }
        guard let idx = self.speakerChips.firstIndex(where: { $0.label == chipLabel }) else { return }
        switch result {
        case .enrolled:
          self.speakerChips[idx].indicator = .enrolled
        case .skipped(let reason):
          self.speakerChips[idx].indicator = .skipped(reason: reason.tooltip)
        case .failed(let stderr):
          self.speakerChips[idx].indicator = .failed(stderr: stderr)
        }
      }
      // Propagate the name into the record and the document AFTER enroll:
      // enroll reads the stored clip under the old label, and the serial
      // queue guarantees this runs second. A failed or skipped enroll still
      // renames — the user asked for the name either way, the voiceprint is
      // only a bonus.
      guard chipLabel != newName else { return }
      await EnrollQueue.shared.enqueueTranscriptRename(
        historyID: info.historyID,
        label: chipLabel,
        name: newName
      ) { [weak self] ok, _ in
        guard let self, ok else { return }
        self.applyTranscriptRename(oldLabel: chipLabel, newName: newName)
      }
    }
  }

  /// Attach pending suggestions (label → candidate) onto the matching chips.
  /// Only the labels the open record actually proposes get a suggestion;
  /// every other chip keeps its current face.
  private func applySuggestions(_ suggestions: [SpeakerSuggestion]) {
    let byLabel = pendingSuggestionMap(suggestions)
    for idx in speakerChips.indices {
      speakerChips[idx].suggestion = byLabel[speakerChips[idx].label]
    }
  }

  /// Accept the pending suggestion for `label` (decision 4): the CLI renames
  /// the label to the suggested name everywhere AND enrolls the clip as a new
  /// voiceprint AND marks the suggestion accepted — one serialized verb. On
  /// success the chip takes the suggested name with the .enrolled indicator
  /// (same visual as a successful manual enroll) and the record reloads, so
  /// a `summaryOutdated` flag set by the rename surfaces the regenerate
  /// affordance (decision 5).
  func acceptSuggestion(label: String) {
    guard
      let info = cachedHistoryRecord,
      let idx = speakerChips.firstIndex(where: { $0.label == label }),
      let suggestion = speakerChips[idx].suggestion
    else {
      return
    }

    // In-flight guard: a second tap while the first accept is queued must not
    // spawn a duplicate verb. The .enrolling indicator gives visual feedback.
    if speakerChips[idx].indicator == .enrolling { return }
    speakerChips[idx].indicator = .enrolling

    let chipLabel = label
    Task {
      await EnrollQueue.shared.enqueueSuggestionAccept(
        historyID: info.historyID,
        label: chipLabel
      ) { [weak self] result in
        guard let self else { return }
        switch result {
        case .enrolled:
          // The CLI renamed the transcript; mirror the manual-rename
          // propagation (sidecar move, body reload, chip re-derive) and keep
          // the accepted indicator on the resulting chip.
          if let idx = self.speakerChips.firstIndex(where: { $0.label == chipLabel }) {
            self.speakerChips[idx].indicator = .enrolled
          }
          self.applyTranscriptRename(oldLabel: chipLabel, newName: suggestion.suggestedName)
        case .skipped(let reason):
          guard let idx = self.speakerChips.firstIndex(where: { $0.label == chipLabel }) else { return }
          self.speakerChips[idx].indicator = .skipped(reason: reason.tooltip)
        case .failed(let stderr):
          guard let idx = self.speakerChips.firstIndex(where: { $0.label == chipLabel }) else { return }
          self.speakerChips[idx].indicator = .failed(stderr: stderr)
        }
      }
    }
  }

  /// Dismiss the pending suggestion for `label` (decision 4): decision state
  /// only — the record's segments, clips, and store stay untouched. On
  /// success the chip's suggestion clears (the chip stays unnamed) and the
  /// record reloads so reopening the document doesn't resurrect the chip.
  func dismissSuggestion(label: String) {
    guard let info = cachedHistoryRecord else { return }
    let chipLabel = label
    Task {
      await EnrollQueue.shared.enqueueSuggestionDismiss(
        historyID: info.historyID,
        label: chipLabel
      ) { [weak self] ok, _ in
        guard let self, ok else { return }
        self.reloadChipsPreservingIndicators()
      }
    }
  }

  /// Rebuild the chips from the current document + record, keeping every
  /// chip's enroll indicator (loadChips's conservative default would reset
  /// named chips to the amber "no history record" state). Used after a
  /// dismiss, where the record — not the body — is what changed.
  private func reloadChipsPreservingIndicators() {
    guard let documentURL = lastOutputURL else { return }
    let indicators = Dictionary(
      uniqueKeysWithValues: speakerChips.map { ($0.label, $0.indicator) }
    )
    loadChips(for: documentURL)
    for idx in speakerChips.indices {
      if let indicator = indicators[speakerChips[idx].label] {
        speakerChips[idx].indicator = indicator
      }
    }
  }

  /// The record and output markdown now carry `newName` where `oldLabel` was:
  /// move the sidecar mapping, reload the visible document from disk, and
  /// re-derive the chips from the renamed body — keeping the enroll indicator
  /// the queue already delivered for this chip.
  private func applyTranscriptRename(oldLabel: String, newName: String) {
    guard let documentURL = lastOutputURL else { return }

    var sidecar = SpeakerSidecar.load(for: documentURL)
    sidecar.speakers.removeValue(forKey: oldLabel)
    sidecar.speakers[newName] = newName
    try? SpeakerSidecar.save(sidecar, for: documentURL)

    let keptIndicator = speakerChips.first(where: { $0.label == oldLabel })?.indicator

    if let content = try? String(contentsOf: documentURL, encoding: .utf8) {
      markdown = content
    }
    loadChips(for: documentURL)
    if let indicator = keptIndicator,
       let idx = speakerChips.firstIndex(where: { $0.label == newName }) {
      speakerChips[idx].indicator = indicator
    }
    refreshHistory()
  }
}

struct NotaResult {
  let markdown: String
  let outputURL: URL
}

// MARK: - History record info (cached per-document)

/// Lightweight cache of the history record matching the current document.
/// We only need `historyID` and `sourcePath` for the enroll flow, so we
/// avoid holding the full (potentially large) segments array in memory.
struct HistoryRecordInfo {
  let historyID: String
  /// Where this record's audio actually is *now*, resolved through the
  /// relative `audioPath` when the record has one (XIA-428/430) and falling
  /// back to the stored absolute `sourcePath` for records that predate it.
  /// The stored absolute path is a convenience copy and goes stale the moment
  /// `~/.nota` is moved; the relative one is the authority.
  let sourcePath: String
  /// The `~/.nota/history/<id>.json` file the info was read from, so the
  /// enrichment record can be decoded without re-scanning the directory.
  let recordURL: URL

  /// Walk `~/.nota/history/*.json` and return the record whose `outputPath`
  /// matches `outputPath`. Returns nil when no match exists (imported .md).
  static func find(outputPath: String, historyDir: URL) -> HistoryRecordInfo? {
    let fileManager = FileManager.default
    guard let entries = try? fileManager.contentsOfDirectory(
      at: historyDir,
      includingPropertiesForKeys: nil,
      options: []
    ) else {
      return nil
    }

    for entry in entries where entry.pathExtension == "json" {
      guard
        let data = try? Data(contentsOf: entry),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let recordOutput = json["outputPath"] as? String,
        recordOutput == outputPath,
        let id = json["id"] as? String,
        let audio = LiveSessionPersistence.resolvedAudioURL(
          record: json,
          historyDirectory: historyDir
        )
      else {
        continue
      }
      return HistoryRecordInfo(historyID: id, sourcePath: audio.path, recordURL: entry)
    }
    return nil
  }

  /// Persist the pinned flag on the record whose `outputPath` matches,
  /// preserving every other key (app-managed field; the CLI ignores it).
  /// No-op when no record matches (imported markdown).
  static func setPinned(_ pinned: Bool, outputPath: String, historyDir: URL) {
    guard let info = find(outputPath: outputPath, historyDir: historyDir),
          let data = try? Data(contentsOf: info.recordURL),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return
    }
    var updated = json
    updated["pinned"] = pinned
    updated["updatedAt"] = ISO8601DateFormatter().string(from: Date())
    guard let out = try? JSONSerialization.data(
      withJSONObject: updated,
      options: [.prettyPrinted]
    ) else {
      return
    }
    try? out.write(to: info.recordURL, options: .atomic)
  }

  /// outputPath (standardized) → `status` for every history record. Feeds the
  /// dashboard's "transcript" pill; records without an `outputPath` are
  /// skipped (they have no row to badge).
  static func statusesByOutputPath(historyDir: URL) -> [String: HistoryStatus] {
    kindsAndStatusesByOutputPath(historyDir: historyDir).statuses
  }

  /// outputPath (standardized) → `{status, kind}` for every history record,
  /// from a single directory scan. Records without an `outputPath` are
  /// skipped. `kind` resolves from the record's `kind` field when present,
  /// else infers a legacy record by source: live sessions written before the
  /// kind field shipped always carry the streaming model with diarize and
  /// identify off (the CLI never writes that combination for file runs), so
  /// those read as `.meeting`; everything else legacy reads as `.file`.
  static func kindsAndStatusesByOutputPath(
    historyDir: URL
  ) -> (statuses: [String: HistoryStatus], kinds: [String: HistoryKind]) {
    var statuses: [String: HistoryStatus] = [:]
    var kinds: [String: HistoryKind] = [:]
    for (key, detail) in detailsByOutputPath(historyDir: historyDir) {
      if let status = detail.status { statuses[key] = status }
      kinds[key] = detail.kind
    }
    return (statuses, kinds)
  }

  /// One record's dashboard-relevant facts, resolved from the JSON record in
  /// a single scan (status, kind incl. legacy inference, duration, unique
  /// speaker count from the segments, pinned flag).
  struct HistoryDetail: Equatable {
    /// Lifecycle status, normalized from whatever vocabulary the record was
    /// written in. Nil only for a record with no `outputPath` (never scanned)
    /// — every scanned record resolves to something.
    var status: HistoryStatus?
    /// True when the launch sweep resolved this record's failure: it presents
    /// as "Interrupted" rather than as a stage that failed on its own.
    var interrupted: Bool = false
    var kind: HistoryKind
    var durationMinutes: Int?
    var speakerCount: Int?
    var pinned: Bool = false
    /// The record's own id. Carried so a row can name the record a manual
    /// retry has to re-run (XIA-435); the drawer only ever holds the output
    /// path, and `nota history summarize` wants the id.
    var recordID: String = ""
  }

  /// outputPath (standardized) → `HistoryDetail` for every history record.
  static func detailsByOutputPath(
    historyDir: URL
  ) -> [String: HistoryDetail] {
    let fileManager = FileManager.default
    guard let entries = try? fileManager.contentsOfDirectory(
      at: historyDir,
      includingPropertiesForKeys: nil,
      options: []
    ) else {
      return [:]
    }

    var details: [String: HistoryDetail] = [:]
    for entry in entries where entry.pathExtension == "json" {
      guard
        let data = try? Data(contentsOf: entry),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let outputPath = json["outputPath"] as? String
      else {
        continue
      }
      let key = URL(fileURLWithPath: outputPath).standardizedFileURL.path
      let segments = json["segments"] as? [[String: Any]] ?? []
      var speakers = Set<String>()
      for segment in segments {
        if let speaker = segment["speaker"] as? String, !speaker.isEmpty {
          speakers.insert(speaker)
        }
      }
      details[key] = HistoryDetail(
        status: HistoryStatus.normalized(fromRecord: json),
        interrupted: json["interrupted"] as? Bool ?? false,
        kind: kind(from: json),
        durationMinutes: json["durationMinutes"] as? Int,
        speakerCount: speakers.isEmpty ? nil : speakers.count,
        pinned: json["pinned"] as? Bool ?? false,
        recordID: json["id"] as? String ?? ""
      )
    }
    return details
  }

  /// Record kind: the explicit `kind` field when present, else the legacy
  /// inference (live-session records predate the field). Internal so the
  /// home-stats aggregation (UsageStatsProvider) shares one inference rule.
  static func kind(from json: [String: Any]) -> HistoryKind {
    if let raw = json["kind"] as? String, let kind = HistoryKind(rawValue: raw) {
      return kind
    }
    let options = json["options"] as? [String: Any]
    let model = options?["model"] as? String
    let diarize = options?["diarize"] as? Bool ?? false
    let identify = options?["identify"] as? Bool ?? false
    if model == "universal-3.5-pro-streaming" && !diarize && !identify {
      return .meeting
    }
    return .file
  }
}

enum NotaAppError: LocalizedError {
  case pipelineFailed(Int32, command: String, stdout: String, stderr: String)

  var errorDescription: String? {
    switch self {
    case .pipelineFailed(let status, let command, let stdout, let stderr):
      let detail = stderr.isEmpty ? stdout : stderr
      let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        return "Transcription failed with exit code \(status)\n\nCommand:\n\(command)"
      }
      return "\(trimmed)\n\nCommand:\n\(command)"
    }
  }
}
