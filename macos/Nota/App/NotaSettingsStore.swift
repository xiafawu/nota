import Foundation

// Reads and writes ~/.nota/settings.json — the same non-secret schema the CLI
// uses (see src/utils/settings.ts):
//   { "transcription": { "model": "..." }, "summary": { "model": "..." } }
//
// Unknown top-level JSON keys are preserved across writes (the file is parsed
// as a generic object, only the touched task section is rewritten).

enum NotaSettingsStore {
  static var fileURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".nota", isDirectory: true)
      .appendingPathComponent("settings.json")
  }

  /// Effective model id for a task: the value in settings.json when it is a
  /// valid model for that task, else the built-in default.
  static func effectiveModel(for task: ModelTask) -> String {
    if let stored = storedModel(for: task),
       let entry = ModelRegistry.model(id: stored),
       entry.task == task {
      return stored
    }
    return ModelRegistry.defaultModel(for: task)
  }

  /// True when settings.json explicitly pins this task's model.
  static func isConfigured(_ task: ModelTask) -> Bool {
    guard let stored = storedModel(for: task),
          let entry = ModelRegistry.model(id: stored) else { return false }
    return entry.task == task
  }

  /// Persist a model id for a task, preserving other keys. A missing file is
  /// created; the directory is created if needed.
  static func setModel(_ modelID: String, for task: ModelTask) throws {
    var root = readRoot()
    var section = (root[task.rawValue] as? [String: Any]) ?? [:]
    section["model"] = modelID
    root[task.rawValue] = section
    try writeRoot(root)
  }

  // MARK: - Private

  private static func storedModel(for task: ModelTask) -> String? {
    let root = readRoot()
    let section = root[task.rawValue] as? [String: Any]
    return section?["model"] as? String
  }

  private static func readRoot() -> [String: Any] {
    guard let data = try? Data(contentsOf: fileURL),
          let object = try? JSONSerialization.jsonObject(with: data),
          let dict = object as? [String: Any] else {
      return [:]
    }
    return dict
  }

  private static func writeRoot(_ root: [String: Any]) throws {
    let target = fileURL
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: target.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let data = try JSONSerialization.data(
      withJSONObject: root,
      options: [.prettyPrinted, .sortedKeys]
    )
    let tempURL = target.deletingLastPathComponent()
      .appendingPathComponent(".settings-\(UUID().uuidString).tmp")
    try data.write(to: tempURL, options: .atomic)
    if fileManager.fileExists(atPath: target.path) {
      _ = try fileManager.replaceItemAt(target, withItemAt: tempURL)
    } else {
      try fileManager.moveItem(at: tempURL, to: target)
    }
  }
}
