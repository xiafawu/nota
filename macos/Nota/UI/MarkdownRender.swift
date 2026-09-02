import AppKit
import Foundation

func rtfData(from attributedText: NSAttributedString) throws -> Data {
  try attributedText.data(
    from: NSRange(location: 0, length: attributedText.length),
    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
  )
}

extension NSAttributedString.Key {
  /// The speaker's **full** display name, carried on the run that draws it —
  /// which may be drawing `Brian D.` or `B.D.` instead (see `SpeakerColumn`).
  ///
  /// The name column is measured and capped, so what is on screen is not always
  /// the whole name. Anything that needs the whole one — the identity-hue pass
  /// in `MainPaneView.applySpeakerColors`, and the hover path that already
  /// reveals a line's timestamp in the gutter beside it — reads it here rather
  /// than parsing it back out of the drawn glyphs, for the reason
  /// `.notaTimestampSeconds` exists beside `.notaTimestamp`: re-deriving a
  /// value the renderer already had in hand is how two answers to one question
  /// get into a file.
  static let notaSpeakerName = NSAttributedString.Key("notaSpeakerName")
}

// MARK: - The speaker column (ADR 0008)

/// **Names right, words left, on two edges that never move** (ADR 0008; owner,
/// 2026-09-02: *"verbatim and names should separate out. words should left
/// align, names right align"*).
///
/// The renderer used to append `"\(name): "` inline, in the speaker's identity
/// hue, immediately before the words — so the text's left edge moved with the
/// length of the name ("Brian Demsky:" against "Freya Wu:") and a wrapped
/// paragraph ran back underneath the name. A transcript is read down its left
/// edge; that edge has to be one edge.
///
/// In TextKit the line becomes `tab + name + tab + text` with a **right**-aligned
/// tab stop at the name column's trailing edge, a **left** tab stop at the text
/// edge, and a `headIndent` that matches it — which is what puts every wrapped
/// line on the text edge rather than under the name.
///
/// The column sits **inside the text container**. The outer `Metrics.gutterWidth`
/// gutter is untouched and still belongs to the hover timestamps and the moment
/// pips (XIA-429).
///
/// Pure arithmetic, for the reason `SessionTimerMetrics` and `HUDPillMetrics`
/// are: the two edges are asserted without a window server.
enum SpeakerColumn {
  /// The face the names are drawn in. The speaker name is a **label**, not
  /// reading — the row's structure rather than part of the sentence.
  static var font: NSFont { NSFonts.readingSpeaker }

  /// The gap between the name column's trailing edge and the text edge: one em
  /// of the label's own face, so the two move together if that face ever
  /// changes. A word space (≈5pt at the body size) would not read as a column
  /// boundary at all.
  static var gap: CGFloat { font.pointSize }

  /// How much of the reading measure the **text** column must keep.
  ///
  /// `Metrics.readingMeasure` is 34em of the reading face ≈ 74 characters,
  /// chosen to sit inside the 45–75 band, and every point the name column takes
  /// comes out of it. 26em is ≈ 57 characters — comfortably inside the band —
  /// and this is the number that decides the cap below rather than the cap
  /// deciding it.
  ///
  /// It is deliberately not tighter. Measured 2026-09-02 at the label face,
  /// "Brian Demsky" is 92.9pt and "Bartholomew" 89.4pt, so a cap much under
  /// 100pt would abbreviate ordinary two-word names — and the ladder is meant
  /// to be the exception a very long name reaches, not the normal rendering.
  static let minimumTextEms: CGFloat = 26

  /// The widest the name column may get, **derived from the measure it eats
  /// into** rather than typed (the `RecordingPaneMetrics.capsuleHeight`
  /// precedent). A name wider than this is abbreviated, never truncated.
  static var maximumWidth: CGFloat {
    max(0, Metrics.readingMeasure - minimumTextEms * NSFonts.readingBody.pointSize - gap)
  }

  /// The drawn width of a name at the label face.
  static func width(of name: String) -> CGFloat {
    (name as NSString).size(withAttributes: [.font: font]).width
  }

  /// What this name actually looks like in the column — the full name whenever
  /// it fits, and a rung of the ladder when it does not.
  static func drawnName(_ name: String) -> String {
    fitted(name, within: maximumWidth)
  }

