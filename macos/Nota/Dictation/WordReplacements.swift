import Foundation

// MARK: - WordReplacements

/// L2 of the dictation pipeline: deterministic `spokenForms` → `term`
/// substitution driven by the custom dictionary.
///
/// Runs after `Formatter.applyRules` and before LLM polish, so the polish model
/// sees the corrected spelling instead of being asked to guess it. Pure and
/// offline — when polish is disabled this is the last thing that touches the
/// text.
enum WordReplacements {
  /// One `spoken → term` substitution.
  struct Rule: Equatable {
    let spoken: String
    let term: String
  }

  /// Flatten the dictionary into substitution rules, longest spoken form first.
  ///
  /// Longest-first matters because spoken forms overlap: with "gency to rust"
  /// and "rust" both in the dictionary, applying the short one first would eat
  /// the tail of the long one and leave "gency to Rust".
  static func rules(from terms: [DictionaryTerm]) -> [Rule] {
    var rules: [Rule] = []
    for term in terms {
      for spoken in term.spokenForms {
        let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only an exact copy of the term is dropped, as a pure no-op. A form
        // that differs merely in case is kept: "nota" → "Nota" is a fix the
        // user explicitly asked for by storing it.
        guard !trimmed.isEmpty, trimmed != term.term else { continue }
        rules.append(Rule(spoken: trimmed, term: term.term))
      }
    }
    // `sorted(by:)` is not stable, so ties are broken on the spoken form and
    // then the term: `apply` resolves same-position matches by rule order, so
    // an unstable sort would make its output vary run to run.
    return rules.sorted {
      if $0.spoken.count != $1.spoken.count { return $0.spoken.count > $1.spoken.count }
      if $0.spoken != $1.spoken { return $0.spoken < $1.spoken }
      return $0.term < $1.term
    }
  }

  /// Apply every dictionary substitution to `text`.
  static func apply(_ text: String, terms: [DictionaryTerm]) -> String {
    apply(text, rules: rules(from: terms))
  }

  /// One left-to-right pass over `text`: at each position the first rule that
  /// matches wins (rules arrive longest-first) and its *input* span is consumed.
  ///
  /// Consuming the input is the point. Folding the rules over an accumulating
  /// result instead let a short rule fire inside a term a long rule had just
  /// produced — with `package.json` ("package json") and `JSON` ("json") both
  /// in the dictionary, "package json" became "package.JSON", a spelling
  /// neither entry asks for. One pass means every character of what the user
  /// said is rewritten at most once.
  static func apply(_ text: String, rules: [Rule]) -> String {
    guard !text.isEmpty, !rules.isEmpty else { return text }
    var result = ""
    var index = text.startIndex
    // The character before `index` in the original text — the left half of the
    // `(?<![A-Za-z0-9])` boundary. Nil at the start of the text.
    var previous: Character?

    while index < text.endIndex {
      if !isBoundaryBlocking(previous), let match = firstMatch(in: text, at: index, rules: rules) {
        result.append(match.term)
        previous = text[text.index(before: match.end)]
        index = match.end
        continue
      }
      previous = text[index]
      result.append(text[index])
      index = text.index(after: index)
    }
    return result
  }

  // MARK: - Matching

  private struct Match {
    let term: String
    let end: String.Index
  }

  private static func firstMatch(
    in text: String,
    at index: String.Index,
    rules: [Rule]
  ) -> Match? {
    for rule in rules {
      guard let end = matchEnd(of: rule.spoken, in: text, at: index) else { continue }
      return Match(term: rule.term, end: end)
    }
    return nil
  }

  /// End index of `spoken` matched case-insensitively at `index`, or nil.
  ///
  /// The boundary is `(?<![A-Za-z0-9]) … (?![A-Za-z0-9])`, not `\b`: `\b` sits
  /// between a word character and a non-word character, so it fires *inside*
  /// the identifiers this dictionary exists to protect — `genc2rust`,
  /// `package.json`, `--no-history` would all be matched piecewise. Treating
  /// punctuation as a boundary means a spoken form only ever replaces a
  /// complete alphanumeric run.
  private static func matchEnd(
    of spoken: String,
    in text: String,
    at index: String.Index
  ) -> String.Index? {
    guard let range = text.range(
      of: spoken,
      options: [.caseInsensitive, .anchored],
      range: index..<text.endIndex
    ) else { return nil }
    guard !isBoundaryBlocking(range.upperBound == text.endIndex ? nil : text[range.upperBound])
    else { return nil }
    return range.upperBound
  }

  /// True when `character` is one of `[A-Za-z0-9]`, i.e. when it sits mid-token
  /// and so blocks a match from starting or ending next to it.
  private static func isBoundaryBlocking(_ character: Character?) -> Bool {
    guard let character, character.isASCII else { return false }
    return character.isLetter || character.isNumber
  }
}
