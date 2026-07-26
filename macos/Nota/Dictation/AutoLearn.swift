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

  /// Most terms one session may contribute. A polish call that turned four or
  /// five separate runs into identifiers is rewriting the text, not fixing a
  /// couple of spellings, and every stored term biases every later session.
  static let maxCandidatesPerSession = 3

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
      guard isLearnable(term) else { continue }

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
    return Array(result.prefix(maxCandidatesPerSession))
  }

  // MARK: - What may be learned

  /// Whether `term` is worth writing to the dictionary permanently.
  ///
  /// `ContextSnapshot.isIdentifierShaped` is the L1 harvest filter and is
  /// deliberately generous: a wrong recognition hint costs one session. A
  /// learned term is different — it lands on disk and L2 rewrites every later
  /// session with it — so the bar is higher on two counts.
  ///
  /// 1. The shape must carry real identifier signal. Punctuation alone is not
  ///    enough, or "e.g." and "U.S." (single letters around dots) qualify;
  ///    at least one alphanumeric run of two characters has to survive the
  ///    punctuation, unless a digit or interior case-mix already settles it.
  /// 2. The letters alone must not spell an ordinary English word. "e-mail"
  ///    passes rule 1, but learning it means L2 hyphenates the user's "email"
  ///    forever — a stylistic preference of one polish call made permanent.
  static func isLearnable(_ term: String) -> Bool {
    guard ContextSnapshot.isIdentifierShaped(term) else { return false }
    guard !isCommonWord(term) else { return false }

    if term.contains(where: { $0.isNumber }) { return true }
    if hasInteriorCaseMix(term) { return true }
    return alphanumericRuns(term).contains { $0.count >= 2 }
  }

  /// Uppercase past the first character alongside a lowercase somewhere —
  /// `camelCase`, `NSWorkspace`, `genC2`, but not `Rust` or `JSON`.
  private static func hasInteriorCaseMix(_ term: String) -> Bool {
    term.dropFirst().contains(where: { $0.isUppercase })
      && term.contains(where: { $0.isLowercase })
  }

  private static func alphanumericRuns(_ term: String) -> [Substring] {
    term.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
  }

  /// True when the term is an ordinary word wearing punctuation or case as a
  /// costume: fold away everything but the letters and look the result up.
  private static func isCommonWord(_ term: String) -> Bool {
    let letters = term.lowercased().filter(\.isLetter)
    guard !letters.isEmpty else { return false }
    return commonWords.contains(letters)
  }

  /// Small stoplist, letters-only and lowercased. It does not need to be a
  /// dictionary — it only has to cover the words a polish model actually
  /// restyles: contractions it re-punctuates, ordinals it renumbers, and the
  /// handful of compounds it likes to hyphenate.
  private static let commonWords: Set<String> = [
    "a", "about", "after", "all", "also", "am", "an", "and", "any", "are", "as", "at",
    "back", "be", "because", "been", "before", "best", "but", "by",
    "call", "can", "cant", "come", "could", "couldnt",
    "day", "did", "didnt", "do", "does", "doesnt", "dont", "down",
    "each", "eg", "email", "etc", "even", "first", "for", "from",
    "get", "give", "go", "good", "great", "had", "has", "hasnt", "have", "havent",
    "he", "her", "here", "hes", "him", "his", "how",
    "i", "id", "ie", "if", "ill", "im", "in", "into", "is", "isnt", "it", "its", "ive",
    "just", "know", "let", "lets", "like", "look",
    "make", "many", "me", "more", "most", "my", "nd", "new", "no", "not", "now",
    "of", "ok", "okay", "on", "one", "online", "only", "or", "other", "our", "out", "over",
    "people", "pm", "rd", "right", "said", "same", "say", "see", "she", "shes", "should",
    "shouldnt", "so", "some", "st",
    "take", "th", "than", "that", "thats", "the", "their", "them", "then", "there",
    "these", "they", "theyre", "thing", "think", "this", "those", "time", "to", "two",
    "up", "us", "use", "very", "want", "was", "wasnt", "way", "we", "well", "were",
    "werent", "what", "whats", "when", "which", "who", "will", "with", "wont", "work",
    "would", "wouldnt", "year", "you", "your", "youre",
  ]

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