  /// **The column is measured, not typed**: one pass over the document's own
  /// speaker names, sized to the longest thing it has to hold and clamped.
  ///
  /// Measured over the names **as drawn**, so a document whose one long name
  /// abbreviates to `B.D.` gets a narrow column rather than a wide one holding
  /// four characters.
  static func width(forNames names: [String]) -> CGFloat {
    let widest = names.map { width(of: drawnName($0)) }.max() ?? 0
    return min(widest, maximumWidth)
  }

  /// Where the words start. A document with no speaker lines has no column at
  /// all, and then there is no indent either — a foreign `.md` is not a
  /// transcript and may not be laid out as one.
  static func textEdge(nameWidth: CGFloat) -> CGFloat {
    nameWidth <= 0 ? 0 : nameWidth + gap
  }

  /// **Abbreviated, never truncated** (ADR 0008): full name → `Brian D.` →
  /// `B.D.` → an ellipsis, and the last rung only when a single word is absurd.
  /// A name is a person; cutting one mid-syllable is worse than shortening it
  /// the way a person would.
  ///
  /// The full name is never lost — it rides on `.notaSpeakerName`.
  static func fitted(_ name: String, within limit: CGFloat) -> String {
    let full = name.trimmingCharacters(in: .whitespaces)
    guard limit > 0, width(of: full) > limit else { return full }

    let words = full.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    if words.count >= 2, let first = words.first, let last = words.last,
      let lastInitial = last.first {
      let shortened = "\(first) \(lastInitial)."
      if width(of: shortened) <= limit { return shortened }
      if let firstInitial = first.first {
        let initials = "\(firstInitial).\(lastInitial)."
        if width(of: initials) <= limit { return initials }
      }
    }
    return elided(full, within: limit)
  }

  /// The bottom rung: one word too long to shorten any other way.
  private static func elided(_ name: String, within limit: CGFloat) -> String {
    let ellipsis = "\u{2026}"
    var candidate = name
    while !candidate.isEmpty {
      candidate.removeLast()
      let trial = candidate + ellipsis
      if width(of: trial) <= limit { return trial }
    }
    return ellipsis
  }

  /// The two tab stops and the head indent that make the columns.
  static func paragraphStyle(nameWidth: CGFloat) -> NSMutableParagraphStyle {
    let edge = textEdge(nameWidth: nameWidth)
    let paragraph = NSMutableParagraphStyle()
    paragraph.paragraphSpacing = Metrics.paraSpacingTranscript
    paragraph.lineSpacing = Metrics.lineSpacingReading
    // Every wrapped line lands on the text edge, never under a name.
    paragraph.headIndent = edge
    guard edge > 0 else { return paragraph }
    paragraph.tabStops = [
      NSTextTab(textAlignment: .right, location: nameWidth),
      NSTextTab(textAlignment: .left, location: edge),
    ]
    // Only two tabs are ever emitted; this keeps a stray one inside the spoken
    // text from walking off to AppKit's 28pt default grid.
    paragraph.defaultTabInterval = edge
    return paragraph
  }

  /// A transcript line with **no** speaker keeps its words on the same edge as
  /// every other line's: `firstLineHeadIndent` rather than a pair of tabs,
  /// because there is no name to align and an empty name column would put a tab
  /// character into the text for nothing.
  static func continuationStyle(nameWidth: CGFloat) -> NSMutableParagraphStyle {
    let paragraph = paragraphStyle(nameWidth: nameWidth)
    paragraph.firstLineHeadIndent = textEdge(nameWidth: nameWidth)
    return paragraph
  }
}

// MARK: - What the pane draws

/// How much of a document a render is for.
///
/// **The pane draws the title and the transcript, and nothing else** (ADR 0006,
/// addendum 2026-09-02). The body used to begin at the first `## `, which on a
/// summarized meeting is `## Summary` — so the narrative, key topics, decisions
/// and action items were drawn here *and* again in `SummaryRailView`, which
/// reads all four off the record. The same text, twice, on every meeting that
/// had been summarized.
///
/// `.whole` is not a leftover: copy and RTF export answer a different question
/// ("what is this document?") and still want every section.
enum RenderedSections {
  /// The transcript alone — what the reading surface draws.
  case transcript
  /// Every section, for copy and export.
  case whole
}

