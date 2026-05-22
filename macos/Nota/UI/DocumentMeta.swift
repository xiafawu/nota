import AppKit
import Foundation

/// Custom attribute carrying a transcript line's timestamp (e.g. "0:51") on the
/// rendered speaker+text range. The visible `[MM:SS]` prefix is stripped at
/// render time; the value rides along here so the hover gutter can reveal it
/// without keeping a separate line→timestamp map in sync.
extension NSAttributedString.Key {
  static let notaTimestamp = NSAttributedString.Key("notaTimestamp")
}

/// Structured header parsed from a summary's leading markdown block. Drives the
/// SwiftUI document header (title + subtitle + tag pills) so the rich-text body
/// can start at the first `## ` section instead of repeating the metadata inline.
struct DocMeta: Equatable {
  let title: String
  /// e.g. "May 20 · 51 min". Empty when there's no date/duration to show.
  let subtitle: String
  let tags: [String]
}

/// The placeholder H1 emitted before LLM titles existed.
private let metaGenericTitle = "Nota Summary"

/// Parse the leading header — everything before the first `## ` — into a `DocMeta`:
/// the `# Title`, a `**Captured:**` (or legacy `**Date:**`) line, `**Duration:**`,
/// and `**Tags:**`. `**Source:**` and `**Transcribed:**` are intentionally ignored:
/// the minimal subtitle shows only capture date + duration.
func parseDocumentMeta(_ markdown: String) -> DocMeta? {
  var title: String?
  var dateRaw: String?
  var durationRaw: String?
  var tags: [String] = []

  for rawLine in markdown.components(separatedBy: "\n") {
    let line = rawLine.trimmingCharacters(in: .whitespaces)
    if line.hasPrefix("## ") {
      break // reached the body; the header block lives above it
    }

    if title == nil, line.hasPrefix("# ") {
      let candidate = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
      if !candidate.isEmpty {
        title = candidate
      }
    } else if let value = headerValue("**Captured:**", in: line) ?? headerValue("**Date:**", in: line) {
      dateRaw = value
    } else if let value = headerValue("**Duration:**", in: line) {
      durationRaw = value
    } else if let value = headerValue("**Tags:**", in: line) {
      tags = value
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    }
  }

  guard let title, !title.isEmpty else {
    return nil
  }

  let subtitle = [prettyDate(dateRaw), prettyDuration(durationRaw)]
    .compactMap { $0 }
    .joined(separator: " · ")
  let display = title == metaGenericTitle ? "Untitled transcript" : title
  return DocMeta(title: display, subtitle: subtitle, tags: tags)
}

/// Returns the value after a `**Label:**` prefix, or nil when the line isn't that
/// label (or the value is empty / the "—" placeholder).
private func headerValue(_ label: String, in line: String) -> String? {
  guard line.hasPrefix(label) else {
    return nil
  }
  let value = String(line.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
  return (value.isEmpty || value == "—") ? nil : value
}

/// "2026-05-20" → localized "May 20". Falls back to the raw string when it isn't
/// an ISO date (legacy files sometimes carried free-form `**Date:**` values).
private func prettyDate(_ raw: String?) -> String? {
  guard let raw, !raw.isEmpty else {
    return nil
  }
  let iso = DateFormatter()
  iso.locale = Locale(identifier: "en_US_POSIX")
  iso.dateFormat = "yyyy-MM-dd"
  guard let date = iso.date(from: String(raw.prefix(10))) else {
    return raw
  }
  let formatter = DateFormatter()
  formatter.locale = .current
  formatter.setLocalizedDateFormatFromTemplate("MMMd")
  return formatter.string(from: date)
}

/// "51 minutes" → "51 min".
private func prettyDuration(_ raw: String?) -> String? {
  guard let raw, !raw.isEmpty else {
    return nil
  }
  let digits = raw.prefix { $0.isNumber }
  return digits.isEmpty ? raw : "\(digits) min"
}
