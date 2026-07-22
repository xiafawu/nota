import Foundation
import SwiftUI

// Observable wrapper around the model catalog cache, plus the one place the app
// asks for a fresh catalog: it shells the bundled CLI (`nota models refresh`) —
// mirroring shellMergeSpeakers — instead of fetching models.dev itself. The
// Models settings tab observes this and reloads when a refresh finishes.

@MainActor
final class ModelCatalogModel: ObservableObject {
  /// Effective catalog (cache when present, baked snapshot otherwise).
  @Published private(set) var catalog: ModelCatalog
  @Published private(set) var source: ModelCatalogSource
  @Published private(set) var isRefreshing = false
  /// Result of a user-initiated "Check for New Models" refresh (nil = none yet).
  @Published var refreshMessage: String?

  private let cacheURL: URL
  private let projectDirectory: URL

  /// 7 days — the same staleness window the CLI uses.
  private static let staleAfter: TimeInterval = 7 * 24 * 60 * 60

  init(
    cacheURL: URL = ModelCatalogLoader.defaultCacheURL,
    projectDirectory: URL = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["NOTA_PROJECT_DIR"]
        ?? "/Users/xiafawu/Developer/Nota"
    )
  ) {
    self.cacheURL = cacheURL
    self.projectDirectory = projectDirectory
    let effective = ModelCatalogLoader.effective(cacheURL: cacheURL)
    self.catalog = effective.catalog
    self.source = effective.source
  }

  // MARK: Derived state

  var summaryEntries: [ModelEntry] { catalog.summaryModelEntries() }

  /// `fetchedAt` parsed as a Date, or nil when unparseable.
  var fetchedDate: Date? { Self.parseISODate(catalog.fetchedAt) }

  func contains(_ modelID: String) -> Bool { catalog.contains(modelID) }

  /// Footer text: the cache date, or "built-in defaults" on the baked fallback.
  var footerText: String {
    if source == .baked { return "Model catalog: built-in defaults" }
    if let date = fetchedDate {
      return "Model catalog as of \(Self.mediumDateFormatter.string(from: date))"
    }
    return "Model catalog as of \(catalog.fetchedAt)"
  }

  // MARK: Reload / refresh

  /// Re-read the cache from disk (after a refresh writes a new one).
  func reload() {
    let effective = ModelCatalogLoader.effective(cacheURL: cacheURL)
    catalog = effective.catalog
    source = effective.source
  }

  /// On tab appear: refresh in the background when there is no cache or it is
  /// older than 7 days. Never blocks the UI; failures are silent (the footer
  /// simply keeps the old date).
  func refreshIfStale() {
    if source == .baked {
      refresh(userInitiated: false)
      return
    }
    // An unparseable fetchedAt counts as stale — otherwise a cache with a
    // corrupted timestamp would never refresh again.
    guard let date = fetchedDate else {
      refresh(userInitiated: false)
      return
    }
    if Date().timeIntervalSince(date) > Self.staleAfter {
      refresh(userInitiated: false)
    }
  }

  /// Shell `nota models refresh` off the main actor, then reload. When
  /// `userInitiated`, publish an added/removed summary (or "up to date").
  func refresh(userInitiated: Bool) {
    guard !isRefreshing else { return }
    isRefreshing = true
    if userInitiated { refreshMessage = nil }

    let previousIDs = Set(catalog.models.map(\.id))
    let projectDir = projectDirectory

    Task.detached(priority: .userInitiated) {
      let result = shellRefreshCatalog(projectDirectory: projectDir)
      await MainActor.run {
        self.isRefreshing = false
        self.reload()
        guard userInitiated else { return }
        switch result {
        case .failure:
          // Non-blocking feedback; the footer keeps whatever date it had.
          self.refreshMessage = "Couldn't check for new models"
        case .success:
          let currentIDs = Set(self.catalog.models.map(\.id))
          let added = currentIDs.subtracting(previousIDs).count
          let removed = previousIDs.subtracting(currentIDs).count
          if added == 0 && removed == 0 {
            self.refreshMessage = "Catalog is up to date"
          } else {
            var parts: [String] = []
            if added > 0 { parts.append("\(added) added") }
            if removed > 0 { parts.append("\(removed) removed") }
            self.refreshMessage = parts.joined(separator: ", ")
          }
        }
      }
    }
  }

  // MARK: Formatters

  private static let mediumDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .none
    return f
  }()

  private static func parseISODate(_ raw: String) -> Date? {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: raw) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: raw)
  }
}

// MARK: - CLI refresh runner (shells out to the TS CLI)

enum CatalogRefreshError: LocalizedError {
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .failed(let detail): return "Catalog refresh failed: \(detail)"
    }
  }
}

/// Run `nota models refresh` against the bundled CLI. Prefers the compiled
/// dist/index.js, falling back to `npx tsx src/index.ts`. Mirrors
/// shellMergeSpeakers in SpeakerProfileStore.swift.
///
/// The child is killed after `timeout` seconds — `npx` can otherwise block
/// indefinitely resolving tsx with no network, which would pin the store's
/// isRefreshing flag (and the refresh button's spinner) for the app's
/// lifetime.
func shellRefreshCatalog(
  projectDirectory: URL,
  timeout: TimeInterval = 120
) -> Result<Void, Error> {
  let process = Process()
  process.currentDirectoryURL = projectDirectory

  let distEntry = projectDirectory
    .appendingPathComponent("dist", isDirectory: true)
    .appendingPathComponent("index.js")
  let srcEntry = projectDirectory
    .appendingPathComponent("src", isDirectory: true)
    .appendingPathComponent("index.ts")

  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  if FileManager.default.fileExists(atPath: distEntry.path) {
    process.arguments = ["node", distEntry.path, "models", "refresh"]
  } else if FileManager.default.fileExists(atPath: srcEntry.path) {
    process.arguments = ["npx", "tsx", srcEntry.path, "models", "refresh"]
  } else {
    // Neither entry point exists (moved repo, shipped .app without the CLI):
    // fail fast instead of letting npx grope at a missing file.
    return .failure(CatalogRefreshError.failed(
      "Nota CLI not found under \(projectDirectory.path)"
    ))
  }

  // One merged pipe: a single blocking read reaches EOF when the child exits
  // (or is killed), so neither stream can fill its buffer and deadlock us.
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = pipe

  do {
    try process.run()
  } catch {
    return .failure(CatalogRefreshError.failed(error.localizedDescription))
  }

  // Watchdog: SIGTERM the child at the deadline. Checking isRunning makes the
  // fired-after-exit case a no-op; cancel() below makes the normal case free.
  let watchdog = DispatchWorkItem { [weak process] in
    if let process, process.isRunning { process.terminate() }
  }
  DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

  let output = String(
    data: pipe.fileHandleForReading.readDataToEndOfFile(),
    encoding: .utf8
  ) ?? ""
  process.waitUntilExit()
  watchdog.cancel()

  if process.terminationStatus == 0 {
    return .success(())
  }
  if process.terminationReason == .uncaughtSignal {
    return .failure(CatalogRefreshError.failed(
      "timed out after \(Int(timeout))s"
    ))
  }
  let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
  return .failure(CatalogRefreshError.failed(
    detail.isEmpty ? "exit code \(process.terminationStatus)" : detail
  ))
}