/// Render markdown to a rich `NSAttributedString`.
///
/// - Parameters:
///   - markdown: Raw markdown body.
///   - overrides: Optional label→name substitution map. When a transcript
///     line's speaker label matches a key, the display name in the rendered
///     string uses the mapped value instead of the original label. The body
///     on disk is **never** mutated — substitution is purely at render time.
///   - sections: Which sections reach the output. See `RenderedSections`.
func renderMarkdownAsRichText(
  _ markdown: String,
  overrides: [String: String] = [:],
  sections: RenderedSections = .transcript
) -> NSAttributedString {
  let output = NSMutableAttributedString()
  let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
  let lines = normalized.components(separatedBy: "\n")
  let plan = DocumentBody.plan(lines: lines, sections: sections)

  // One pass over the lines that will really be drawn, so the name column is
  // sized to the longest name in *this* document (ADR 0008).
  let nameWidth = SpeakerColumn.width(
    forNames: DocumentBody.speakerNames(in: lines[plan.range], overrides: overrides))

  var isInCodeBlock = false

  for index in plan.range {
    // The document's own `# Title` is drawn once, by the pane, as the first
    // line of the scrolling body — never a second time here.
    if index == plan.titleLine { continue }

    let rawLine = lines[index]
    let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)

    if trimmedLine.hasPrefix("```") {
      isInCodeBlock.toggle()
      continue
    }

    if isInCodeBlock {
      appendPlainLine(rawLine, to: output, font: NSFonts.codeBlock, color: GroundInk.nsColor(.timestamp))
      continue
    }

    if trimmedLine.isEmpty {
      output.append(NSAttributedString(string: "\n"))
      continue
    }

    if trimmedLine == "---" {
      appendPlainLine(
        "------------------------------", to: output, font: NSFonts.separator,
        color: GroundInk.nsColor(.rail))
      continue
    }

    if trimmedLine.hasPrefix("## ") {
      let title = String(trimmedLine.dropFirst(3))
      appendPlainLine(
        title, to: output, font: NSFonts.readingH2,
        paragraphSpacing: Metrics.paraSpacingH2,
        paragraphSpacingBefore: Metrics.paraSpacingBeforeH2)
      continue
    }

    if trimmedLine.hasPrefix("# ") {
      let title = String(trimmedLine.dropFirst(2))
      appendPlainLine(
        title, to: output, font: NSFonts.readingH1,
        paragraphSpacing: Metrics.paraSpacingH1,
        paragraphSpacingBefore: Metrics.paraSpacingBeforeH1)
      continue
    }

    if trimmedLine.hasPrefix("- ") {
      let item = String(trimmedLine.dropFirst(2))
      appendBulletLine(item, to: output)
      continue
    }

    if appendTranscriptLine(
      trimmedLine, to: output, overrides: overrides, nameWidth: nameWidth) {
      continue
    }

    appendInlineMarkdownLine(trimmedLine, to: output)
  }

  return output
}

/// The document's title as the **first line of the scrolling body** (ADR 0006,
/// addendum 2026-09-02).
///
/// It used to sit in a pinned band above the transcript. The band existed to
/// hold the metadata that moved into the Details panel; with the title alone
/// left in it, a whole non-scrolling region was reserved for one line — and a
/// band is the shape the transcript's old **shake** came out of, a height that
/// changed on scroll changing the scroll range that decided it. A line of text
/// inside the column cannot do that: it is content, and content has no height
/// that scroll can alter.
///
/// It is drawn as the `# ` heading it literally is in the markdown, at the same
/// H1 face the body would have given it, so a Nota export and a foreign `.md`
/// that opens with a heading look the same. Full ink rather than the reading
/// tier — it is the largest and most important run on the surface, and that is
/// the tier the pinned title already used.
func renderDocumentTitle(_ title: String) -> NSAttributedString {
  let output = NSMutableAttributedString()
  appendPlainLine(
    title, to: output, font: NSFonts.readingH1, color: GroundInk.nsColor(.body),
    paragraphSpacing: Metrics.paraSpacingH1,
    // Nothing above the document's first line.
    paragraphSpacingBefore: 0)
  return output
}

