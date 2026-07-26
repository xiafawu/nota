import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

// MARK: - TextInjector

/// Hybrid text injection with AX → CGEvent → paste fallback and a per-bundle override table.
///
/// Strategy selection per bundle:
/// 1. Consult the per-app override table for a forced strategy.
/// 2. Default: fallback chain `.accessibility` → `.keyEvents` → `.paste`.
///
/// Secure / password fields are refused with a nonfatal notice.
final class TextInjector {
  private let logger = Logger(subsystem: "com.xiafawu.nota", category: "dictation.injector")

  /// Per-bundle-ID injection overrides. Injectable for tests.
  var overrides: [String: PerAppOverride]

  /// Set when a secure/password field was refused on the last `inject` call.
  private(set) var lastSecureFieldNotice: String?

  /// Clear the secure-field notice after it has been displayed.
  func clearSecureFieldNotice() {
    lastSecureFieldNotice = nil
  }

  init(overrides: [String: PerAppOverride]? = nil) {
    self.overrides = overrides ?? Self.defaultOverrideTable
  }

  // MARK: - Public API

  /// Inject `text` into the given `target` using the strategy table.
  /// Runs off the main thread (uses `Task.sleep` instead of `Thread.sleep`).
  ///
  /// `mode` only changes the Accessibility strategy. CGEvent and paste both
  /// insert at the caret, which already appends; AX sets the field's whole
  /// value, so appending means reading what is there and writing it back with
  /// the delta on the end.
  func inject(_ text: String, target: FocusedTarget, mode: InjectionMode = .standard) async {
    guard !text.isEmpty else {
      logger.info("Skipping injection — empty text")
      return
    }

    lastSecureFieldNotice = nil

    // Check secure / password fields. Re-asked on every write, not read off the
    // capture-time snapshot: a streaming session writes many times against one
    // target and the focus inside that app can move into a password field
    // between two sentences.
    guard !target.isSecureInputNow() else {
      lastSecureFieldNotice = "Cannot dictate into a password or secure field"
      logger.notice("Refusing injection into secure field (bundle=\(target.bundleID ?? "nil", privacy: .public))")
      return
    }

    // Resolve strategy.
    let strategy = resolveStrategy(for: target.bundleID)
    logger.info("Injection strategy for \(target.bundleID ?? "nil", privacy: .public): \(String(describing: strategy))")

    // Fallback chain.
    switch strategy {
    case .accessibility:
      if tryAXInject(text, target: target, mode: mode) {
        logResolved(target.bundleID, strategy: "AX")
        return
      }
      logger.debug("AX failed, falling back to CGEvent")
      if tryCGEventInject(text, target: target) {
        logResolved(target.bundleID, strategy: "CGEvent")
        return
      }
      logger.debug("CGEvent failed, falling back to paste")
      await tryPasteInject(text, for: target)
      logResolved(target.bundleID, strategy: "paste")

    case .keyEvents:
      if tryCGEventInject(text, target: target) {
        logResolved(target.bundleID, strategy: "CGEvent")
        return
      }
      logger.debug("CGEvent failed, falling back to paste")
      await tryPasteInject(text, for: target)
      logResolved(target.bundleID, strategy: "paste")

    case .paste:
      await tryPasteInject(text, for: target)
      logResolved(target.bundleID, strategy: "paste")
    }
  }

  // MARK: - Strategy resolution

  /// Returns the injection strategy for a given bundle ID based on the override table.
  /// Used by tests — also used internally.
  func resolveStrategy(for bundleID: String?) -> InjectionStrategy {
    guard let bundleID, let override = overrides[bundleID], let forced = override.forceStrategy else {
      return .accessibility
    }
    return forced
  }

  /// Returns the pasteboard restore delay in nanoseconds for a bundle ID.
  private func pasteRestoreDelayNs(for bundleID: String?) -> UInt64 {
    guard let bundleID, let override = overrides[bundleID], let custom = override.pasteRestoreDelayMs else {
      return 80_000_000 // default 80 ms
    }
    return UInt64(custom) * 1_000_000
  }

  // MARK: - AX injection

