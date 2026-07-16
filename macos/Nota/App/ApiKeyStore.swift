import Foundation

// Reads/writes API keys the way the CLI does: real environment variables win,
// otherwise ~/.nota/config (a dotenv-style KEY=VALUE file). Setting a key writes
// it into ~/.nota/config, created with 0600 permissions. Full secrets are never
// surfaced — only a masked status like `sk…abcd`.

enum ApiKeySource {
  case env
  case file
  case absent
}

struct ApiKeyStatus {
  let env: String
  let source: ApiKeySource
  /// Masked value (e.g. `sk…abcd`) or nil when absent.
  let masked: String?
}

enum ApiKeyStore {
  static var configURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".nota", isDirectory: true)
      .appendingPathComponent("config")
  }

  /// Env var names surfaced in the Settings UI.
  static let keys = [
    "OPENAI_API_KEY",
    "ASSEMBLYAI_API_KEY",
    "GEMINI_API_KEY",
    "DEEPSEEK_API_KEY",
  ]

  static func status(for env: String) -> ApiKeyStatus {
    if let value = ProcessInfo.processInfo.environment[env], !value.isEmpty {
      return ApiKeyStatus(env: env, source: .env, masked: mask(value))
    }
    if let value = fileMap()[env], !value.isEmpty {
      return ApiKeyStatus(env: env, source: .file, masked: mask(value))
    }
    return ApiKeyStatus(env: env, source: .absent, masked: nil)
  }

  /// Resolve the actual key value (env first, then ~/.nota/config), or nil.
  /// The single read path for secrets — callers must not parse the config
  /// file themselves.
  static func value(for env: String) -> String? {
    if let value = ProcessInfo.processInfo.environment[env], !value.isEmpty {
      return value
    }
    if let value = fileMap()[env], !value.isEmpty {
      return value
    }
    return nil
  }

  /// Write (or overwrite) a key in ~/.nota/config, preserving other lines.
  /// Passing an empty/whitespace value removes the key.
  static func setKey(_ env: String, value rawValue: String) throws {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    var map = fileMap()
    if value.isEmpty {
      map.removeValue(forKey: env)
    } else {
      map[env] = value
    }
    try writeFileMap(map)
  }

  // MARK: - Masking

  static func mask(_ value: String) -> String {
    if value.count <= 6 { return "••••" }
    let start = value.prefix(2)
    let end = value.suffix(4)
    return "\(start)…\(end)"
  }

  // MARK: - dotenv parse/serialize

  private static func fileMap() -> [String: String] {
    guard let content = try? String(contentsOf: configURL, encoding: .utf8) else {
      return [:]
    }
    var map: [String: String] = [:]
    for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      let unexported = line.hasPrefix("export ")
        ? String(line.dropFirst("export ".count))
        : line
      guard let eq = unexported.firstIndex(of: "=") else { continue }
      let key = String(unexported[..<eq]).trimmingCharacters(in: .whitespaces)
      if key.isEmpty { continue }
      var raw = String(unexported[unexported.index(after: eq)...])
        .trimmingCharacters(in: .whitespaces)
      if raw.count >= 2, let first = raw.first, let last = raw.last,
         (first == "\"" || first == "'"), first == last {
        raw = String(raw.dropFirst().dropLast())
      }
      map[key] = raw
    }
    return map
  }

  private static func writeFileMap(_ map: [String: String]) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: configURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let body = map.keys.sorted()
      .map { "\($0)=\(map[$0] ?? "")" }
      .joined(separator: "\n")
    let content = body.isEmpty ? "" : body + "\n"
    let data = Data(content.utf8)

    // Atomic write, then lock down to 0600 (owner read/write only).
    let tempURL = configURL.deletingLastPathComponent()
      .appendingPathComponent(".config-\(UUID().uuidString).tmp")
    try data.write(to: tempURL, options: .atomic)
    if fileManager.fileExists(atPath: configURL.path) {
      _ = try fileManager.replaceItemAt(configURL, withItemAt: tempURL)
    } else {
      try fileManager.moveItem(at: tempURL, to: configURL)
    }
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: configURL.path
    )
  }
}