/// Which lines of a document the pane draws, as a pure decision.
///
/// **The title.** It is the first `# ` line before the first `## ` — exactly
/// what `parseDocumentMeta` takes — and it is skipped here because the pane
/// draws it itself, once, at the top of the body. Skipping *that* line rather
/// than "a leading heading" is what keeps the two from disagreeing: whatever
/// `parseDocumentMeta` calls the title is the line that does not render.
///
/// **The body, and how it degrades.** `## Full Transcript` is what makes a file
/// recognizably one of Nota's own exports (`src/pipeline/write.ts`), and it is
/// the *only* thing this decision keys on:
///
/// - With it, the file's shape is known. `.transcript` starts after that
///   heading — dropping the metadata block, the summary sections and the
///   heading itself, since the pane **is** the transcript — and `.whole` starts
///   at the first `## `, which is the metadata block and nothing else, exactly
///   as copy and export have always had it.
/// - Without it, nothing about the file's shape is known, so **nothing is
///   assumed and nothing is dropped**: the whole document renders, in both
///   modes, minus the one line the pane draws as the title. Anything cleverer
///   guesses — and the two guesses available are both wrong. Cutting
///   "everything before the transcript" renders an imported file as *nothing*.
///   Cutting "everything before the first `## `" — which is what this renderer
///   did until 2026-09-02 — silently eats an imported file's opening
///   paragraphs, which is the same failure quieter: it is a metadata block only
///   in a document that has one.
enum DocumentBody {
  /// The heading Nota's own exports put in front of the transcript
  /// (`src/pipeline/write.ts`), and the one marker that says this file's shape
  /// is known.
  static let transcriptHeading = "## Full Transcript"

  struct Plan: Equatable {
    /// The lines that reach the renderer.
    var range: Range<Int>
    /// The `# Title` line, when the document has one. It is skipped inside
    /// `range` — which it falls inside whenever the file is not a Nota export.
    var titleLine: Int?
  }

  static func plan(lines: [String], sections: RenderedSections) -> Plan {
    func trimmed(_ index: Int) -> String {
      lines[index].trimmingCharacters(in: .whitespaces)
    }
    let firstSection = lines.indices.first { trimmed($0).hasPrefix("## ") }
    let titleLine = lines.indices.first {
      $0 < (firstSection ?? lines.count) && trimmed($0).hasPrefix("# ")
    }
    let transcript = lines.indices.first { trimmed($0) == transcriptHeading }

    var start = 0
    if let transcript {
      start = sections == .transcript ? transcript + 1 : (firstSection ?? 0)
    }
    // Open on real content: a section heading is followed by a blank line in
    // every export, and an imported file opens on the title the pane is already
    // drawing.
    while start < lines.count, trimmed(start).isEmpty || start == titleLine {
      start += 1
    }

    return Plan(range: start..<lines.count, titleLine: titleLine)
  }

  /// Every speaker name the given lines will draw, after the render-time
  /// override substitution — the input to the column's one measuring pass.
  static func speakerNames(
    in lines: ArraySlice<String>, overrides: [String: String]
  ) -> [String] {
    lines.compactMap { line in
      guard
        let groups = matchTranscript(
          speakerLinePattern, in: line.trimmingCharacters(in: .whitespaces))
      else { return nil }
      let raw = groups[2]
      return overrides[raw] ?? raw
    }
  }
}

private func appendPlainLine(
  _ line: String,
  to output: NSMutableAttributedString,
  font: NSFont,
  color: NSColor = GroundInk.nsColor(.reading),
  paragraphSpacing: CGFloat = Metrics.paraSpacingTight,
  paragraphSpacingBefore: CGFloat = 0
) {
  let paragraph = NSMutableParagraphStyle()
  paragraph.paragraphSpacing = paragraphSpacing
  paragraph.paragraphSpacingBefore = paragraphSpacingBefore
  paragraph.lineSpacing = Metrics.lineSpacingReading
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
  paragraph.lineSpacing = Metrics.lineSpacingReading

  output.append(NSAttributedString(string: "• ", attributes: [
    .font: NSFonts.readingBody,
    .foregroundColor: GroundInk.nsColor(.reading),
    .paragraphStyle: paragraph
  ]))
  appendInlineMarkdown(line, to: output, font: NSFonts.readingBody, paragraphStyle: paragraph)
  output.append(NSAttributedString(string: "\n"))
}

