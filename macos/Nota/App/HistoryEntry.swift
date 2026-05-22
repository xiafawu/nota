import Foundation

struct HistoryEntry: Identifiable, Hashable {
  let url: URL
  let modifiedAt: Date
  let title: String
  let tags: [String]

  var id: URL { url }

  var relativeDate: String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: modifiedAt, relativeTo: Date())
  }
}

extension HistoryEntry {
  /// Build an entry, deriving the title/tags from the file's content when present
  /// (LLM-generated `# Title` heading + `**Tags:**` line), and falling back to the
  /// timestamped filename for legacy outputs that predate the title feature.
  static func make(url: URL, modifiedAt: Date) -> HistoryEntry {
    let meta = parseSummaryMetadata(at: url)
    let title = meta.title ?? fallbackTitle(for: url)
    return HistoryEntry(url: url, modifiedAt: modifiedAt, title: title, tags: meta.tags)
  }
}

/// The placeholder H1 emitted before LLM titles existed; treated as "no title".
private let genericSummaryTitle = "Nota Summary"
private let tagsMarker = "**Tags:**"

/// Reads the leading metadata block of a `.summary.md` and extracts the title
/// (first `# ` heading) and tags (`**Tags:**` line). Scanning stops at the first
/// `## ` body section, so this only ever touches the small header region.
private func parseSummaryMetadata(at url: URL) -> (title: String?, tags: [String]) {
  guard let content = try? String(contentsOf: url, encoding: .utf8) else {
    return (nil, [])
  }

  var title: String?
  var tags: [String] = []

  for rawLine in content.components(separatedBy: "\n") {
    let line = rawLine.trimmingCharacters(in: .whitespaces)

    if line.hasPrefix("## ") {
      break // reached the body; title/tags live in the header block above
    }

    if title == nil, line.hasPrefix("# ") {
      let candidate = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
      if !candidate.isEmpty, candidate != genericSummaryTitle {
        title = candidate
      }
    } else if line.hasPrefix(tagsMarker) {
      tags = String(line.dropFirst(tagsMarker.count))
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    }
  }

  return (title, tags)
}

/// Derives a display title from the timestamped filename, e.g.
/// `team-sync-20260521-101530.summary.md` -> `team-sync`.
private func fallbackTitle(for url: URL) -> String {
  let base = url.deletingPathExtension().lastPathComponent
  let stripped = base.hasSuffix(".summary") ? String(base.dropLast(".summary".count)) : base
  if let dashRange = stripped.range(of: "-", options: .backwards),
     let _ = Int(stripped[dashRange.upperBound...].prefix(8)) {
    let prefix = stripped[..<dashRange.lowerBound]
    if !prefix.isEmpty {
      return String(prefix)
    }
  }
  return stripped
}
