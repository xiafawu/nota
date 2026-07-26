import AppKit
import ApplicationServices
import Foundation

// MARK: - ContextSnapshot

/// What the user was looking at when a dictation session began.
///
/// Captured at session START, not at injection time: the AX round-trip costs a
/// few milliseconds and at start those milliseconds hide under the user's first
/// syllable, whereas at the end they would sit directly on the injection path.
///
/// Everything here is best-effort. Without Accessibility trust the window title
/// is simply nil, and every consumer must behave exactly as it did before this
/// type existed when the snapshot is empty.
struct ContextSnapshot: Equatable, Sendable {
  var appName: String?
  var bundleID: String?
  var windowTitle: String?

  static let empty = ContextSnapshot(appName: nil, bundleID: nil, windowTitle: nil)

  var isEmpty: Bool {
    appName == nil && bundleID == nil && windowTitle == nil
  }

  /// Snapshot the frontmost app and its focused window title.
  ///
  /// `NSWorkspace.frontmostApplication` is main-thread API, so this is
  /// `@MainActor`. AX failures (untrusted process, app without an AX-visible
  /// window) degrade to nil rather than throwing.
  @MainActor
  static func capture() -> ContextSnapshot {
    guard let frontApp = NSWorkspace.shared.frontmostApplication else {
      return .empty
    }
    return ContextSnapshot(
      appName: frontApp.localizedName,
      bundleID: frontApp.bundleIdentifier,
      windowTitle: focusedWindowTitle(pid: frontApp.processIdentifier)
    )
  }

  /// Focused-window title of `pid`, or nil.
  ///
  /// Guarded by `AXIsProcessTrusted()`: calling AX without the grant returns
  /// errors anyway, and skipping the calls avoids a pointless several-hundred
  /// millisecond timeout on some apps.
  @MainActor
  private static func focusedWindowTitle(pid: pid_t) -> String? {
    guard AXIsProcessTrusted() else { return nil }
    let appElement = AXUIElementCreateApplication(pid)

    var windowValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      appElement,
      kAXFocusedWindowAttribute as CFString,
      &windowValue
    ) == .success, let windowValue else { return nil }
    let window = windowValue as! AXUIElement

    var titleValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      window,
      kAXTitleAttribute as CFString,
      &titleValue
    ) == .success, let title = titleValue as? String else { return nil }

    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Identifier-shaped tokens harvested from the window title.
  ///
  /// Window titles are where the ambient vocabulary lives — "genc2rust — src/
  /// lower.rs", "package.json — nota". Only code-ish tokens are kept; ordinary
  /// prose words would dilute the 100-phrase context budget with words the
  /// recognizer already knows.
  func harvestIdentifiers() -> [String] {
    guard let windowTitle else { return [] }
    return ContextSnapshot.harvestIdentifiers(from: windowTitle)
  }

  /// Pure tokenizer behind `harvestIdentifiers()`.
  static func harvestIdentifiers(from title: String) -> [String] {
    var result: [String] = []
    var seen = Set<String>()
    for raw in title.split(whereSeparator: { $0 == " " || $0.isNewline || $0 == "\t" }) {
      let token = String(raw).trimmingCharacters(in: separatorPunctuation)
      guard isIdentifierShaped(token), seen.insert(token.lowercased()).inserted else { continue }
      result.append(token)
    }
    return result
  }

  /// Punctuation that only ever wraps a token (quotes, brackets, sentence
  /// enders). `.` `_` `-` `/` are deliberately absent: they are *part* of the
  /// identifiers we are trying to harvest (`package.json`, `--no-history`).
  private static let separatorPunctuation = CharacterSet(charactersIn: "\"'`“”‘’()[]{}<>,;:!?…|")

  /// A token is identifier-shaped when it carries a signal a plain English word
  /// would not: an interior digit, mixed case past the first character, or
  /// interior code punctuation.
  static func isIdentifierShaped(_ token: String) -> Bool {
    guard token.count >= 2, token.count <= 64 else { return false }
    guard token.rangeOfCharacter(from: .letters) != nil else { return false }

    if token.rangeOfCharacter(from: .decimalDigits) != nil { return true }

    // Mixed case ignoring the first character, so "Rust" is prose and
    // "genC2" / "camelCase" / "NSWorkspace" are identifiers.
    let tail = token.dropFirst()
    if tail.contains(where: { $0.isUppercase }), token.contains(where: { $0.isLowercase }) {
      return true
    }

    // Interior code punctuation: `package.json`, `--no-history`, `src/lower.rs`.
    if token.dropFirst().dropLast().contains(where: { codePunctuation.contains($0) }) {
      return true
    }

    // Leading `--`/`-` flags are identifiers even though the punctuation is not
    // interior (`--force`).
    if token.hasPrefix("-"), token.count >= 3 { return true }

    return false
  }

  private static let codePunctuation: Set<Character> = [".", "_", "-", "/", "\\", ":", "@", "#"]
}

// MARK: - Context hints (L1)

/// Assembly of the `AnalysisContext.contextualStrings` hint list.
///
/// Kept pure and free of the Speech framework so the ranking and the cap are
/// unit-testable without an analyzer.
enum ContextHints {
  /// Apple documents `contextualStrings` as short phrases with a hard cap of
  /// 100 entries; longer entries are ignored by the recognizer, so they are
  /// dropped here rather than spending budget. Multi-word dictionary terms
  /// still take effect at L2 (deterministic replacement) and L3 (polish).
  static let maxHints = 100
  static let maxWordsPerHint = 2

  /// Rank dictionary terms and harvested identifiers into a hint list.
  ///
  /// Order is the cut order: starred terms survive first, then manual/learned
  /// terms, then dictionary-harvested terms, then identifiers harvested from
  /// the window title.
  static func build(
    terms: [DictionaryTerm],
    harvested: [String] = [],
    limit: Int = maxHints
  ) -> [String] {
    let starred = terms.filter { $0.starred }.map(\.term)
    let authored = terms.filter { !$0.starred && $0.source != .harvested }.map(\.term)
    let dictHarvested = terms.filter { !$0.starred && $0.source == .harvested }.map(\.term)

    var result: [String] = []
    var seen = Set<String>()
    for candidate in starred + authored + dictHarvested + harvested {
      guard result.count < limit else { break }
      let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, isShortEnough(trimmed) else { continue }
      guard seen.insert(trimmed.lowercased()).inserted else { continue }
      result.append(trimmed)
    }
    return result
  }

  private static func isShortEnough(_ phrase: String) -> Bool {
    phrase.split(whereSeparator: { $0 == " " || $0.isNewline || $0 == "\t" }).count
      <= maxWordsPerHint
  }
}
