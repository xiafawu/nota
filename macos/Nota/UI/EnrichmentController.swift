import Foundation

// MARK: - History record schema (enrichment slice of HistoryRecord in history.ts)

/// The summary object stored on a history record. Mirrors `MeetingSummary`,
/// but every field decodes as optional so partial records (e.g. tags-only
/// enrichment on a transcribed record) and legacy shapes never fail to decode.
struct EnrichmentSummary: Codable, Equatable {
  var title: String?
  var tags: [String]?
  var narrative: String?
  var keyTopics: [String]?
  var decisions: [String]?
  var actionItems: [String]?
}

/// The enrichment-relevant slice of a `~/.nota/history/<id>.json` record.
/// Unknown keys (segments, usage, …) are ignored by Codable; `summaryEdited`
/// and `tagsEdited` are the E3 per-field flags — absent on legacy records,
/// which reads as "never edited".
struct EnrichmentRecord: Codable, Equatable {
  let id: String
  var status: String
  var summary: EnrichmentSummary?
  var summaryEdited: Bool?
  var tagsEdited: Bool?
  var outputPath: String?

  var tags: [String] { summary?.tags ?? [] }
  var isSummaryEdited: Bool { summaryEdited ?? false }
  var isTagsEdited: Bool { tagsEdited ?? false }
  var hasSummaryNarrative: Bool { !(summary?.narrative ?? "").isEmpty }

  static func decode(_ data: Data) throws -> EnrichmentRecord {
    do {
      return try JSONDecoder().decode(EnrichmentRecord.self, from: data)
    } catch {
      throw EnrichmentCLIError.decodeFailed(
        "Expected history record JSON. \(error.localizedDescription)"
      )
    }
  }

  static func load(from url: URL) -> EnrichmentRecord? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? decode(data)
  }
}

/// stdin payload for `nota history apply-enrichment <id> --json`. Synthesized
/// Codable skips nil fields, matching the contract's optional shape
/// `{summary?, tags?, summaryEdited?, tagsEdited?}`.
struct EnrichmentEditPayload: Codable, Equatable {
  var summary: String?
  var tags: [String]?
  var summaryEdited: Bool?
  var tagsEdited: Bool?
}

// MARK: - Pure state helpers (unit-tested)

enum EnrichmentActivity: Equatable {
  case idle
  case summarizing
  case tagging
}

enum EnrichmentField: Equatable {
  case summary
  case tags
}

/// The single layout slot between the document header and the transcript:
/// placeholder → in-flight row → summary section (E2 single-slot morph).
enum EnrichmentSlotState: Equatable {
  case hidden
  case placeholder
  case generating(kind: EnrichmentActivity, modelID: String)
  case summary(narrative: String, edited: Bool)
}

/// Select the slot state from the record + in-flight activity. Record is
/// truth: the summary section and Edited badge derive from record fields,
/// never from UI-local state.
func enrichmentSlotState(
  record: EnrichmentRecord?,
  activity: EnrichmentActivity,
  modelID: String
) -> EnrichmentSlotState {
  guard let record else { return .hidden }
  if activity != .idle {
    return .generating(kind: activity, modelID: modelID)
  }
  if record.hasSummaryNarrative {
    return .summary(narrative: record.summary?.narrative ?? "", edited: record.isSummaryEdited)
  }
  if record.status == "transcribed" {
    return .placeholder
  }
  return .hidden
}

/// Edited-is-protected: regeneration over a field requires confirmation only
/// when that field's edited flag is set on the record.
func enrichmentNeedsConfirm(record: EnrichmentRecord?, target: EnrichmentField) -> Bool {
  guard let record else { return false }
  switch target {
  case .summary: return record.isSummaryEdited
  case .tags: return record.isTagsEdited
  }
}

/// Dashboard predicate: transcript-only records get the subtle "transcript"
/// pill; it clears once the record completes (or when no record is known).
func showsTranscriptPill(recordStatus: String?) -> Bool {
  recordStatus == "transcribed"
}

/// Remove the enrichment sections (`## Summary`, `## Key Topics`,
/// `## Decisions Made`, `## Action Items`) from a document's markdown.
/// Used for display when the enrichment slot renders the whole summary block
/// from the record instead — the body stays transcript-only. Each section is
/// stripped independently (any order, any subset present) and spans from its
/// heading up to the next `## ` heading or a `---` rule; the rule itself is
/// kept. Copy/export always use the full markdown.
func strippingEnrichmentSections(_ markdown: String) -> String {
  let headings: Set<String> = [
    "## Summary", "## Key Topics", "## Decisions Made", "## Action Items",
  ]
  let lines = markdown.components(separatedBy: "\n")
  var kept: [String] = []
  var index = 0
  while index < lines.count {
    guard headings.contains(lines[index].trimmingCharacters(in: .whitespaces)) else {
      kept.append(lines[index])
      index += 1
      continue
    }
    index += 1
    while index < lines.count {
      let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("## ") || trimmed == "---" { break }
      index += 1
    }
  }
  return kept.joined(separator: "\n")
}

