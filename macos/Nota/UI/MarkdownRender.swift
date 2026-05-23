import AppKit
import Foundation

func rtfData(from attributedText: NSAttributedString) throws -> Data {
  try attributedText.data(
    from: NSRange(location: 0, length: attributedText.length),
    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
  )
}

/// Render markdown to a rich `NSAttributedString`.
///
/// - Parameters:
///   - markdown: Raw markdown body.
///   - overrides: Optional label→name substitution map. When a transcript
///     line's speaker label matches a key, the display name in the rendered
///     string uses the mapped value instead of the original label. The body
///     on disk is **never** mutated — substitution is purely at render time.
func renderMarkdownAsRichText(
  _ markdown: String,
  overrides: [String: String] = [:]
) -> NSAttributedString {
  let output = NSMutableAttributedString()
  let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
  let lines = normalized.components(separatedBy: "\n")
  let hasBodySection = lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("## ") }
  var skippingHeader = hasBodySection
  var isInCodeBlock = false

  for rawLine in lines {
    let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)

    // Skip the leading header block (title + `**Captured:**`/`**Tags:**` etc.) —
    // the SwiftUI DocumentHeaderView renders it. Body begins at the first `## `.
    if skippingHeader {
      if trimmedLine.hasPrefix("## ") {
        skippingHeader = false
      } else {
        continue
      }
    }

    if trimmedLine.hasPrefix("```") {
      isInCodeBlock.toggle()
      continue
    }

    if isInCodeBlock {
      appendPlainLine(rawLine, to: output, font: NSFonts.codeBlock, color: .secondaryLabelColor)
      continue
    }

    if trimmedLine.isEmpty {
      output.append(NSAttributedString(string: "\n"))
      continue
    }

    if trimmedLine == "---" {
      appendPlainLine("------------------------------", to: output, font: NSFonts.separator, color: .separatorColor)
      continue
    }

    if trimmedLine.hasPrefix("## ") {
      let title = String(trimmedLine.dropFirst(3))
      appendPlainLine(title, to: output, font: NSFonts.h2, paragraphSpacing: Metrics.paraSpacingH2)
      continue
    }

    if trimmedLine.hasPrefix("# ") {
      let title = String(trimmedLine.dropFirst(2))
      appendPlainLine(title, to: output, font: NSFonts.h1, paragraphSpacing: Metrics.paraSpacingH1)
      continue
    }

    if trimmedLine.hasPrefix("- ") {
      let item = String(trimmedLine.dropFirst(2))
      appendBulletLine(item, to: output)
      continue
    }

    if appendTranscriptLine(trimmedLine, to: output, overrides: overrides) {
      continue
    }

    appendInlineMarkdownLine(trimmedLine, to: output)
  }

  return output
}

private func appendPlainLine(
  _ line: String,
  to output: NSMutableAttributedString,
  font: NSFont,
  color: NSColor = .labelColor,
  paragraphSpacing: CGFloat = Metrics.paraSpacingTight
) {
  let paragraph = NSMutableParagraphStyle()
  paragraph.paragraphSpacing = paragraphSpacing
  paragraph.lineSpacing = Metrics.lineSpacingDefault
  output.append(NSAttributedString(string: line, attributes: [
    .font: font,
    .foregroundColor: color,
    .paragraphStyle: paragraph
  ]))
  output.append(NSAttributedString(string: "\n"))
}

private func appendBulletLine(_ line: String, to output: NSMutableAttributedString) {
  let paragraph = NSMutableParagraphStyle()
  paragraph.firstLineHeadIndent = 0
  paragraph.headIndent = Metrics.bulletHeadIndent
  paragraph.paragraphSpacing = Metrics.paraSpacingTight
  paragraph.lineSpacing = Metrics.lineSpacingDefault

  output.append(NSAttributedString(string: "• ", attributes: [
    .font: NSFonts.body,
    .foregroundColor: NSColor.labelColor,
    .paragraphStyle: paragraph
  ]))
  appendInlineMarkdown(line, to: output, font: NSFonts.body, paragraphStyle: paragraph)
  output.append(NSAttributedString(string: "\n"))
}

