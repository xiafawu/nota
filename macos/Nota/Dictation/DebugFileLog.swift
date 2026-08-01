import Foundation

/// File-backed debug log for dictation sessions.
///
/// The unified log store has proven unreliable on this machine (entries
/// silently dropped within minutes), so session-critical events — protocol
/// messages, hypothesis routing, finish() paths — also append here. Appends
/// are serialized through an actor so concurrent sessions never interleave
/// lines.
actor DebugFileLog {
  private let url: URL
  private static let dateFormatter = ISO8601DateFormatter()

  init(url: URL) {
    self.url = url
  }

  static func shared(_ name: String = "dictation-debug.log") -> DebugFileLog {
    DebugFileLog(
      url: URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".nota/log/\(name)")
    )
  }

  func write(_ line: String) {
    let ts = Self.dateFormatter.string(from: Date())
    guard let data = (ts + " " + line + "\n").data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      handle.seekToEndOfFile()
      handle.write(data)
    } else {
      try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try? data.write(to: url, options: .atomic)
    }
  }
}
