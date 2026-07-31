import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

// MARK: - TextInjector

/// Hybrid text injection with AX → paste fallback and a per-bundle override table.
///
/// Strategy selection per bundle:
/// 1. Consult the per-app override table for a forced strategy.
/// 2. Default: fallback chain `.accessibility` → `.paste`.
/// 3. Terminal overrides use `.keyEvents` → `.paste` because terminal
///    emulators handle Unicode keyboard events more reliably than AX.
///
/// Secure / password fields are refused with a nonfatal notice.
final class TextInjector {
  private let logger = Logger(subsystem: "com.xiafawu.nota", category: "dictation.injector")

  /// Per-bundle-ID injection overrides. Injectable for tests.
  var overrides: [String: PerAppOverride]

  /// Set when a secure/password field was refused on the last `inject` call.
  private(set) var lastSecureFieldNotice: String?

  /// Serializes the clipboard save/restore pairs of the paste strategy.
  private let paster = PasteInjector()

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
  func inject(_ text: String, target: FocusedTarget, mode: InjectionMode = .standard) async -> InjectionResult {
    guard !text.isEmpty else {
      logger.info("Skipping injection — empty text")
      return .failed(strategy: nil, reason: "There was no text to insert")
    }

    lastSecureFieldNotice = nil

    // Check secure / password fields on every write. A streaming session can
    // outlive the field that was focused when it began.
    guard !target.isSecureInputNow() else {
      lastSecureFieldNotice = "Cannot dictate into a password or secure field"
      logger.notice("Refusing injection into secure field (bundle=\(target.bundleID ?? "nil", privacy: .public))")
      return .refused(reason: lastSecureFieldNotice ?? "Cannot dictate into a secure field")
    }

    // Never fall back to whichever app happens to be frontmost when capture
    // failed: that could put private dictated text in the wrong application.
    guard target.processID != nil else {
      let reason = "Nota could not identify the app to insert into"
      logger.error("Injection refused — no target process was captured")
      return .failed(strategy: nil, reason: reason)
    }

    let chain = strategyChain(for: target.bundleID)
    logger.info("Injection strategy chain for \(target.bundleID ?? "nil", privacy: .public): \(chain.map(\.description).joined(separator: " → "), privacy: .public)")

    for strategy in chain {
      switch strategy {
      case .accessibility:
        if tryAXInject(text, target: target, mode: mode) {
          logSubmitted(target.bundleID, strategy: .accessibility)
          return .delivered(strategy: .accessibility)
        }
        logger.debug("AX failed, falling back to the next reliable strategy")

      case .keyEvents:
        if tryCGEventInject(text, target: target) {
          logSubmitted(target.bundleID, strategy: .keyEvents)
          return .delivered(strategy: .keyEvents)
        }
        logger.debug("CGEvent could not be posted, falling back to paste")

      case .paste:
        return await tryPasteInject(text, for: target)
      }
    }

    logger.error("No injection strategy could submit text to the captured target")
    return .failed(strategy: nil, reason: "Nota could not submit text to the captured target")
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

  /// The ordered delivery chain for a target.
  ///
  /// A Unicode CGEvent only reports that WindowServer accepted the event post;
  /// it cannot report that an Electron/webview editor accepted the characters.
  /// Unknown applications therefore skip that unverifiable step and use paste
  /// after AX fails. Explicit terminal overrides retain CGEvent as their first
  /// choice, with paste as the recovery path.
  func strategyChain(for bundleID: String?) -> [InjectionStrategy] {
    switch resolveStrategy(for: bundleID) {
    case .accessibility:
      return [.accessibility, .paste]
    case .keyEvents:
      return [.keyEvents, .paste]
    case .paste:
      return [.paste]
    }
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
  /// caller down the paste branch, which inserts the same delta at the caret.
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
        logger.debug("AX: could not read current value for append — falling back to paste")
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
  /// The pid must come from the captured target. Posting to whatever is
  /// frontmost at delivery time is what made a streaming sentence land in the
  /// app the user switched to while it was being polished.
  ///
  /// Both events are posted with **explicitly empty flags**. A `CGEvent` built
  /// from a `CGEventSource` inherits that source's modifier state, and
  /// `.combinedSessionState` includes the physical keyboard — so a keystroke
  /// posted while the owner still holds ⌘ (the review card's ⌘↩, for one)
  /// arrived tagged as a command, was routed to key-equivalent dispatch by the
  /// target, and never inserted its payload. This event carries text, so it is
  /// never a shortcut, whatever the keyboard happens to be doing.
  /// `ModifierClearance` covers the other half — the target's own idea of the
  /// modifier state, which no flag set here can correct.
  ///
  /// This is a rule for *this* strategy, not a house style:
  /// `PasteInjector.synthesizeCommandV` sets `.maskCommand` on purpose and
  /// always has, because its event is a shortcut rather than a payload. So the
  /// apps `defaultOverrideTable` forces onto `.paste` were never affected by
  /// the missing assignment — the ones that were are the `.keyEvents` terminals
  /// and any target that got here by AX writing having failed.
  private func tryCGEventInject(_ text: String, target: FocusedTarget) -> Bool {
    guard let pid = target.processID else {
      logger.debug("CGEvent: no captured target PID")
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
    keyDown.flags = []
    utf16.withUnsafeBufferPointer { ptr in
      keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: ptr.baseAddress)
    }
    keyDown.postToPid(pid)

    // Key-up event with the same payload.
    guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
      logger.debug("CGEvent: failed to create key-up event")
      return false
    }
    keyUp.flags = []
    utf16.withUnsafeBufferPointer { ptr in
      keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: ptr.baseAddress)
    }
    usleep(15_000) // 15 ms inter-event delay
    keyUp.postToPid(pid)

    logger.debug("CGEvent: posted \(utf16.count) UTF-16 code units to pid \(pid)")
    return true
  }

