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
