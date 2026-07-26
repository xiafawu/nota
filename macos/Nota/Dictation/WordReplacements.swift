import Foundation
import os

// MARK: - WordReplacements

/// L2 of the dictation pipeline: deterministic `spokenForms` → `term`
/// substitution driven by the custom dictionary.
///
/// Runs after `Formatter.applyRules` and before LLM polish, so the polish model
/// sees the corrected spelling instead of being asked to guess it. Pure and
/// offline — when polish is disabled this is the last thing that touches the
/// text.
enum WordReplacements {
  private static let logger = Logger(
    subsystem: "com.xiafawu.nota",
    category: "dictation.replacements"
  )

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
    // `sorted(by:)` is not stable, so break ties on the spoken form to keep the
    // output of `rules(from:)` deterministic for a given dictionary.
    return rules.sorted {
      $0.spoken.count != $1.spoken.count
        ? $0.spoken.count > $1.spoken.count
        : $0.spoken < $1.spoken
    }
  }

  /// Apply every dictionary substitution to `text`.
  static func apply(_ text: String, terms: [DictionaryTerm]) -> String {
    apply(text, rules: rules(from: terms))
  }

  static func apply(_ text: String, rules: [Rule]) -> String {
    guard !text.isEmpty, !rules.isEmpty else { return text }
    var result = text
    for rule in rules {
      result = replace(rule.spoken, with: rule.term, in: result)
    }
    return result
  }

  /// Case-insensitive whole-token replacement.
  ///
  /// The boundary is `(?<![A-Za-z0-9]) … (?![A-Za-z0-9])`, not `\b`: `\b` sits
  /// between a word character and a non-word character, so it fires *inside*
  /// the identifiers this dictionary exists to protect — `genc2rust`,
  /// `package.json`, `--no-history` would all be matched piecewise. Treating
  /// punctuation as a boundary means a spoken form only ever replaces a
  /// complete alphanumeric run.
  static func replace(_ spoken: String, with term: String, in text: String) -> String {
    let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: spoken)
      + "(?![A-Za-z0-9])"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else {
      logger.error("Unusable replacement pattern for \(spoken, privacy: .public)")
      return text
    }
    return regex.stringByReplacingMatches(
      in: text,
      options: [],
      range: NSRange(text.startIndex..., in: text),
      withTemplate: NSRegularExpression.escapedTemplate(for: term)
    )
  }
}