/// Split a key-topic string into a chip term and optional hover detail at the
/// FIRST ` — ` (space, em dash, space) separator. A plain hyphen is not a
/// separator; a missing or empty remainder yields a nil detail.
func topicChipParts(_ topic: String) -> (term: String, detail: String?) {
  guard let separator = topic.range(of: " \u{2014} ") else {
    return (topic.trimmingCharacters(in: .whitespaces), nil)
  }
  let term = String(topic[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
  let detail = String(topic[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
  return (term, detail.isEmpty ? nil : detail)
}

/// Parse a summary list item's inline markdown (`**bold**`, `*italic*`,
/// `` `code` ``) for slot display — the record stores the model's markdown
/// verbatim, and rendering it raw leaks literal asterisks into the UI.
/// Inline-only: block syntax stays literal, whitespace is preserved. Falls
/// back to the raw string when parsing fails.
func inlineMarkdownAttributed(_ text: String) -> AttributedString {
  (try? AttributedString(
    markdown: text,
    options: AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
  )) ?? AttributedString(text)
}

/// Flatten inline markdown to plain text — for surfaces that can't carry
/// formatting (chip faces, `.help` tooltips).
func strippingInlineMarkdown(_ text: String) -> String {
  String(inlineMarkdownAttributed(text).characters)
}

// MARK: - Errors

enum EnrichmentCLIError: LocalizedError {
  case cliFailed(Int32, stderr: String)
  case decodeFailed(String)

  var errorDescription: String? {
    switch self {
    case .cliFailed(let code, let stderr):
      let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      return detail.isEmpty ? "Nota CLI failed (exit \(code))" : detail
    case .decodeFailed(let detail):
      return "Failed to parse CLI response: \(detail)"
    }
  }
}

// MARK: - Process layer

/// Runs `node dist/index.js <arguments…>` and returns stdout. Mocked in unit
/// tests; the real implementation spawns the CLI like `UsageStatsProvider`.
/// Implementations must kill the child process when the surrounding task is
/// cancelled (Cancel in the in-flight row → nothing written).
protocol EnrichmentProcessRunning: Sendable {
  func run(arguments: [String], stdinJSON: Data?) async throws -> Data
}

/// Shell out with the UsageStatsProvider PATH/build-if-missing pattern.
/// Arguments are passed positionally through `"$@"` so history ids never go
/// through string interpolation into the script.
struct EnrichmentCLIProcess: EnrichmentProcessRunning {
  let projectDirectory: URL

  func run(arguments: [String], stdinJSON: Data?) async throws -> Data {
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
      cd "$1" || exit 1
      shift
      if [ ! -f "dist/index.js" ]; then
        npm run build 2>/dev/null || exit 1
      fi
      exec node dist/index.js "$@"
      """#,
      "nota",
      projectDirectory.path,
    ] + arguments

    let stdinPipe = Pipe()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    shell.standardInput = stdinPipe
    shell.standardOutput = outputPipe
    shell.standardError = errorPipe

    try shell.run()

    if let stdinJSON {
      try? stdinPipe.fileHandleForWriting.write(contentsOf: stdinJSON)
    }
    try? stdinPipe.fileHandleForWriting.close()

    return try await withTaskCancellationHandler {
      let outputData = await Self.collectOutput(outputPipe.fileHandleForReading)
      let errorData = await Self.collectOutput(errorPipe.fileHandleForReading)
      shell.waitUntilExit()

      if Task.isCancelled {
        throw CancellationError()
      }
      guard shell.terminationStatus == 0 else {
        let stderr = String(data: errorData, encoding: .utf8) ?? ""
        throw EnrichmentCLIError.cliFailed(shell.terminationStatus, stderr: stderr)
      }
      return outputData
    } onCancel: {
      shell.terminate()
    }
  }

  /// Drain a file handle to EOF asynchronously (same shape as UsageStatsProvider).
  private static func collectOutput(_ handle: FileHandle) async -> Data {
    await withCheckedContinuation { continuation in
      handle.readabilityHandler = { fh in
        let data = fh.readDataToEndOfFile()
        fh.readabilityHandler = nil
        continuation.resume(returning: data)
      }
    }
  }
}

// MARK: - Controller

/// Owns the enrichment state for the currently open document and performs
/// every mutation by spawning the CLI contract verbs (`summarize`, `tag`,
/// `history apply-enrichment`). Swift never writes history JSON or markdown;
/// the CLI updates the record (record-first) and rewrites the `.md`, and the
/// updated record JSON on stdout becomes the new truth here.
@MainActor
final class EnrichmentController: ObservableObject {
  enum UpdateKind {
    /// A paid generation finished (usage entries were appended on the record).
    case generated
    /// A manual edit was applied via apply-enrichment.
    case edited
  }

  static let shared = EnrichmentController()

  @Published private(set) var record: EnrichmentRecord?
  @Published private(set) var activity: EnrichmentActivity = .idle
  @Published private(set) var generatingModelID = ""
  @Published private(set) var isSavingEdit = false
  @Published var errorMessage: String?

  /// Fired after any successful CLI mutation so the app model can reload the
  /// rewritten `.md`, refresh the dashboard pill, and (for generations)
  /// invalidate the usage-stats cache.
  var onRecordUpdated: ((EnrichmentRecord, UpdateKind) -> Void)?

  private let runner: EnrichmentProcessRunning
  private let summaryModelResolver: @MainActor () -> String
  private var generationTask: Task<Void, Never>?
  /// Monotonic guard: a cancelled/stale generation's epilogue must not stomp
  /// state that belongs to a newer generation.
  private var generationID = 0

  init(
    runner: EnrichmentProcessRunning? = nil,
    summaryModelResolver: (@MainActor () -> String)? = nil
  ) {
    let projectDirectory = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["NOTA_PROJECT_DIR"]
        ?? "/Users/xiafawu/Developer/Nota"
    )
    self.runner = runner ?? EnrichmentCLIProcess(projectDirectory: projectDirectory)
    self.summaryModelResolver = summaryModelResolver
      ?? { NotaSettingsStore.effectiveModel(for: .summary) }
  }

  /// Install the record backing the currently open document (nil = none).
  /// Cancels any in-flight generation for the previous document.
  func setRecord(_ newRecord: EnrichmentRecord?) {
    if activity != .idle {
      cancelGeneration()
    }
    // Epoch bump: an edit-save still in flight for the PREVIOUS document must
    // not install its result over the new document's record.
    generationID += 1
    record = newRecord
    errorMessage = nil
  }

  // MARK: Generation (summarize / tag verbs)

  @discardableResult
  func generateSummary(force: Bool = false) -> Task<Void, Never>? {
    guard let record else { return nil }
    return generate(.summarizing, arguments: ["summarize", record.id] + (force ? ["--force"] : []))
  }

  @discardableResult
  func generateTags(force: Bool = false) -> Task<Void, Never>? {
    guard let record else { return nil }
    return generate(.tagging, arguments: ["tag", record.id] + (force ? ["--force"] : []))
  }

  /// Kill the in-flight generation process; nothing is written.
  func cancelGeneration() {
    generationTask?.cancel()
    generationTask = nil
    generationID += 1
    activity = .idle
  }

  private func generate(_ kind: EnrichmentActivity, arguments: [String]) -> Task<Void, Never>? {
    guard activity == .idle else { return nil }
    errorMessage = nil
    activity = kind
    generatingModelID = summaryModelResolver()
    generationID += 1
    let id = generationID

    let task = Task { [runner] in
      do {
        let stdout = try await runner.run(arguments: arguments, stdinJSON: nil)
        let updated = try EnrichmentRecord.decode(stdout)
        guard self.generationID == id else { return }
        self.record = updated
        self.onRecordUpdated?(updated, .generated)
      } catch is CancellationError {
        // Cancelled: the process was killed, nothing was written.
      } catch {
        guard self.generationID == id else { return }
        self.errorMessage = error.localizedDescription
      }
      if self.generationID == id {
        self.activity = .idle
      }
    }
    generationTask = task
    return task
  }

  // MARK: Edits (hidden apply-enrichment verb)

  /// Persist a manually edited summary. Empty text is never written — the
  /// record keeps its existing summary (empty-content-is-a-failure rule).
  @discardableResult
  func saveSummaryEdit(_ narrative: String) -> Task<Void, Never>? {
    let trimmed = narrative.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return applyEdit(EnrichmentEditPayload(summary: trimmed, summaryEdited: true))
  }

  /// Append a manual tag (lowercase-normalized, case-insensitive dedup).
  @discardableResult
  func addTag(_ raw: String) -> Task<Void, Never>? {
    let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !tag.isEmpty, let record else { return nil }
    var tags = record.tags
    guard !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else {
      return nil
    }
    tags.append(tag)
    return applyEdit(EnrichmentEditPayload(tags: tags, tagsEdited: true))
  }

  @discardableResult
  func removeTag(_ tag: String) -> Task<Void, Never>? {
    guard let record else { return nil }
    let tags = record.tags.filter { $0.caseInsensitiveCompare(tag) != .orderedSame }
    guard tags.count != record.tags.count else { return nil }
    return applyEdit(EnrichmentEditPayload(tags: tags, tagsEdited: true))
  }

  private func applyEdit(_ payload: EnrichmentEditPayload) -> Task<Void, Never>? {
    guard let record, !isSavingEdit else { return nil }
    errorMessage = nil
    isSavingEdit = true
    let id = generationID

    return Task { [runner] in
      do {
        let stdin = try JSONEncoder().encode(payload)
        let stdout = try await runner.run(
          arguments: ["history", "apply-enrichment", record.id, "--json"],
          stdinJSON: stdin
        )
        let updated = try EnrichmentRecord.decode(stdout)
        // The CLI wrote the right record for the right id either way; only the
        // in-memory install must be skipped once the document has switched.
        if self.generationID == id {
          self.record = updated
        }
        self.onRecordUpdated?(updated, .edited)
      } catch {
        if self.generationID == id {
          self.errorMessage = error.localizedDescription
        }
      }
      self.isSavingEdit = false
    }
  }
}