  /// Attempt to inject via AXUIElementSetAttributeValue on the focused element.
  ///
  /// In `.append` mode a failed *read* returns false rather than writing the
  /// delta as the whole value — that would wipe the field. False sends the
  /// caller down the CGEvent branch, which types the same delta at the caret.
  private func tryAXInject(
    _ text: String,
    target: FocusedTarget,
    mode: InjectionMode = .standard
  ) -> Bool {
    guard let element = target.accessibilityElement else {
      logger.debug("AX: no accessibility element available")
      return false
    }

    let value: String
    switch mode {
    case .standard:
      value = text
    case .append:
      guard let current = Self.readAXValue(element) else {
        logger.debug("AX: could not read current value for append — falling back to CGEvent")
        return false
      }
      value = Self.appendedValue(current: current, delta: text)
    }

    // Set AXValue attribute directly.
    let result = AXUIElementSetAttributeValue(
      element,
      kAXValueAttribute as CFString,
      value as CFTypeRef
    )

    if result == .success {
      logger.debug("AX: set value directly — success")
      return true
    }

    logger.debug("AX: set value failed with error \(result.rawValue)")
    return false
  }

  /// Current string value of an AX element, or nil when it has none this
  /// process can read (wrong type, no permission, element gone).
  private static func readAXValue(_ element: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      element,
      kAXValueAttribute as CFString,
      &value
    ) == .success else { return nil }
    return value as? String
  }

  /// The full field value that appends `delta` to `current`. Pure, so the
  /// append-only contract is testable without an AX element.
  static func appendedValue(current: String?, delta: String) -> String {
    (current ?? "") + delta
  }

  // MARK: - CGEvent keystroke injection

  /// Attempt to inject by posting a single CGEvent with UTF-16 string to the
  /// target's process.
  ///
  /// The pid comes from the target, falling back to the frontmost app only when
  /// the capture could not record one. Posting to whatever is frontmost at
  /// delivery time is what made a streaming sentence land in the app the user
  /// switched to while it was being polished.
  private func tryCGEventInject(_ text: String, target: FocusedTarget) -> Bool {
    guard let pid = target.processID ?? frontmostAppPID() else {
      logger.debug("CGEvent: no target or frontmost PID")
      return false
    }

    guard let source = CGEventSource(stateID: .combinedSessionState) else {
      logger.debug("CGEvent: failed to create event source")
      return false
    }

    let utf16 = Array(text.utf16)
    guard !utf16.isEmpty else {
      logger.debug("CGEvent: empty text")
      return false
    }

    // Key-down event with Unicode string payload.
    guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else {
      logger.debug("CGEvent: failed to create key-down event")
      return false
    }
    utf16.withUnsafeBufferPointer { ptr in
      keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: ptr.baseAddress)
    }
    keyDown.postToPid(pid)

    // Key-up event with the same payload.
    guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
      logger.debug("CGEvent: failed to create key-up event")
      return false
    }
    utf16.withUnsafeBufferPointer { ptr in
      keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: ptr.baseAddress)
    }
    usleep(15_000) // 15 ms inter-event delay
    keyUp.postToPid(pid)

    logger.debug("CGEvent: posted \(utf16.count) UTF-16 code units to pid \(pid)")
    return true
  }

  // MARK: - Paste injection

  /// Inject via clipboard save → Cmd-V → clipboard restore with per-app delay.
  private func tryPasteInject(_ text: String, for target: FocusedTarget) async {
    let pasteboard = NSPasteboard.general
    let snapshot = capturePasteboard(pasteboard)
    let restoreDelayNs = pasteRestoreDelayNs(for: target.bundleID)

    defer {
      Task { [weak self] in
        try? await Task.sleep(nanoseconds: restoreDelayNs)
        self?.restorePasteboard(pasteboard, from: snapshot)
      }
    }

    pasteboard.clearContents()
    guard pasteboard.setString(text, forType: .string) else {
      logger.error("Paste: failed to set string on pasteboard")
      return
    }

    // Brief settle for NSPasteboard to flush.
    try? await Task.sleep(nanoseconds: 10_000_000) // 10 ms
    await synthesizeCommandV()
  }

  // MARK: - Pasteboard save/restore

  private func capturePasteboard(_ pb: NSPasteboard) -> PasteboardSnapshot {
    let items: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
      item.types.compactMap { type in
        item.data(forType: type).map { (type, $0) }
      }
    }
    return PasteboardSnapshot(items: items)
  }

  private func restorePasteboard(_ pb: NSPasteboard, from snapshot: PasteboardSnapshot) {
    pb.clearContents()
    let restoredItems = snapshot.items.map { typeDataPairs -> NSPasteboardItem in
      let item = NSPasteboardItem()
      for (type, data) in typeDataPairs {
        item.setData(data, forType: type)
      }
      return item
    }
    pb.writeObjects(restoredItems)
    logger.debug("Paste: restored \(snapshot.items.count) pasteboard items")
  }

  // MARK: - Synthetic Cmd-V

  private func synthesizeCommandV() async {
    let source = CGEventSource(stateID: .combinedSessionState)
    let vKey = CGKeyCode(0x09) // kVK_ANSI_V

    guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
    else {
      logger.error("Paste: failed to create CGEvent for Cmd-V")
      return
    }

    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand

    keyDown.post(tap: .cghidEventTap)
    try? await Task.sleep(nanoseconds: 30_000_000) // 30 ms between down and up
    keyUp.post(tap: .cghidEventTap)

    logger.debug("Paste: posted synthetic Cmd-V")
  }

  // MARK: - Helpers

  private func frontmostAppPID() -> pid_t? {
    NSWorkspace.shared.frontmostApplication?.processIdentifier
  }

  private func logResolved(_ bundleID: String?, strategy: String) {
    logger.info("Injected via \(strategy, privacy: .public) into bundle=\(bundleID ?? "nil", privacy: .public)")
  }
}

