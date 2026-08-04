import Foundation

// MARK: - Enroll result

enum EnrollResult {
  case enrolled
  /// Sidecar written, voiceprint skipped — carries user-facing hint.
  case skipped(reason: EnrollSkipReason)
  /// Extraction crashed — stderr tail available for tooltip.
  case failed(stderr: String)
}

enum EnrollSkipReason {
  case noHistoryRecord
  case audioMissing
  case runtimeUnavailable
  case insufficientSpeech

  var tooltip: String {
    switch self {
    case .noHistoryRecord: return "no history record"
    case .audioMissing:    return "audio missing"
    case .runtimeUnavailable: return "voiceprint runtime unavailable"
    case .insufficientSpeech: return "insufficient speech in clip"
    }
  }
}

// MARK: - Serial enroll queue

/// Serializes `nota enroll` shell invocations so two rapid renames cannot
/// race on speakers.json. Each task carries back an `EnrollResult` on the
/// main actor. Mirrors `shellMergeSpeakers` in `SpeakerProfileStore`.
actor EnrollQueue {
  static let shared = EnrollQueue()

  private var pending: [() async -> Void] = []
  private var isRunning = false

  private let projectDirectory = URL(
    fileURLWithPath: ProcessInfo.processInfo.environment["NOTA_PROJECT_DIR"]
      ?? "/Users/xiafawu/Developer/Nota"
  )

  /// Enqueue a `nota enroll` job. Calls `onResult` on the main actor when done.
  func enqueue(
    historyID: String,
    label: String,
    name: String,
    onResult: @escaping @MainActor (EnrollResult) -> Void
  ) {
    let projectDir = projectDirectory
    pending.append {
      let result = await Self.run(
        historyID: historyID,
        label: label,
        name: name,
        projectDirectory: projectDir
      )
      await MainActor.run {
        onResult(result)
      }
    }
    if !isRunning {
      Task { await self.drain() }
    }
  }

  /// Enqueue a `nota history rename-speaker` job: rewrites the record's
  /// segments, stored clip, and the output markdown's transcript lines so
  /// the document and a later summary regeneration carry the name. Shares
  /// this serial queue with enroll on purpose — enroll must read the clip
  /// under the OLD label before rename moves it, and the two must never race
  /// on the record JSON. Calls `onDone(success, stderrTail)` on the main actor.
  func enqueueTranscriptRename(
    historyID: String,
    label: String,
    name: String,
    onDone: @escaping @MainActor (Bool, String) -> Void
  ) {
    let projectDir = projectDirectory
    pending.append {
      let (ok, tail) = await Self.runRename(
        historyID: historyID,
        label: label,
        name: name,
        projectDirectory: projectDir
      )
      await MainActor.run {
        onDone(ok, tail)
      }
    }
    if !isRunning {
      Task { await self.drain() }
    }
  }

  /// Enqueue a `nota history accept-suggestion` job: renames the label to the
  /// suggested name everywhere (segments, clip, output markdown) AND enrolls
  /// the clip as a new voiceprint AND marks the suggestion accepted — one CLI
  /// verb, atomic on its side. Shares this serial queue with enroll/rename so
  /// an accept can never race speakers.json or the record JSON. Maps exit
  /// codes exactly like `nota enroll`: 2 = record missing, 3 = clip missing,
  /// 4 = identity unavailable, 5 = insufficient speech. Calls `onResult` on
  /// the main actor.
  func enqueueSuggestionAccept(
    historyID: String,
    label: String,
    onResult: @escaping @MainActor (EnrollResult) -> Void
  ) {
    let projectDir = projectDirectory
    pending.append {
      let result = await Self.runAccept(
        historyID: historyID,
        label: label,
        projectDirectory: projectDir
      )
      await MainActor.run {
        onResult(result)
      }
    }
    if !isRunning {
      Task { await self.drain() }
    }
  }

  /// Enqueue a `nota history dismiss-suggestion` job: decision state only —
  /// the record's segments, clips, and store stay untouched. Shares the
  /// serial queue with accept so a dismiss can't interleave with an
  /// accept/rename/enroll for the same label. Calls `onDone(success,
  /// stderrTail)` on the main actor.
  func enqueueSuggestionDismiss(
    historyID: String,
    label: String,
    onDone: @escaping @MainActor (Bool, String) -> Void
  ) {
    let projectDir = projectDirectory
    pending.append {
      let (ok, tail) = await Self.runDismiss(
        historyID: historyID,
        label: label,
        projectDirectory: projectDir
      )
      await MainActor.run {
        onDone(ok, tail)
      }
    }
    if !isRunning {
      Task { await self.drain() }
    }
  }

  private func drain() async {
    isRunning = true
    while !pending.isEmpty {
      let task = pending.removeFirst()
      await task()
    }
    isRunning = false
  }

  // MARK: - Shell runner

  private static func runRename(
    historyID: String,
    label: String,
    name: String,
    projectDirectory: URL
  ) async -> (Bool, String) {
    let (status, stderr) = await Self.spawn(
      arguments: ["history", "rename-speaker", historyID, label, name],
      projectDirectory: projectDirectory
    )
    return (status == 0, String(stderr.suffix(200)))
  }

  private static func run(
    historyID: String,
    label: String,
    name: String,
    projectDirectory: URL
  ) async -> EnrollResult {
    let (status, stderr) = await Self.spawn(
      arguments: ["enroll", historyID, label, name],
      projectDirectory: projectDirectory
    )
    switch status {
    case 0:
      return .enrolled
    case 2:
      return .skipped(reason: .noHistoryRecord)
    case 3:
      return .skipped(reason: .audioMissing)
    case 4:
      return .skipped(reason: .runtimeUnavailable)
    default:
      // Capture last 200 chars of stderr for the tooltip
      let tail = String(stderr.suffix(200))
      return .failed(stderr: tail.isEmpty ? "exit \(status)" : tail)
    }
  }

  /// `nota history accept-suggestion <id> <label>` — exit codes mirror
  /// `nota enroll`, with 5 (insufficient speech) mapped to a skipped state.
  private static func runAccept(
    historyID: String,
    label: String,
    projectDirectory: URL
  ) async -> EnrollResult {
    let (status, stderr) = await Self.spawn(
      arguments: ["history", "accept-suggestion", historyID, label],
      projectDirectory: projectDirectory
    )
    switch status {
    case 0:
      return .enrolled
    case 2:
      return .skipped(reason: .noHistoryRecord)
    case 3:
      return .skipped(reason: .audioMissing)
    case 4:
      return .skipped(reason: .runtimeUnavailable)
    case 5:
      return .skipped(reason: .insufficientSpeech)
    default:
      let tail = String(stderr.suffix(200))
      return .failed(stderr: tail.isEmpty ? "exit \(status)" : tail)
    }
  }

  /// `nota history dismiss-suggestion <id> <label>` — decision state only.
  private static func runDismiss(
    historyID: String,
    label: String,
    projectDirectory: URL
  ) async -> (Bool, String) {
    let (status, stderr) = await Self.spawn(
      arguments: ["history", "dismiss-suggestion", historyID, label],
      projectDirectory: projectDirectory
    )
    return (status == 0, String(stderr.suffix(200)))
  }

  /// Run one CLI verb (`node dist/index.js <arguments…>`, falling back to
  /// `npx tsx src/index.ts`) and return the exit status plus stderr. Shared
  /// by enroll / rename-speaker / accept-suggestion / dismiss-suggestion so
  /// every verb spawns through the same runner. 30-second timeout — history +
  /// voiceprint extraction can be slow.
  private static func spawn(
    arguments: [String],
    projectDirectory: URL
  ) async -> (status: Int32, stderr: String) {
    await withCheckedContinuation { continuation in
      let process = Process()
      process.currentDirectoryURL = projectDirectory

      let distEntry = projectDirectory
        .appendingPathComponent("dist")
        .appendingPathComponent("index.js")
      let srcEntry = projectDirectory
        .appendingPathComponent("src")
        .appendingPathComponent("index.ts")

      if FileManager.default.fileExists(atPath: distEntry.path) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", distEntry.path] + arguments
      } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["npx", "tsx", srcEntry.path] + arguments
      }

      let outPipe = Pipe()
      let errPipe = Pipe()
      process.standardOutput = outPipe
      process.standardError = errPipe

      let timeoutItem = DispatchWorkItem {
        process.terminate()
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeoutItem)

      do {
        try process.run()
        process.waitUntilExit()
        timeoutItem.cancel()
      } catch {
        timeoutItem.cancel()
        continuation.resume(returning: (1, error.localizedDescription))
        return
      }

      let stderr = (String(
        data: errPipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
      ) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

      continuation.resume(returning: (process.terminationStatus, stderr))
    }
  }
}
