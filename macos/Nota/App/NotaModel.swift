import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

let supportedExtensions: Set<String> = [
  "mp3", "wav", "m4a", "aac", "caf", "aif", "aiff", "ogg", "webm", "flac", "qta", "mov", "mp4"
]

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

  /// History-record status per output path (standardized), driving the
  /// dashboard's "transcript" pill on transcript-only Recent rows.
  @Published private(set) var historyStatuses: [String: String] = [:]

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
    // Re-render whenever enrichment state changes: the document view's summary
    // slot, header tag chips, and stripped body all derive from the controller.
    enrichmentSink = enrichment.objectWillChange.sink { [weak self] in
      self?.objectWillChange.send()
    }
    enrichment.onRecordUpdated = { [weak self] record, kind in
      self?.handleEnrichmentUpdate(record, kind: kind)
    }
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

  /// History-record status ("transcribed"/"completed") for a dashboard entry,
  /// nil when no record matches (e.g. imported markdown).
  func recordStatus(for entry: HistoryEntry) -> String? {
    historyStatuses[entry.url.standardizedFileURL.path]
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

  /// Begin a live dictation/transcription session. The pane switches to the
  /// live view when the session enters `.recording` (ContentView reads
  /// `liveSession.state`); start failures surface through the session's own
  /// `.failed` state (rendered by the live pane's error banner) and are
  /// mirrored here for the status pill.
  func startLiveSession() {
    guard liveSession.state != .recording, liveSession.state != .stopping else {
      return
    }
    status = "Recording…"
    Task {
      do {
        try await liveSession.start()
      } catch {
        status = "Live session failed: \(error.localizedDescription)"
      }
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
    guard liveSession.state == .recording || liveSession.state == .stopping else {
      return
    }
    status = "Saving live session…"
    Task {
      let result: LiveMeetingSession.LiveMeetingResult
      do {
        result = try await liveSession.stop()
      } catch {
        status = "Live session failed: \(error.localizedDescription)"
        return
      }

      do {
        let saved = try LiveSessionPersistence.persist(
          result: result,
          outputDirectory: outputDirectory,
          historyDirectory: notaHistoryDirectory()
        )
        markdown = saved.markdown
        lastOutputURL = saved.outputURL
        status = "Complete"
        refreshHistory()
        if let entry = history.first(where: {
          $0.url.standardizedFileURL == saved.outputURL.standardizedFileURL
        }) {
          selectedHistoryID = entry.id
          // Mirror openHistory: keep the header coherent with the new doc.
          displayName = entry.title
          displayPath = entry.url.path
        }
        // Resets the enrichment record/speaker chips for the new document;
        // the async lookup finds the fresh record (no summary → placeholder).
        loadChips(for: saved.outputURL)
      } catch LiveSessionPersistenceError.emptyTranscript {
        status = LiveSessionPersistenceError.emptyTranscript.errorDescription ?? "No speech was captured"
      } catch LiveSessionPersistenceError.missingAudio {
        status = LiveSessionPersistenceError.missingAudio.errorDescription ?? "Recording failed"
      } catch {
        status = "Could not save live session"
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
      return HistoryEntry.make(url: url, modifiedAt: date)
    }
    history = entries.sorted { $0.modifiedAt > $1.modifiedAt }
    refreshHistoryStatuses()
  }

  /// Rebuild the outputPath → record-status map off the main thread (history
  /// records carry full transcripts, so parsing them inline would jank).
  private func refreshHistoryStatuses() {
    let historyDir = notaHistoryDirectory()
    Task { @MainActor [weak self] in
      let statuses = await Task.detached(priority: .utility) {
        HistoryRecordInfo.statusesByOutputPath(historyDir: historyDir)
      }.value
      self?.historyStatuses = statuses
    }
  }

  func openHistory(_ entry: HistoryEntry) {
    guard !isRunning else {
      return
    }
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
      if identifySpeakers {
        arguments.append("--identify")
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
      let (info, record) = await Task.detached(priority: .utility) { () -> (HistoryRecordInfo?, EnrichmentRecord?) in
        let info = HistoryRecordInfo.find(outputPath: docPath, historyDir: historyDir)
        let record = info.flatMap { EnrichmentRecord.load(from: $0.recordURL) }
        return (info, record)
      }.value
      self.cachedHistoryRecord = info
      self.enrichment.setRecord(record)
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
    }
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
        let source = json["sourcePath"] as? String
      else {
        continue
      }
      return HistoryRecordInfo(historyID: id, sourcePath: source, recordURL: entry)
    }
    return nil
  }

  /// outputPath (standardized) → `status` for every history record. Feeds the
  /// dashboard's "transcript" pill; records without an `outputPath` are
  /// skipped (they have no row to badge).
  static func statusesByOutputPath(historyDir: URL) -> [String: String] {
    let fileManager = FileManager.default
    guard let entries = try? fileManager.contentsOfDirectory(
      at: historyDir,
      includingPropertiesForKeys: nil,
      options: []
    ) else {
      return [:]
    }

    var statuses: [String: String] = [:]
    for entry in entries where entry.pathExtension == "json" {
      guard
        let data = try? Data(contentsOf: entry),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let outputPath = json["outputPath"] as? String,
        let status = json["status"] as? String
      else {
        continue
      }
      statuses[URL(fileURLWithPath: outputPath).standardizedFileURL.path] = status
    }
    return statuses
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
