import AppKit
import Foundation

/// Custom attribute carrying a transcript line's timestamp (e.g. "0:51") on the
/// rendered speaker+text range. The visible `[MM:SS]` prefix is stripped at
/// render time; the value rides along here so the hover gutter can reveal it
/// without keeping a separate line→timestamp map in sync.
extension NSAttributedString.Key {
  static let notaTimestamp = NSAttributedString.Key("notaTimestamp")
  /// The same instant as a **number** — seconds from the start of the
  /// recording — carried alongside the display string (XIA-429).
  ///
  /// The gutter pips map a marker's `atSeconds` onto a line, and the display
  /// string is a display string: parsing "1:02:03" back out of it at draw time
  /// would be re-deriving a number the renderer already had in hand.
  static let notaTimestampSeconds = NSAttributedString.Key("notaTimestampSeconds")
}

/// Structured header parsed from a summary's leading markdown block. Drives the
/// SwiftUI document header (title + subtitle + tag pills) so the rich-text body
/// can start at the first `## ` section instead of repeating the metadata inline.
struct DocMeta: Equatable {
  let title: String
  /// e.g. "May 20". Empty when the markdown carried no capture date.
  let dateText: String
  /// e.g. "51 min", parsed from the exported `**Duration:**` line — which the
  /// writer rounds **up** to whole minutes.
  ///
  /// Kept apart from the date rather than pre-joined, because the record's fact
  /// strip states the same length to the second off `durationSeconds`. Two
  /// spellings of one fact four points apart in one header — "May 20 · 19 min"
  /// above "18:42 · Meeting · …" — is precisely the drift XIA-429's one-model
  /// rule exists to prevent, so the header drops this half when a strip is
  /// present. When there is no strip (an imported `.md` with no record) this is
  /// the only duration the document has, and it is still shown.
  let durationText: String
  let tags: [String]

  /// The subtitle as it reads with no fact strip under it.
  var subtitle: String {
    subtitle(facts: nil)
  }

  /// **One duration per surface.** The subtitle keeps the capture date always,
  /// and keeps the markdown's `**Duration:**` figure only when the fact strip
  /// beneath it is not about to state the same length itself.
  ///
  /// The two disagree by construction, which is why this is a rule and not a
  /// tidy-up: `durationMinutes` is `max(1, ceil(seconds / 60))`, so an 18 min
  /// 42 s meeting exports `**Duration:** 19 minutes` while `durationSeconds`
  /// (1122) drives the strip's `18:42`. Rendering both put "May 20 · 19 min"
  /// four points above "18:42 · Meeting · 3 speakers", inside a single surface,
  /// on a feature chosen specifically so the moment and the document could not
  /// disagree about how long the recording was.
  ///
  /// It lives on `DocMeta` because it is a statement about the parsed document,
  /// and because this type already owns the two disagreeing spellings. It has
  /// moved surface twice — header, then the info card, now the Details panel —
  /// and the rule has never moved with them, so it belongs to neither.
  ///
  /// Pure, so the rule is asserted without laying anything out.
  func subtitle(facts: RecordFacts?) -> String {
    let stripStatesDuration = facts?.text(for: .duration) != nil
    let parts = stripStatesDuration ? [dateText] : [dateText, durationText]
    return parts.filter { !$0.isEmpty }.joined(separator: " · ")
  }

  init(title: String, dateText: String = "", durationText: String = "", tags: [String] = []) {
    self.title = title
    self.dateText = dateText
    self.durationText = durationText
    self.tags = tags
  }

  /// For previews and tests that only care about the joined line.
  init(title: String, subtitle: String, tags: [String]) {
    self.init(title: title, dateText: subtitle, durationText: "", tags: tags)
  }
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

  // `enumerateLines` rather than `components(separatedBy:)`, and the `stop`
  // flag is the whole reason: splitting first materializes every line of the
  // document as a `String` before this loop breaks at the first `## `, and the
  // Details panel reads this parse two to four times per body evaluation while
  // an `@Published` summary draft is being typed into it. What is documented
  // as costing a header block now costs one.
  markdown.enumerateLines { rawLine, stop in
    let line = rawLine.trimmingCharacters(in: .whitespaces)
    if line.hasPrefix("## ") {
      stop = true // reached the body; the header block lives above it
      return
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

  let display = title == metaGenericTitle ? "Untitled transcript" : title
  return DocMeta(
    title: display,
    dateText: prettyDate(dateRaw) ?? "",
    durationText: prettyDuration(durationRaw) ?? "",
    tags: tags
  )
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
