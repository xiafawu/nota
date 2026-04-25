import Foundation

// MARK: - Codable schema

struct SpeakerProfile: Codable, Hashable {
  var embedding: [Double]
  var enrolledAt: String
  var source: String
}

struct SpeakerStore: Codable {
  var version: Int
  var speakers: [String: SpeakerProfile]

  static let empty = SpeakerStore(version: 1, speakers: [:])
}

// MARK: - On-disk locations

enum SpeakerStoreLocation {
  static var primary: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".nota", isDirectory: true)
      .appendingPathComponent("speakers.json")
  }

  static var legacy: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".meetingsum", isDirectory: true)
      .appendingPathComponent("speakers.json")
  }
}

// MARK: - Errors

enum SpeakerStoreError: LocalizedError {
  case notFound(String)
  case nameCollision(String)
  case sameName
  case mergeFailed(String)

  var errorDescription: String? {
    switch self {
    case .notFound(let name):
      return "Speaker \"\(name)\" not found."
    case .nameCollision(let name):
      return "A speaker named \"\(name)\" already exists."
    case .sameName:
      return "Source and destination must be different speakers."
    case .mergeFailed(let detail):
      return "Merge failed: \(detail)"
    }
  }
}

// MARK: - Atomic load/save

enum SpeakerProfileStore {
  static func load() -> SpeakerStore {
    if let store = readStore(at: SpeakerStoreLocation.primary) {
      return store
    }
    if let legacy = readStore(at: SpeakerStoreLocation.legacy) {
      return legacy
    }
    return .empty
  }

  static func write(_ store: SpeakerStore) throws {
    let target = SpeakerStoreLocation.primary
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: target.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(store)

    let tempDirectory = target.deletingLastPathComponent()
    let tempURL = tempDirectory.appendingPathComponent(
      ".speakers-\(UUID().uuidString).tmp"
    )
    try data.write(to: tempURL, options: .atomic)

    if fileManager.fileExists(atPath: target.path) {
      _ = try fileManager.replaceItemAt(target, withItemAt: tempURL)
    } else {
      try fileManager.moveItem(at: tempURL, to: target)
    }
  }

  private static func readStore(at url: URL) -> SpeakerStore? {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    do {
      let data = try Data(contentsOf: url)
      return try JSONDecoder().decode(SpeakerStore.self, from: data)
    } catch {
      return nil
    }
  }
}

// MARK: - Merge runner (shells out to the TS CLI)

func shellMergeSpeakers(
  src: String,
  dst: String,
  projectDirectory: URL
) -> Result<Void, Error> {
  let process = Process()
  process.currentDirectoryURL = projectDirectory

  let distEntry = projectDirectory
    .appendingPathComponent("dist", isDirectory: true)
    .appendingPathComponent("index.js")
  let srcEntry = projectDirectory
    .appendingPathComponent("src", isDirectory: true)
    .appendingPathComponent("index.ts")

  let arguments: [String]
  if FileManager.default.fileExists(atPath: distEntry.path) {
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    arguments = ["node", distEntry.path, "speakers", "merge", src, dst]
  } else {
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    arguments = ["npx", "tsx", srcEntry.path, "speakers", "merge", src, dst]
  }
  process.arguments = arguments

  let outPipe = Pipe()
  let errPipe = Pipe()
  process.standardOutput = outPipe
  process.standardError = errPipe

  do {
    try process.run()
    process.waitUntilExit()
  } catch {
    return .failure(SpeakerStoreError.mergeFailed(error.localizedDescription))
  }

  let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

  if process.terminationStatus == 0 {
    return .success(())
  }
  let detail = stderr.isEmpty ? stdout : stderr
  let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
  return .failure(SpeakerStoreError.mergeFailed(
    trimmed.isEmpty ? "exit code \(process.terminationStatus)" : trimmed
  ))
}
