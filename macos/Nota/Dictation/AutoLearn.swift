import Foundation

// MARK: - AutoLearn

/// Learns dictionary entries from what polish actually corrected.
///
/// The polish model routinely repairs an identifier the recognizer mangled
/// ("gency to rust" → "genc2rust"). That correction is exactly the
/// `spokenForms → term` pair the dictionary wants, and capturing it means the
/// next session gets the term for free at L1/L2 without a paid call.
///
/// Deliberately conservative: only a run of words collapsing into a single
/// identifier-shaped token is learned. Ordinary prose edits (grammar,
/// punctuation, filler removal) must never reach the dictionary.
enum AutoLearn {
  /// A `spokenForm → term` pair recovered from a polish diff.
  struct Candidate: Equatable {
    let term: String
    let spokenForm: String
  }

  /// Longest misheard run that can collapse into one term. Beyond this the
  /// "correction" is more likely a rewrite than a spelling fix.
  static let maxSpokenWords = 5

  /// Above this token count the O(n·m) alignment is not worth running — long
  /// dictations are rewritten in too many places for a diff to be meaningful.
  static let maxTokens = 400

  /// Pairs worth adding to the dictionary as `.learned`.
  static func candidates(before: String, after: String) -> [Candidate] {
    let beforeTokens = tokenize(before)
    let afterTokens = tokenize(after)
    guard !beforeTokens.isEmpty, !afterTokens.isEmpty else { return [] }
    guard beforeTokens.count <= maxTokens, afterTokens.count <= maxTokens else { return [] }

    var result: [Candidate] = []
    var seen = Set<String>()
    for block in changedBlocks(beforeTokens, afterTokens) {
      // One replacement token only: a multi-token "correction" is a rewrite.
      guard block.after.count == 1, let term = normalizedTerm(block.after[0]) else { continue }
      guard !block.before.isEmpty, block.before.count <= maxSpokenWords else { continue }
      guard ContextSnapshot.isIdentifierShaped(term) else { continue }

      let spokenForm = block.before
        .compactMap { normalizedTerm($0) }
        .joined(separator: " ")
      guard !spokenForm.isEmpty,
            spokenForm.caseInsensitiveCompare(term) != .orderedSame,
            // A misheard form made of identifier-shaped tokens is usually the
            // model reformatting something already correct, not a mishearing.
            !spokenForm.split(separator: " ").allSatisfy({
              ContextSnapshot.isIdentifierShaped(String($0))
            }),
            seen.insert("\(term.lowercased())\u{1}\(spokenForm.lowercased())").inserted
      else { continue }

      result.append(Candidate(term: term, spokenForm: spokenForm))
    }
    return result
  }

  // MARK: - Diff

  private struct Block {
    let before: [String]
    let after: [String]
  }

  static func tokenize(_ text: String) -> [String] {
    text.split(whereSeparator: { $0 == " " || $0.isNewline || $0 == "\t" }).map(String.init)
  }

  /// Maximal runs where the two token lists disagree, via a plain LCS table
  /// over case-folded, punctuation-stripped tokens.
  private static func changedBlocks(_ before: [String], _ after: [String]) -> [Block] {
    let a = before.map(comparisonKey)
    let b = after.map(comparisonKey)

    var lcs = Array(
      repeating: Array(repeating: 0, count: b.count + 1),
      count: a.count + 1
    )
    if a.count > 0, b.count > 0 {
      for i in stride(from: a.count - 1, through: 0, by: -1) {
        for j in stride(from: b.count - 1, through: 0, by: -1) {
          lcs[i][j] = a[i] == b[j]
            ? lcs[i + 1][j + 1] + 1
            : max(lcs[i + 1][j], lcs[i][j + 1])
        }
      }
    }

    var blocks: [Block] = []
    var i = 0
    var j = 0
    var pendingBefore: [String] = []
    var pendingAfter: [String] = []

    func flush() {
      guard !pendingBefore.isEmpty || !pendingAfter.isEmpty else { return }
      blocks.append(Block(before: pendingBefore, after: pendingAfter))
      pendingBefore = []
      pendingAfter = []
    }

    while i < a.count, j < b.count {
      if a[i] == b[j] {
        flush()
        i += 1
        j += 1
      } else if lcs[i + 1][j] >= lcs[i][j + 1] {
        pendingBefore.append(before[i])
        i += 1
      } else {
        pendingAfter.append(after[j])
        j += 1
      }
    }
    while i < a.count {
      pendingBefore.append(before[i])
      i += 1
    }
    while j < b.count {
      pendingAfter.append(after[j])
      j += 1
    }
    flush()
    return blocks
  }

  // MARK: - Token helpers

  /// Sentence punctuation only — `.` `_` `-` `/` stay because they belong to
  /// the identifiers being learned (`package.json`, `--no-history`).
  private static let edgePunctuation = CharacterSet(charactersIn: ",;:!?\"'`“”‘’()[]{}<>…|")

  private static func stripEdgePunctuation(_ token: String) -> String {
    token.trimmingCharacters(in: edgePunctuation)
  }

  /// The term as it should be stored: edge punctuation gone, and a trailing
  /// sentence period dropped (a period is legitimate *inside* `package.json`
  /// but never at the end of the last word of a sentence).
  private static func normalizedTerm(_ token: String) -> String? {
    var term = stripEdgePunctuation(token)
    while term.hasSuffix(".") { term.removeLast() }
    term = stripEdgePunctuation(term)
    return term.isEmpty ? nil : term
  }

  /// Tokens are compared case- and punctuation-insensitively so that pure
  /// capitalization or punctuation edits are not reported as changes — the
  /// terminal period `Formatter.ensureTerminalPunctuation` adds would
  /// otherwise make the last word of every sentence look rewritten.
  private static func comparisonKey(_ token: String) -> String {
    normalizedTerm(token)?.lowercased() ?? ""
  }
}
