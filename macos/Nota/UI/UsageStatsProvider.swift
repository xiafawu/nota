import Foundation

// MARK: - JSON schema (mirrors ModelSummaryRow in usage-stats.ts)

struct ModelUsageRow: Codable, Equatable {
  let modelId: String
  let provider: String
  let runs: Int
  let calls: Int
  let tokensIn: Int
  let tokensOut: Int
  let costUSD: Double
  let hasUnknown: Bool
  let hasEstimated: Bool
}

struct UsageSummaryResponse: Codable, Equatable {
  let window: String
  let rows: [ModelUsageRow]
}

// MARK: - Errors

enum UsageStatsProviderError: LocalizedError {
  case cliFailed(Int32, stderr: String)
  case decodeFailed(String)

  var errorDescription: String? {
    switch self {
    case .cliFailed(let code, let stderr):
      return "Usage stats CLI failed (exit \(code)): \(stderr)"
    case .decodeFailed(let detail):
      return "Failed to parse usage stats: \(detail)"
    }
  }
}

// MARK: - Provider

/// Spawns `nota usage --json`, decodes the response, and caches per window.
@MainActor
final class UsageStatsProvider: ObservableObject {
  @Published var summary: UsageSummaryResponse?
  @Published var isLoading = false
  @Published var error: Error?

  private let projectDirectory: URL
  private var cache: [String: UsageSummaryResponse] = [:]

  init(projectDirectory: URL) {
    self.projectDirectory = projectDirectory
  }

  /// Clear the cache so the next refresh re-fetches regardless of window.
  func invalidateCache() {
    cache.removeAll()
  }

  /// Refresh usage stats for the given window.
  /// Uses an in-memory cache keyed by window; call `invalidateCache()` to
  /// force a re-fetch (e.g. after a completed transcription run).
  func refresh(window: String = "30d") async {
    isLoading = true
    error = nil

    if let cached = cache[window] {
      summary = cached
      isLoading = false
      return
    }

    do {
      let response = try await fetch(window: window)
      cache[window] = response
      summary = response
    } catch let fetchError {
      self.error = fetchError
    }

    isLoading = false
  }

  // MARK: - Private

  private func fetch(window: String) async throws -> UsageSummaryResponse {
    let stdout = try await runCLI(window: window)

    guard let data = stdout.data(using: .utf8),
          let response = try? JSONDecoder().decode(UsageSummaryResponse.self, from: data)
    else {
      throw UsageStatsProviderError.decodeFailed(
        "Expected JSON with 'window' and 'rows' fields. Got: "
          + String(stdout.prefix(200))
      )
    }

    return response
  }

  /// Shell out to `node dist/index.js usage --json --window <window>`.
  private func runCLI(window: String) async throws -> String {
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
      if [ ! -f "dist/index.js" ]; then
        npm run build 2>/dev/null || exit 1
      fi
      exec node dist/index.js usage --json --window \#(window)
      """#,
    ]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    shell.standardOutput = outputPipe
    shell.standardError = errorPipe

    try shell.run()

    let outputData = await Self.collectOutput(outputPipe.fileHandleForReading)
    let errorData = await Self.collectOutput(errorPipe.fileHandleForReading)

    shell.waitUntilExit()

    guard shell.terminationStatus == 0 else {
      let stderr = String(data: errorData, encoding: .utf8) ?? ""
      throw UsageStatsProviderError.cliFailed(shell.terminationStatus, stderr: stderr)
    }

    return String(data: outputData, encoding: .utf8) ?? ""
  }

  /// Drain a file handle to EOF asynchronously.
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

// MARK: - Cost-card view model

struct CostCardViewModel: Equatable {
  let headlineCost: String
  let hasEstimated: Bool
  let unknownNote: String?
  let topModels: [ModelUsageRow]
  let totalModelCount: Int

  /// Headline: sum of all costUSD. Prefix with ~ when any row hasEstimated.
  /// Unknown runs: footnote "N runs unknown cost" when any hasUnknown.
  /// Top 5 by costUSD, remaining count. Rows whose cost is entirely unknown
  /// (hasUnknown with $0) are excluded from the top list — they carry no
  /// dollar information and rendering them as $0 would violate the T5 rule
  /// that unknown never displays as zero; the footnote already counts them.
  init(rows: [ModelUsageRow], window: String) {
    let totalCost = rows.reduce(0) { $0 + $1.costUSD }
    let anyEstimated = rows.contains(where: \.hasEstimated)
    let unknownRuns = rows.filter(\.hasUnknown).reduce(0) { $0 + $1.runs }

    let prefix = anyEstimated ? "~" : ""
    headlineCost = "\(prefix)$\(String(format: "%.2f", totalCost))"
    hasEstimated = anyEstimated
    unknownNote = unknownRuns > 0 ? "\(unknownRuns) run\(unknownRuns == 1 ? "" : "s") unknown cost" : nil

    let knownRows = rows.filter { !($0.hasUnknown && $0.costUSD == 0) }
    let sorted = knownRows.sorted { $0.costUSD > $1.costUSD }
    topModels = Array(sorted.prefix(5))
    totalModelCount = rows.count
  }

  /// USD formatting shared with the CLI's formatCost: two decimals, but four
  /// for sub-cent values so tiny costs don't render as $0.00.
  static func formatUSD(_ usd: Double) -> String {
    if usd < 0 { return "$0.00" }
    if usd > 0 && usd < 0.01 {
      return "$" + String(format: "%.4f", usd)
    }
    return "$" + String(format: "%.2f", usd)
  }
}

#if DEBUG
extension ModelUsageRow {
  static func fixture(
    modelId: String = "gpt-4o",
    provider: String = "assemblyai",
    runs: Int = 1,
    calls: Int = 2,
    tokensIn: Int = 200,
    tokensOut: Int = 100,
    costUSD: Double = 0.03,
    hasEstimated: Bool = false,
    hasUnknown: Bool = false
  ) -> ModelUsageRow {
    ModelUsageRow(
      modelId: modelId,
      provider: provider,
      runs: runs,
      calls: calls,
      tokensIn: tokensIn,
      tokensOut: tokensOut,
      costUSD: costUSD,
      hasUnknown: hasUnknown,
      hasEstimated: hasEstimated
    )
  }
}
#endif
