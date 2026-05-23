import Foundation

// MARK: - Schema

/// Sidecar JSON stored alongside `<doc>.summary.md` as
/// `<doc>.summary.speakers.json`.
///
/// Schema:
/// ```json
/// { "version": 1, "speakers": { "Speaker 1": "Alice" } }
/// ```
/// Keys are original labels parsed from the body. Values are display names.
/// An empty string value or missing key means no override.
struct SpeakerSidecarData: Codable {
  var version: Int
  /// label → display name
  var speakers: [String: String]

  static let empty = SpeakerSidecarData(version: 1, speakers: [:])
}

// MARK: - Load / save

enum SpeakerSidecar {
  /// Derives the sidecar URL from the document's .md URL.
  /// `<base>.summary.md` → `<base>.summary.speakers.json`
  static func sidecarURL(for documentURL: URL) -> URL {
    // Strip trailing path extension (.md), then append .speakers.json
    let withoutMd = documentURL.deletingPathExtension()
    return withoutMd.appendingPathExtension("speakers.json")
  }

  /// Load the sidecar for a document. Returns `.empty` when the file is
  /// absent or cannot be decoded — this is not an error condition.
  static func load(for documentURL: URL) -> SpeakerSidecarData {
    let url = sidecarURL(for: documentURL)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return .empty
    }
    do {
      let data = try Data(contentsOf: url)
      return try JSONDecoder().decode(SpeakerSidecarData.self, from: data)
    } catch {
      return .empty
    }
  }

  /// Atomically save the sidecar. Mirrors `SpeakerProfileStore.write`'s
  /// tmp-file + replaceItemAt pattern.
  static func save(_ sidecar: SpeakerSidecarData, for documentURL: URL) throws {
    let target = sidecarURL(for: documentURL)
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: target.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(sidecar)

    let tempURL = target.deletingLastPathComponent().appendingPathComponent(
      ".speakers-\(UUID().uuidString).tmp"
    )
    try data.write(to: tempURL, options: .atomic)

    if fileManager.fileExists(atPath: target.path) {
      _ = try fileManager.replaceItemAt(target, withItemAt: tempURL)
    } else {
      try fileManager.moveItem(at: tempURL, to: target)
    }
  }
}
