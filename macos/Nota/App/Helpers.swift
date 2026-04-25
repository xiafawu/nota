import Foundation

func sanitizedBaseName(_ url: URL) -> String {
  let raw = url.deletingPathExtension().lastPathComponent
  let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
  let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
  let value = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  return value.isEmpty ? "recording" : value
}

func notaTimestamp() -> String {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.dateFormat = "yyyyMMdd-HHmmss"
  return formatter.string(from: Date())
}

func notaOutputDirectory() -> URL {
  if let override = ProcessInfo.processInfo.environment["NOTA_OUTPUT_DIR"], !override.isEmpty {
    return URL(fileURLWithPath: override, isDirectory: true)
  }

  return FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Documents", isDirectory: true)
    .appendingPathComponent("Nota", isDirectory: true)
}

func shellQuoted(_ value: String) -> String {
  "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

func failureMarkdown(_ title: String, details: String) -> String {
  let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
  return """
  # \(title)

  ```text
  \(trimmed.isEmpty ? "No error detail was reported." : trimmed)
  ```
  """
}