// MARK: - Default override table

extension TextInjector {
  /// Known bundle IDs with forced injection strategies.
  ///
  /// Default fallback: AX → CGEvent → paste.
  /// An override may skip early strategies for unreliable targets.
  static let defaultOverrideTable: [String: PerAppOverride] = [
    // Electron / Chrome family — AX value fails silently.
    "com.google.Chrome":           PerAppOverride(forceStrategy: .paste, pasteRestoreDelayMs: 150),
    "com.google.Chrome.canary":    PerAppOverride(forceStrategy: .paste, pasteRestoreDelayMs: 150),
    "org.chromium.Chromium":       PerAppOverride(forceStrategy: .paste, pasteRestoreDelayMs: 150),
    "com.microsoft.edgemac":       PerAppOverride(forceStrategy: .paste, pasteRestoreDelayMs: 150),
    "com.slack.Slack":             PerAppOverride(forceStrategy: .paste, pasteRestoreDelayMs: 150),
    "com.microsoft.VSCode":        PerAppOverride(forceStrategy: .paste, pasteRestoreDelayMs: 120),
    "com.github.copilot.Copilot":  PerAppOverride(forceStrategy: .paste, pasteRestoreDelayMs: 120),
    "com.spotify.client":          PerAppOverride(forceStrategy: .paste, pasteRestoreDelayMs: 120),

    // Terminals — CGEvent works better than AX.
    "com.apple.Terminal":          PerAppOverride(forceStrategy: .keyEvents, pasteRestoreDelayMs: nil),
    "com.googlecode.iterm2":       PerAppOverride(forceStrategy: .keyEvents, pasteRestoreDelayMs: nil),
    "com.mitchellh.ghostty":       PerAppOverride(forceStrategy: .keyEvents, pasteRestoreDelayMs: nil),
    "com.knollsoft.Hyper":         PerAppOverride(forceStrategy: .keyEvents, pasteRestoreDelayMs: nil),
    "net.kovidgoy.kitty":          PerAppOverride(forceStrategy: .keyEvents, pasteRestoreDelayMs: nil),
    "co.zeit.hyper":               PerAppOverride(forceStrategy: .keyEvents, pasteRestoreDelayMs: nil),

    // Standard Cocoa apps — no override (AX fallthrough).
    // "com.apple.TextEdit", "com.apple.Notes", etc.
  ]
}

// MARK: - PasteboardSnapshot

private struct PasteboardSnapshot {
  /// Outer array = pasteboard items; inner = (type, data) for each item.
  let items: [[(NSPasteboard.PasteboardType, Data)]]
}
