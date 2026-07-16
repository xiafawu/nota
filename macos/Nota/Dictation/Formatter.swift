import Foundation

// MARK: - Formatter

/// Pure local formatting rules for dictation output.
///
/// All methods are deterministic and I/O-free, suitable for unit testing
/// and offline use. The pipeline is:
///   1. Normalize whitespace (collapse, trim)
///   2. Drop standalone filler words ("um", "uh", "you know")
///   3. Clean up false starts (dropped leading partial words)
///   4. Capitalize first character
///   5. Ensure terminal punctuation
enum Formatter {
  /// Apply the full local formatting pipeline to `raw` recognition output.
  static func applyRules(_ raw: String) -> String {
    guard !raw.isEmpty else { return raw }
    var s = raw
    s = normalizeWhitespace(s)
    s = dropFillerWords(s)
    s = cleanupFalseStarts(s)
    s = capitalizeFirst(s)
    s = ensureTerminalPunctuation(s)
    return s
  }

  // MARK: - Individual rules (public for testability)

  /// Collapse runs of whitespace to a single space; trim leading/trailing.
  static func normalizeWhitespace(_ s: String) -> String {
    let collapsed = s
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    return collapsed
  }

  /// Remove standalone filler words ("um", "uh", "you know") in a
  /// case-insensitive, whole-word manner.
  static func dropFillerWords(_ s: String) -> String {
    guard !s.isEmpty else { return s }
    let fillers: [String] = ["um", "uh", "you know"]
    let words = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    var keep = [Bool](repeating: true, count: words.count)

    for i in words.indices {
      guard keep[i] else { continue }
      let lower = words[i].trimmingCharacters(in: .punctuationCharacters).lowercased()

      // Check single-word fillers
      if fillers.contains(lower) {
        keep[i] = false
        continue
      }

      // Check multi-word fillers (e.g. "you know")
      for filler in fillers where filler.contains(" ") {
        let fillerWords = filler.components(separatedBy: " ")
        let end = i + fillerWords.count
        guard end <= words.count else { continue }
        let slice = words[i..<end]
          .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
        if slice == fillerWords {
          for j in i..<end { keep[j] = false }
        }
      }
    }

    let result = words.enumerated().filter { keep[$0.offset] }.map { $0.element }
    return result.joined(separator: " ")
  }

  /// Basic false-start cleanup: remove a leading repeated word (e.g.
  /// "I I think" → "I think", "the the cat" → "the cat").
  /// Only handles a single repetition at the start.
  static func cleanupFalseStarts(_ s: String) -> String {
    guard !s.isEmpty else { return s }
    let words = s.components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
    guard words.count >= 2 else { return s }

    let first = words[0].trimmingCharacters(in: .punctuationCharacters).lowercased()
    let second = words[1].trimmingCharacters(in: .punctuationCharacters).lowercased()

    if first == second {
      return words.dropFirst().joined(separator: " ")
    }
    return s
  }

  /// Capitalize the first character of the string.
  static func capitalizeFirst(_ s: String) -> String {
    guard !s.isEmpty else { return s }
    var result = s
    // Find the first letter (skip leading punctuation/quotes)
    if let range = result.rangeOfCharacter(from: .letters) {
      let firstChar = result[range.lowerBound]
      let upper = firstChar.uppercased()
      result.replaceSubrange(range.lowerBound...range.lowerBound, with: upper)
    }
    return result
  }

  /// Append a period (`.`) at the end if the string does not already end
  /// with sentence-ending punctuation (`.`, `!`, `?`).
  static func ensureTerminalPunctuation(_ s: String) -> String {
    guard !s.isEmpty else { return s }
    let terminal: CharacterSet = [".", "!", "?"]
    if let last = s.unicodeScalars.last, terminal.contains(last) {
      return s
    }
    return s + "."
  }
}
