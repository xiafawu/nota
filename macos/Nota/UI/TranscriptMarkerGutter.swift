import Foundation

/// Where a flagged moment lands in a **finished** transcript (XIA-429 rule 4).
///
/// Markers persist as `atSeconds` on the record (XIA-433). The exported `.md`
/// prints each segment's **start** (`formatTimestamp(seg.start)` in
/// src/pipeline/write.ts, mirrored by `LiveSessionPersistence.buildMarkdown`),
/// so a marker belongs to the **last line that had already started** when it was
/// flagged. That is deliberately not the live surface's rule —
/// `LiveTranscriptMarking` picks the first line whose `endTime >= t`, because a
/// live transcript is indexed by when a line *finished* arriving. The two
/// disagree at boundaries, and each is right about the document it reads.
///
/// A marker flagged before the first line has one anyway: it belongs to line 0,
/// because the alternative is a moment the owner flagged that the document does
/// not admit exists.
///
/// Pure, so the mapping is asserted with no text view, no layout manager and no
/// window server.
enum TranscriptMarkerGutter {
  /// The line indices that carry a pip, ascending and deduplicated: two moments
  /// flagged inside one line draw one pip, because a pip means "something here"
  /// and there is no second place to put the second one.
  /// `lineStarts` is in document order and therefore ascending, so the search
  /// is a **binary** one per marker rather than a scan of every line. This runs
  /// inside `NSTextView.draw(_:)`, which AppKit calls once per tile while
  /// scrolling: an O(markers × lines) inner loop over a 90-minute transcript is
  /// the same unbounded main-thread cost CLAUDE.md records for the HUD prompter
  /// and for XIA-432, arrived at from the other direction.
  static func markedLines(
    markerSeconds: [TimeInterval],
    lineStarts: [TimeInterval]
  ) -> [Int] {
    guard !lineStarts.isEmpty else { return [] }
    var lines = Set<Int>()
    for marker in markerSeconds {
      // The last line whose start is <= marker, or line 0 when the moment was
      // flagged before the first line had one.
      var low = 0
      var high = lineStarts.count - 1
      var found = 0
      while low <= high {
        let mid = (low + high) / 2
        if lineStarts[mid] <= marker {
          found = mid
          low = mid + 1
        } else {
          high = mid - 1
        }
      }
      lines.insert(found)
    }
    return lines.sorted()
  }

  /// The next pip after `current`, wrapping to the first. Wrapping is what makes
  /// the fact strip's "N moments" button keep working on the last press instead
  /// of going dead — the strip says how many there are, so a press that did
  /// nothing would read as a broken count.
  static func nextLine(after current: Int?, marked: [Int]) -> Int? {
    guard let first = marked.first else { return nil }
    guard let current else { return first }
    return marked.first { $0 > current } ?? first
  }
}
