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

  var tooltip: String {
    switch self {
    case .noHistoryRecord: return "no history record"
    case .audioMissing:    return "audio missing"
    case .runtimeUnavailable: return "voiceprint runtime unavailable"
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

  private func drain() async {
    isRunning = true
    while !pending.isEmpty {
      let task = pending.removeFirst()
      await task()
    }
    isRunning = false
  }

  // MARK: - Shell runner

  private static func run(
    historyID: String,
    label: String,
    name: String,
    projectDirectory: URL
  ) async -> EnrollResult {
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
        process.arguments = ["node", distEntry.path, "enroll", historyID, label, name]
      } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["npx", "tsx", srcEntry.path, "enroll", historyID, label, name]
      }

      let outPipe = Pipe()
      let errPipe = Pipe()
      process.standardOutput = outPipe
      process.standardError = errPipe

      // 30-second timeout — history + pyannote extraction can be slow
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
        continuation.resume(returning: .failed(stderr: error.localizedDescription))
        return
      }

      let stderr = (String(
        data: errPipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
      ) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

      switch process.terminationStatus {
      case 0:
        continuation.resume(returning: .enrolled)
      case 2:
        continuation.resume(returning: .skipped(reason: .noHistoryRecord))
      case 3:
        continuation.resume(returning: .skipped(reason: .audioMissing))
      case 4:
        continuation.resume(returning: .skipped(reason: .runtimeUnavailable))
      default:
        // Capture last 200 chars of stderr for the tooltip
        let tail = String(stderr.suffix(200))
        continuation.resume(returning: .failed(stderr: tail.isEmpty ? "exit \(process.terminationStatus)" : tail))
      }
    }
  }
}
