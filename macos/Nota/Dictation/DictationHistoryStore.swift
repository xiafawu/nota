import Combine
import Foundation

/// The outcome Nota can know about after a delivery attempt. Paste delivery is
/// intentionally reported as `attempted`: posting Cmd-V does not let Nota
/// verify that the target accepted the paste, while AX and CGEvent give us a
/// positive API-level success signal.
enum DictationDeliveryStatus: String, Codable, CaseIterable, Equatable {
  case pending
  case delivered
  case attempted
  case failed
  case discarded

  var label: String {
    switch self {
    case .pending: return "Awaiting insertion"
    case .delivered: return "Inserted"
    case .attempted: return "Insertion attempted"
    case .failed: return "Insertion failed"
    case .discarded: return "Not inserted"
    }
  }
}

/// One completed dictation. Only recognized text and delivery metadata are
/// stored; raw microphone audio never enters this model or its file.
struct DictationHistoryEntry: Codable, Equatable, Identifiable {
  let id: UUID
  var text: String
  let completedAt: Date
  var status: DictationDeliveryStatus
  var statusDetail: String?
  var targetBundleID: String?
  /// The pid is useful for retrying into the same app during this login. It is
  /// validated against the running app before it is ever used again.
  var targetProcessID: Int32?
  var updatedAt: Date

  var targetLabel: String {
    guard let targetBundleID, !targetBundleID.isEmpty else {
      return "No target captured"
    }
    return targetBundleID
  }
}

enum DictationHistoryLocation {
  static var fileURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".nota", isDirectory: true)
      .appendingPathComponent("dictation-history.json")
  }
}

/// Small, owner-readable local store for the dictation recovery surface.
/// Writes are atomic and the file is kept at 0600 because dictation text may
/// contain sensitive material.
final class DictationHistoryStore: ObservableObject {
  static let defaultRetentionLimit = 100

  @Published private(set) var entries: [DictationHistoryEntry] = []

  let fileURL: URL
  let retentionLimit: Int

  init(
    fileURL: URL = DictationHistoryLocation.fileURL,
    retentionLimit: Int = DictationHistoryStore.defaultRetentionLimit
  ) {
    self.fileURL = fileURL
    self.retentionLimit = max(1, retentionLimit)
    load()
  }

  @discardableResult
  func record(
    text rawText: String,
    completedAt: Date = Date(),
    status: DictationDeliveryStatus = .pending,
    statusDetail: String? = nil,
    targetBundleID: String? = nil,
    targetProcessID: Int32? = nil
  ) -> UUID? {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }

    let id = UUID()
    entries.insert(
      DictationHistoryEntry(
        id: id,
        text: text,
        completedAt: completedAt,
        status: status,
        statusDetail: statusDetail,
        targetBundleID: targetBundleID,
        targetProcessID: targetProcessID,
        updatedAt: Date()
      ),
      at: 0
    )
    entries.sort { lhs, rhs in
      if lhs.completedAt != rhs.completedAt {
        return lhs.completedAt > rhs.completedAt
      }
      return lhs.id.uuidString > rhs.id.uuidString
    }
    trimAndPersist()
    return id
  }

  func update(
    id: UUID,
    text: String? = nil,
    status: DictationDeliveryStatus? = nil,
    statusDetail: String? = nil,
    targetBundleID: String? = nil,
    targetProcessID: Int32? = nil
  ) {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
    if let text {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { entries[index].text = trimmed }
    }
    if let status { entries[index].status = status }
    if let targetBundleID { entries[index].targetBundleID = targetBundleID }
    if let targetProcessID { entries[index].targetProcessID = targetProcessID }
    entries[index].statusDetail = statusDetail
    entries[index].updatedAt = Date()
    persist()
  }

  func entry(id: UUID) -> DictationHistoryEntry? {
    entries.first(where: { $0.id == id })
  }

  func delete(id: UUID) {
    entries.removeAll { $0.id == id }
    persist()
  }

  func clear() {
    entries.removeAll()
    persist()
  }

  // MARK: - Persistence

  private func load() {
    guard let data = try? Data(contentsOf: fileURL),
          let decoded = try? JSONDecoder().decode([DictationHistoryEntry].self, from: data)
    else {
      entries = []
      return
    }

    let sorted = decoded
      .sorted { lhs, rhs in
        if lhs.completedAt != rhs.completedAt {
          return lhs.completedAt > rhs.completedAt
        }
        return lhs.id.uuidString > rhs.id.uuidString
      }
    entries = Array(sorted.prefix(retentionLimit))
    if entries.count != decoded.count {
      persist()
    }
  }

  private func trimAndPersist() {
    if entries.count > retentionLimit {
      entries = Array(entries.prefix(retentionLimit))
    }
    persist()
  }

  private func persist() {
    let fileManager = FileManager.default
    var temporaryURL: URL?
    do {
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )

      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(entries)
      let tempURL = fileURL.deletingLastPathComponent()
        .appendingPathComponent(".dictation-history-\(UUID().uuidString).tmp")
      temporaryURL = tempURL
      try data.write(to: tempURL, options: .atomic)

      if fileManager.fileExists(atPath: fileURL.path) {
        _ = try fileManager.replaceItemAt(fileURL, withItemAt: tempURL)
      } else {
        try fileManager.moveItem(at: tempURL, to: fileURL)
      }
      try fileManager.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: fileURL.path
      )
    } catch {
      if let temporaryURL {
        try? fileManager.removeItem(at: temporaryURL)
      }
      // A delivery failure must never erase the in-memory recovery path. The
      // next mutation retries persistence, while the app remains usable.
    }
  }
}