private func appendTranscriptLine(
  _ line: String,
  to output: NSMutableAttributedString,
  overrides: [String: String] = [:]
) -> Bool {
  let paragraph = NSMutableParagraphStyle()
  paragraph.paragraphSpacing = Metrics.paraSpacingTranscript
  paragraph.lineSpacing = Metrics.lineSpacingDefault

  // [MM:SS] **Speaker:** text — render speaker + text, drop the visible timestamp,
  // and carry it as a `.notaTimestamp` attribute for the hover gutter.
  let speakerPattern = #"^\[([0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?)\] \*\*(.+?):\*\* (.*)$"#
  if let groups = matchTranscript(speakerPattern, in: line) {
    let rawLabel = groups[2]
    // Apply render-time substitution: use override name when present, original
    // label otherwise. Body on disk is never mutated.
    let displayLabel = overrides[rawLabel] ?? rawLabel
    let start = output.length
    output.append(NSAttributedString(string: "\(displayLabel): ", attributes: [
      .font: NSFonts.speaker,
      .foregroundColor: NSColor.labelColor,
      .paragraphStyle: paragraph
    ]))
    output.append(NSAttributedString(string: groups[3], attributes: [
      .font: NSFonts.body,
      .foregroundColor: NSColor.labelColor,
      .paragraphStyle: paragraph
    ]))
    attachTimestamp(prettyTimestamp(groups[1]), from: start, to: output)
    output.append(NSAttributedString(string: "\n"))
    return true
  }

  // [MM:SS] text — timestamped line without a speaker label.
  let plainPattern = #"^\[([0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?)\] (.*)$"#
  if let groups = matchTranscript(plainPattern, in: line) {
    let start = output.length
    output.append(NSAttributedString(string: groups[2], attributes: [
      .font: NSFonts.body,
      .foregroundColor: NSColor.labelColor,
      .paragraphStyle: paragraph
    ]))
    attachTimestamp(prettyTimestamp(groups[1]), from: start, to: output)
    output.append(NSAttributedString(string: "\n"))
    return true
  }

  return false
}

/// Match `pattern` against `line`, returning every capture group as a string
/// (index 0 is the full match), or nil when it doesn't match.
private func matchTranscript(_ pattern: String, in line: String) -> [String]? {
  guard
    let regex = try? NSRegularExpression(pattern: pattern),
    let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
  else {
    return nil
  }
  var groups: [String] = []
  for index in 0..<match.numberOfRanges {
    guard let range = Range(match.range(at: index), in: line) else {
      return nil
    }
    groups.append(String(line[range]))
  }
  return groups
}

/// Tag the just-appended speaker+text range with its timestamp so the hover
/// gutter can reveal it. The caller appends the trailing newline, which is left
/// untagged so hovering line breaks reveals nothing.
private func attachTimestamp(_ timestamp: String, from start: Int, to output: NSMutableAttributedString) {
  guard output.length > start else {
    return
  }
  output.addAttribute(.notaTimestamp, value: timestamp, range: NSRange(location: start, length: output.length - start))
}

/// "00:14" → "0:14", "01:02:03" → "1:02:03": drop a single leading zero from the
/// first field so the gutter reads naturally.
private func prettyTimestamp(_ raw: String) -> String {
  var fields = raw.split(separator: ":").map(String.init)
  if let first = fields.first {
    fields[0] = String(Int(first) ?? 0)
  }
  return fields.joined(separator: ":")
}

private func appendInlineMarkdownLine(_ line: String, to output: NSMutableAttributedString) {
  let paragraph = NSMutableParagraphStyle()
  paragraph.paragraphSpacing = Metrics.paraSpacingTight
  paragraph.lineSpacing = Metrics.lineSpacingDefault
  appendInlineMarkdown(line, to: output, font: NSFonts.body, paragraphStyle: paragraph)
  output.append(NSAttributedString(string: "\n"))
}

private func appendInlineMarkdown(
  _ line: String,
  to output: NSMutableAttributedString,
  font: NSFont,
  paragraphStyle: NSParagraphStyle
) {
  let parts = line.components(separatedBy: "**")
  for index in parts.indices {
    let part = parts[index]
    guard !part.isEmpty else {
      continue
    }

    let segmentFont = index.isMultiple(of: 2) ? font : NSFont.boldSystemFont(ofSize: font.pointSize)
    output.append(NSAttributedString(string: part, attributes: [
      .font: segmentFont,
      .foregroundColor: NSColor.labelColor,
      .paragraphStyle: paragraphStyle
    ]))
  }
}
