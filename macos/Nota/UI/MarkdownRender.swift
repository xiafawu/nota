import AppKit
import Foundation

func rtfData(from attributedText: NSAttributedString) throws -> Data {
  try attributedText.data(
    from: NSRange(location: 0, length: attributedText.length),
    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
  )
}

func renderMarkdownAsRichText(_ markdown: String) -> NSAttributedString {
  let output = NSMutableAttributedString()
  let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
  let lines = normalized.components(separatedBy: "\n")
  var isInCodeBlock = false

  for rawLine in lines {
    let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)

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

    if appendTranscriptLine(trimmedLine, to: output) {
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

private func appendTranscriptLine(_ line: String, to output: NSMutableAttributedString) -> Bool {
  let pattern = #"^\[([0-9]{2}:[0-9]{2})\] \*\*(.+?):\*\* (.*)$"#
  guard
    let regex = try? NSRegularExpression(pattern: pattern),
    let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
    match.numberOfRanges == 4,
    let timestampRange = Range(match.range(at: 1), in: line),
    let speakerRange = Range(match.range(at: 2), in: line),
    let textRange = Range(match.range(at: 3), in: line)
  else {
    return false
  }

  let paragraph = NSMutableParagraphStyle()
  paragraph.paragraphSpacing = Metrics.paraSpacingTranscript
  paragraph.lineSpacing = Metrics.lineSpacingDefault

  let timestamp = String(line[timestampRange])
  let speaker = String(line[speakerRange])
  let text = String(line[textRange])

  output.append(NSAttributedString(string: "[\(timestamp)] ", attributes: [
    .font: NSFonts.timestamp,
    .foregroundColor: NSColor.secondaryLabelColor,
    .paragraphStyle: paragraph
  ]))
  output.append(NSAttributedString(string: "\(speaker): ", attributes: [
    .font: NSFonts.speaker,
    .foregroundColor: NSColor.labelColor,
    .paragraphStyle: paragraph
  ]))
  output.append(NSAttributedString(string: text, attributes: [
    .font: NSFonts.body,
    .foregroundColor: NSColor.labelColor,
    .paragraphStyle: paragraph
  ]))
  output.append(NSAttributedString(string: "\n"))
  return true
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
