import Foundation

func sanitizedBaseName(_ url: URL) -> String {
  let raw = url.deletingPathExtension().lastPathComponent

  // Internal input copies (".nota-input-<epoch>-<uuid>", ".nota-share-<epoch>-<uuid>")
  // carry no recoverable original filename. Without this guard the derived output
  // name inherits their leading dot and the .summary.md becomes a hidden file that
  // the sidebar can never show (issue #25).
  if isNotaInternalCopyName(raw) {
    return "recording"
  }

  let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
  let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
  // Trim leading/trailing dots and dashes so the output file is never hidden.
  let value = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
  return value.isEmpty ? "recording" : value
}

/// True for Nota's internal stabilized/shared audio copies, whose names encode only
/// an epoch + UUID and therefore yield no meaningful output title.
private func isNotaInternalCopyName(_ name: String) -> Bool {
  let unprefixed = name.hasPrefix(".") ? String(name.dropFirst()) : name
  return unprefixed.hasPrefix("nota-input-") || unprefixed.hasPrefix("nota-share-")
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