/// `[MM:SS] **Speaker:** text`.
private let speakerLinePattern = #"^\[([0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?)\] \*\*(.+?):\*\* (.*)$"#
/// `[MM:SS] text` — a timestamped line with no speaker label.
private let plainLinePattern = #"^\[([0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?)\] (.*)$"#

private func appendTranscriptLine(
  _ line: String,
  to output: NSMutableAttributedString,
  overrides: [String: String] = [:],
  nameWidth: CGFloat
) -> Bool {
  // [MM:SS] **Speaker:** text — two columns, the visible timestamp dropped and
  // carried as a `.notaTimestamp` attribute for the hover gutter.
  if let groups = matchTranscript(speakerLinePattern, in: line) {
    let paragraph = SpeakerColumn.paragraphStyle(nameWidth: nameWidth)
    let rawLabel = groups[2]
    // Apply render-time substitution: use override name when present, original
    // label otherwise. Body on disk is never mutated.
    let displayLabel = overrides[rawLabel] ?? rawLabel
    let start = output.length
    // tab → right-aligned name → tab → left-aligned words. The colon went with
    // the inline prefix: two columns already separate the name from the words,
    // and a colon hanging off the alignment edge is punctuation doing a job the
    // layout is doing.
    output.append(NSAttributedString(string: "\t", attributes: [
      .font: SpeakerColumn.font,
      .foregroundColor: GroundInk.nsColor(.speaker),
      .paragraphStyle: paragraph
    ]))
    output.append(NSAttributedString(string: SpeakerColumn.drawnName(displayLabel), attributes: [
      .font: SpeakerColumn.font,
      .foregroundColor: GroundInk.nsColor(.speaker),
      .paragraphStyle: paragraph,
      // The whole name, whatever the column had room to draw.
      .notaSpeakerName: displayLabel
    ]))
    output.append(NSAttributedString(string: "\t", attributes: [
      .font: NSFonts.readingBody,
      .foregroundColor: GroundInk.nsColor(.reading),
      .paragraphStyle: paragraph
    ]))
    output.append(NSAttributedString(string: groups[3], attributes: [
      .font: NSFonts.readingBody,
      .foregroundColor: GroundInk.nsColor(.reading),
      .paragraphStyle: paragraph
    ]))
    attachTimestamp(groups[1], from: start, to: output)
    output.append(NSAttributedString(string: "\n"))
    return true
  }

  // [MM:SS] text — timestamped line without a speaker label. Its words start on
  // the same edge as everybody else's.
  if let groups = matchTranscript(plainLinePattern, in: line) {
    let paragraph = SpeakerColumn.continuationStyle(nameWidth: nameWidth)
    let start = output.length
    output.append(NSAttributedString(string: groups[2], attributes: [
      .font: NSFonts.readingBody,
      .foregroundColor: GroundInk.nsColor(.reading),
      .paragraphStyle: paragraph
    ]))
    attachTimestamp(groups[1], from: start, to: output)
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
private func attachTimestamp(_ raw: String, from start: Int, to output: NSMutableAttributedString) {
  guard output.length > start else {
    return
  }
  let range = NSRange(location: start, length: output.length - start)
  output.addAttribute(.notaTimestamp, value: prettyTimestamp(raw), range: range)
  // …and the same instant as a number, for the moment pips (XIA-429). Both come
  // off the one raw capture, so the label in the gutter and the pip beside it
  // can never name different seconds.
  output.addAttribute(
    .notaTimestampSeconds,
    value: NSNumber(value: timestampSeconds(raw)),
    range: range
  )
}

/// "01:02:03" becomes 3723, "0:51" becomes 51. Read off the raw capture rather
/// than the prettified string: this is the numeric half of the same fact.
func timestampSeconds(_ raw: String) -> TimeInterval {
  raw.split(separator: ":")
    .map { TimeInterval(Int($0) ?? 0) }
    .reduce(0) { $0 * 60 + $1 }
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
  paragraph.lineSpacing = Metrics.lineSpacingReading
  appendInlineMarkdown(line, to: output, font: NSFonts.readingBody, paragraphStyle: paragraph)
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

    let segmentFont = index.isMultiple(of: 2)
      ? font
      : NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
    output.append(NSAttributedString(string: part, attributes: [
      .font: segmentFont,
      .foregroundColor: GroundInk.nsColor(.reading),
      .paragraphStyle: paragraphStyle
    ]))
  }
}
