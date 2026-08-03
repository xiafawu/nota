import Foundation

/// Health status of a single preflight check. Mirrors the CLI JSON contract
/// (`nota preflight --json`). Each status maps to one traffic-light color and a
/// fixed consequence, so the UI never re-derives severity.
enum PreflightStatus: String, Codable {
  case ok        // green  — verified working
  case fail      // red    — will fail deterministically (blocks recording if blocking)
  case unverified // yellow — couldn't verify (offline / timeout / 5xx)
  case optional  // grey   — not required; never blocks

  /// Unknown future statuses degrade to grey rather than crashing the decode.
  init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = PreflightStatus(rawValue: raw) ?? .optional
  }
}

/// The overall verdict that drives the hero dot and the Record button.
enum PreflightOverall: String, Codable {
  case ready
  case blocked
  case unverified

  init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = PreflightOverall(rawValue: raw) ?? .unverified
  }
}

struct PreflightCheck: Codable, Identifiable {
  let id: String
  let label: String
  let status: PreflightStatus
  let detail: String
  let blocking: Bool
  let httpStatus: Int?
}

struct PreflightResult: Codable {
  let overall: PreflightOverall
  let checks: [PreflightCheck]
  let checkedAt: String

  /// Checks that need attention (red or yellow), surfaced above the fold.
  var attention: [PreflightCheck] {
    checks.filter { $0.status == .fail || $0.status == .unverified }
  }

  /// Checks that are fine (green or grey), tucked under the fold.
  var passing: [PreflightCheck] {
    checks.filter { $0.status == .ok || $0.status == .optional }
  }
}

/// The entry cards a failing preflight check can gate (F1, XIA-394).
enum EntryCard: CaseIterable, Hashable {
  case meeting
  case file
  case memo
}

extension PreflightCheck {
  /// Short display name for the "Needs setup — <what>" tag.
  var shortLabel: String {
    switch id {
    case "audio-tools": return "Audio tools"
    case "transcription": return "Transcription"
    case "summary": return "Summary"
    case "identity": return "Speaker identity"
    case "diarization": return "Diarization"
    default: return label
    }
  }

  /// The entry card(s) this check gates when it FAILS (F1 mapping):
  /// - `audio-tools` (ffmpeg): file runs only — live sessions never invoke
  ///   ffmpeg.
  /// - `transcription`: meeting + file. Memo is exempt — the memo card runs
  ///   on the Apple engine without an AssemblyAI key.
  /// - `summary`: file + memo (both summarize). Meeting live sessions do not
  ///   summarize yet, so the summary check never gates them.
  /// - `identity` / `diarization`: never gate (optional / off the app path).
  /// `unverified` checks never gate either — they are proceed-at-risk, not
  /// deterministic failures.
  var gatedCards: Set<EntryCard> {
    switch id {
    case "audio-tools": return [.file]
    case "transcription": return [.meeting, .file]
    case "summary": return [.file, .memo]
    default: return []
    }
  }
}

/// The health pill's derived state (pure — tested without a view).
enum HealthPillState: Equatable {
  case notChecked
  case ready
  /// Attention = failing + unverified checks. `hasFail` picks the pill color:
  /// red when any deterministic failure exists, yellow otherwise.
  case issues(count: Int, hasFail: Bool)

  static func make(result: PreflightResult?) -> HealthPillState {
    guard let result else { return .notChecked }
    let attention = result.attention
    guard !attention.isEmpty else { return .ready }
    return .issues(
      count: attention.count,
      hasFail: attention.contains { $0.status == .fail }
    )
  }
}

/// F1 card gating (XIA-394): the first FAILING check that affects a card
/// yields its "Needs setup — <what>" reason. `unverified` never gates
/// (proceed-at-risk); identity is optional and never blocks.
enum HomeGating {
  static func reason(result: PreflightResult?, card: EntryCard) -> String? {
    guard let result else { return nil }
    return result.checks
      .filter { $0.status == .fail && $0.gatedCards.contains(card) }
      .first?
      .shortLabel
  }
}

enum PreflightError: LocalizedError {
  case decodeFailed(String)
  case runnerFailed(Int32, stderr: String)

  var errorDescription: String? {
    switch self {
    case .decodeFailed(let detail):
      return "Couldn't read preflight output: \(detail)"
    case .runnerFailed(let code, let stderr):
      let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      return "Preflight runner exited \(code)\(trimmed.isEmpty ? "" : ": \(trimmed)")"
    }
  }
}

/// Runs `nota preflight --json` via the app's shell runner and decodes the
/// result. Kept off the main actor; callers hop back to update UI state.
enum PreflightRunner {
  static func run(projectDirectory: URL, refresh: Bool) async throws -> PreflightResult {
    try await Task.detached(priority: .userInitiated) {
      let runnerURL = projectDirectory
        .appendingPathComponent("scripts", isDirectory: true)
        .appendingPathComponent("nota-app-preflight.sh")

      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/bash")
      process.currentDirectoryURL = projectDirectory
      var arguments = [runnerURL.path]
      if refresh { arguments.append("--refresh") }
      process.arguments = arguments

      let outputPipe = Pipe()
      let errorPipe = Pipe()
      process.standardOutput = outputPipe
      process.standardError = errorPipe
      // Never inherit stdin: when the app itself was launched from a terminal
      // (e.g. as an xcodebuild test host), the child sees a pty slave and
      // node's TTY bootstrap re-opens it via ttyname(), where open(2) can
      // block forever — leaving an orphaned `nota preflight` process that
      // keeps the app's ghost Dock icon alive after exit.
      process.standardInput = FileHandle.nullDevice

      try process.run()
      // Drain before waitUntilExit so a large JSON payload can't deadlock the pipe.
      let outData = outputPipe.fileHandleForReading.readDataToEndOfFile()
      let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()

      // `nota preflight` exits 1 when blocked — that is a valid, decodable
      // result, not a runner failure. Only treat a missing/undecodable payload
      // as an error.
      do {
        return try JSONDecoder().decode(PreflightResult.self, from: outData)
      } catch {
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 && process.terminationStatus != 1 {
          throw PreflightError.runnerFailed(process.terminationStatus, stderr: stderr)
        }
        throw PreflightError.decodeFailed(
          error.localizedDescription + (stderr.isEmpty ? "" : "\n\(stderr)")
        )
      }
    }.value
  }
}