  // MARK: - Paste injection

  /// Inject via clipboard save → Cmd-V → clipboard restore with per-app delay,
  /// serialized against every other paste (see `PasteInjector`).
  private func tryPasteInject(_ text: String, for target: FocusedTarget) async -> InjectionResult {
    let succeeded = await paster.paste(
      text,
      toPid: target.processID,
      restoreDelayNs: pasteRestoreDelayNs(for: target.bundleID)
    )
    if succeeded {
      logSubmitted(target.bundleID, strategy: .paste)
      return .attempted(strategy: .paste)
    }
    let reason = "Nota could not prepare clipboard insertion"
    logger.error("Paste injection failed")
    return .failed(strategy: .paste, reason: reason)
  }

  // MARK: - Helpers

  private func logSubmitted(_ bundleID: String?, strategy: InjectionStrategy) {
    logger.info(
      "Submitted via \(strategy.description, privacy: .public) to bundle=\(bundleID ?? "nil", privacy: .public); target text acceptance is not observable"
    )
  }
}

// MARK: - Default override table

extension TextInjector {
  /// Known bundle IDs with forced injection strategies.
  ///
  /// Default fallback: AX → paste.
  /// An override may skip early strategies for unreliable targets.
  static let defaultOverrideTable: [String: PerAppOverride] = [
    // Electron / Chrome family — AX value fails silently.
    "com.google.Chrome":           PerAppOverride(forceStrategy: .paste, pasteRestoreDelayMs: 150),
    "com.google.Chrome.canary":    PerAppOverride(forceStrategy: .paste, pasteRestoreDelayMs: 150),
    "org.chromium.Chromium":       PerAppOverride(forceStrategy: .paste, pasteRestoreDelayMs: 150),
    "com.microsoft.edgemac":       PerAppOverride(forceStrategy: .paste, pasteRestoreDelayMs: 150),
    "com.slack.Slack":             PerAppOverride(forceStrategy: .paste, pasteRestoreDelayMs: 150),
    "com.microsoft.VSCode":        PerAppOverride(forceStrategy: .paste, pasteRestoreDelayMs: 120),
    "com.microsoft.VSCodeInsiders": PerAppOverride(forceStrategy: .paste, pasteRestoreDelayMs: 120),
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

// MARK: - PasteInjector

/// Owns the clipboard save → Cmd-V → restore sequence, strictly one at a time.
///
/// Batch delivery pasted once per session, so a snapshot and its restore could
/// never overlap. Streaming delivers sentence after sentence — the pump loops
/// straight into the next queued item and the ordered buffer releases several
/// at once — and unserialized that means the second paste snapshots the
/// clipboard while it still holds the *first* sentence's dictated text and then
/// restores that as "the user's clipboard", with the two deferred restores
/// racing to decide which. Here every step of one paste finishes, restore
/// included, before the next one starts.
///
/// Chained explicitly rather than left to actor isolation: actors are
/// reentrant, so each `await` inside a paste would otherwise readmit the next.
private actor PasteInjector {
  private let logger = Logger(subsystem: "com.xiafawu.nota", category: "dictation.injector")

  /// The most recently enqueued paste; the next one waits on it.
  private var tail: Task<Bool, Never>?

  func paste(_ text: String, toPid pid: pid_t?, restoreDelayNs: UInt64) async -> Bool {
    let previous = tail
    let logger = self.logger
    let task = Task<Bool, Never> {
      _ = await previous?.value
      return await PasteInjector.perform(
        text,
        toPid: pid,
        restoreDelayNs: restoreDelayNs,
        logger: logger
      )
    }
    tail = task
    return await task.value
  }

  private static func perform(
    _ text: String,
    toPid pid: pid_t?,
    restoreDelayNs: UInt64,
    logger: Logger
  ) async -> Bool {
    let pasteboard = NSPasteboard.general
    let snapshot = capture(pasteboard)

    pasteboard.clearContents()
    guard pasteboard.setString(text, forType: .string) else {
      logger.error("Paste: failed to set string on pasteboard")
      restore(pasteboard, from: snapshot, logger: logger)
      return false
    }

    // Brief settle for NSPasteboard to flush.
    try? await Task.sleep(nanoseconds: 10_000_000) // 10 ms
    let submitted = await synthesizeCommandV(toPid: pid, logger: logger)

    // Awaited, not deferred to a detached task: the user's clipboard has to be
    // back before the next paste snapshots it. Give a successfully submitted
    // Cmd-V its app-specific settle time; on failure restore immediately.
    if submitted {
      try? await Task.sleep(nanoseconds: restoreDelayNs)
    }
    restore(pasteboard, from: snapshot, logger: logger)
    return submitted
  }

  // MARK: - Pasteboard save/restore

  private static func capture(_ pb: NSPasteboard) -> PasteboardSnapshot {
    let items: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
      item.types.compactMap { type in
        item.data(forType: type).map { (type, $0) }
      }
    }
    return PasteboardSnapshot(items: items)
  }

  private static func restore(
    _ pb: NSPasteboard,
    from snapshot: PasteboardSnapshot,
    logger: Logger
  ) {
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

  /// Posts Cmd-V to the captured target process.
  ///
  /// The HID tap delivers to whatever is frontmost at delivery time, which is
  /// not necessarily the app the session started in.
  private static func synthesizeCommandV(toPid pid: pid_t?, logger: Logger) async -> Bool {
    let source = CGEventSource(stateID: .combinedSessionState)
    let vKey = CGKeyCode(0x09) // kVK_ANSI_V

    guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
    else {
      logger.error("Paste: failed to create CGEvent for Cmd-V")
      return false
    }

    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand

    guard let pid else {
      logger.error("Paste: no captured target PID")
      return false
    }

    keyDown.postToPid(pid)
    try? await Task.sleep(nanoseconds: 30_000_000) // 30 ms between down and up
    keyUp.postToPid(pid)

    logger.debug("Paste: posted synthetic Cmd-V")
    return true
  }
}

// MARK: - PasteboardSnapshot

private struct PasteboardSnapshot {
  /// Outer array = pasteboard items; inner = (type, data) for each item.
  let items: [[(NSPasteboard.PasteboardType, Data)]]
}
