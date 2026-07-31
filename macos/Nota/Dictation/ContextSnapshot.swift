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
  /// Kept in-process so the optional screenshot fallback can target the
  /// session's window. Never included in a model prompt.
  var processID: pid_t? = nil
  var windowTitle: String?
  /// A bounded sample from the focused accessibility element, when the user
  /// explicitly enabled focused-app context for polish. This is never used as
  /// an audio-recognition hint.
  var focusedText: String? = nil

  static let empty = ContextSnapshot(
    appName: nil,
    bundleID: nil,
    processID: nil,
    windowTitle: nil,
    focusedText: nil
  )

  var isEmpty: Bool {
    appName == nil && bundleID == nil && windowTitle == nil && focusedText == nil
  }

  /// Context that may be sent to the cleanup model for this session.
  ///
  /// Keeping this policy pure makes the opt-in gate explicit and testable. An
  /// unavailable or empty accessibility snapshot is a normal no-context case,
  /// not an error that should interrupt dictation.
  func cleanupContext(enabled: Bool) -> ContextSnapshot? {
    guard enabled, !isEmpty else { return nil }
    return self
  }

  /// Snapshot the frontmost app and its focused window title.
  ///
  /// Async, and deliberately not `@MainActor`: only the `NSWorkspace` lookup
  /// needs the main thread, while the AX round-trip is a synchronous IPC into
  /// another process that can sit there for its whole messaging timeout. This
  /// is called the instant the hotkey goes down, where a blocked main thread
  /// is a frozen HUD and a late microphone.
  ///
  /// AX failures (untrusted process, app without an AX-visible window) degrade
  /// to nil rather than throwing.
  static func capture(includeFocusedText: Bool = false) async -> ContextSnapshot {
    guard let frontApp = await MainActor.run(body: { frontmostApp() }) else {
      return .empty
    }
    return ContextSnapshot(
      appName: frontApp.name,
      bundleID: frontApp.bundleID,
      processID: frontApp.pid,
      windowTitle: focusedWindowTitle(pid: frontApp.pid),
      focusedText: includeFocusedText ? focusedText(pid: frontApp.pid) : nil
    )
  }

  /// Identity of the frontmost app. `NSWorkspace` is main-thread API, but this
  /// reads local state only — it never messages the other process.
  @MainActor
  static func frontmostApp() -> (name: String?, bundleID: String?, pid: pid_t)? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    return (app.localizedName, app.bundleIdentifier, app.processIdentifier)
  }

  /// Focused-window title of `pid`, or nil.
  ///
  /// Guarded by `AXIsProcessTrusted()`: calling AX without the grant returns
  /// errors anyway, and skipping the calls avoids a pointless several-hundred
  /// millisecond timeout on some apps. The AX C API is thread-safe, so this
  /// runs wherever `capture()` was resumed.
  private static func focusedWindowTitle(pid: pid_t) -> String? {
    guard AXIsProcessTrusted() else { return nil }
    let appElement = AXUIElementCreateApplication(pid)
    // This runs the instant the hotkey goes down, before the microphone opens,
    // so a wedged frontmost app must not be able to eat the user's first words
    // against the 6 s default AX timeout.
    AXUIElementSetMessagingTimeout(appElement, 0.25)

    var windowValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      appElement,
      kAXFocusedWindowAttribute as CFString,
      &windowValue
    ) == .success, let windowValue else { return nil }
    // A third-party AX server can return `.success` with some other CF type in
    // the out-parameter; force-casting that traps and takes dictation — and the
    // app — down with it.
    guard CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }
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

  /// Read only the focused accessibility element, never the window hierarchy.
  ///
  /// The value is intentionally sampled once per user-initiated dictation and
  /// bounded before it can leave the process. Secure/password controls and
  /// controls with a sensitive accessibility label are refused. If an app does
  /// not expose a value or times out, the caller gets nil and ordinary
  /// dictation continues.
  private static func focusedText(pid: pid_t) -> String? {
    guard AXIsProcessTrusted() else { return nil }
    let appElement = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(appElement, 0.25)

    var focusedValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      appElement,
      kAXFocusedUIElementAttribute as CFString,
      &focusedValue
    ) == .success, let focusedValue,
    CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
    else { return nil }

    let element = focusedValue as! AXUIElement
    guard !element.hasSecureRole, !hasSensitiveContextLabel(element) else { return nil }

    // A selected range is the most relevant and least surprising context for
    // a dictation cleanup request. If there is no selection, prefer the
    // element's visible range before falling back to its bounded value.
    if let selected = stringAttribute(element, kAXSelectedTextAttribute as CFString),
       let selected = boundedFocusedText(selected)
    {
      return selected
    }

    if let visibleRange = rangeAttribute(element, kAXVisibleCharacterRangeAttribute as CFString),
       let visible = stringForRange(element, visibleRange),
       let visible = boundedFocusedText(visible)
    {
      return visible
    }

    return stringAttribute(element, kAXValueAttribute as CFString)
      .flatMap(boundedFocusedText)
  }

  private static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
      return nil
    }
    return value as? String
  }

  private static func rangeAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFRange? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
          let value,
          CFGetTypeID(value) == AXValueGetTypeID(),
          AXValueGetType(value as! AXValue) == .cfRange
    else { return nil }

    var range = CFRange()
    guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
    return range.location >= 0 && range.length >= 0 ? range : nil
  }

  private static func stringForRange(_ element: AXUIElement, _ range: CFRange) -> String? {
    var requestedRange = range
    guard let parameter = AXValueCreate(.cfRange, &requestedRange) else { return nil }
    var value: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(
      element,
      kAXStringForRangeParameterizedAttribute as CFString,
      parameter,
      &value
    ) == .success else { return nil }
    return value as? String
  }

  /// Internal for tests: this is the last bound before focused text can enter
  /// a model prompt.
  static func boundedFocusedText(_ value: String?) -> String? {
    guard let value else { return nil }
    let flattened = value.unicodeScalars.map { scalar -> Character in
      if CharacterSet.whitespacesAndNewlines.contains(scalar)
        || CharacterSet.controlCharacters.contains(scalar)
      {
        return " "
      }
      return Character(String(scalar))
    }
    let collapsed = String(flattened)
      .split(separator: " ", omittingEmptySubsequences: true)
      .joined(separator: " ")
    guard !collapsed.isEmpty else { return nil }
    guard collapsed.count > maxFocusedTextLength else { return collapsed }
    return String(collapsed.prefix(maxFocusedTextLength - 1))
      .trimmingCharacters(in: .whitespaces) + "…"
  }

  private static let maxFocusedTextLength = 2_000

  private static func hasSensitiveContextLabel(_ element: AXUIElement) -> Bool {
    let labels = [
      stringAttribute(element, kAXTitleAttribute as CFString),
      stringAttribute(element, kAXDescriptionAttribute as CFString),
      stringAttribute(element, kAXRoleAttribute as CFString),
      stringAttribute(element, kAXSubroleAttribute as CFString),
    ]
      .compactMap { $0?.lowercased() }

    let sensitiveMarkers = [
      "password", "passcode", "secret", "private key", "api key", "access token",
      "auth token", "security code", "credit card", "cvv", "credential",
    ]
    return labels.contains { label in
      sensitiveMarkers.contains { label.contains($0) }
    }
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

  /// Cap for the L3 polish prompt's vocabulary block. Smaller than the L1 cap
  /// because every term is prompt tokens on a per-session paid call, and a long
  /// list dilutes the model's attention rather than sharpening it.
  static let maxPromptTerms = 60

  /// Rank dictionary terms and harvested identifiers into a hint list.
  ///
  /// Order is the cut order: starred terms survive first, then manual/learned
  /// terms, then dictionary-harvested terms, then identifiers harvested from
  /// the window title.
  ///
  /// `maxWords` nil keeps phrases of any length — used for the L3 prompt, where
  /// the 1–2 word rule does not apply.
  static func build(
    terms: [DictionaryTerm],
    harvested: [String] = [],
    limit: Int = maxHints,
    maxWords: Int? = maxWordsPerHint
  ) -> [String] {
    let starred = terms.filter { $0.starred }.map(\.term)
    let authored = terms.filter { !$0.starred && $0.source != .harvested }.map(\.term)
    let dictHarvested = terms.filter { !$0.starred && $0.source == .harvested }.map(\.term)

    var result: [String] = []
    var seen = Set<String>()
    for candidate in starred + authored + dictHarvested + harvested {
      guard result.count < limit else { break }
      let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, fits(trimmed, maxWords: maxWords) else { continue }
      guard seen.insert(trimmed.lowercased()).inserted else { continue }
      result.append(trimmed)
    }
    return result
  }

  /// Terms and identifiers for the L3 polish prompt's vocabulary block. Same
  /// ranking as `build`, but multi-word terms are kept — the prompt has no
  /// 1–2 word restriction.
  static func promptVocabulary(
    terms: [DictionaryTerm],
    harvested: [String] = [],
    limit: Int = maxPromptTerms
  ) -> [String] {
    build(terms: terms, harvested: harvested, limit: limit, maxWords: nil)
  }

  private static func fits(_ phrase: String, maxWords: Int?) -> Bool {
    guard let maxWords else { return true }
    return phrase.split(whereSeparator: { $0 == " " || $0.isNewline || $0 == "\t" }).count
      <= maxWords
  }
}
