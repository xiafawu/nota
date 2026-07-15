import AppKit
import CoreGraphics
import Foundation
import os

// MARK: - TextInjector

/// Paste-only text injection: clipboard save → set text → synthetic Cmd-V → clipboard restore.
///
/// Uses `NSPasteboard` for clipboard manipulation and `CGEvent` for the Cmd-V keystroke.
/// Does NOT use Accessibility AX APIs or CGEvent keystroke-by-keystroke typing (those are P3).
final class TextInjector {
  private let logger = Logger(subsystem: "com.xiafawu.nota", category: "dictation.injector")

  /// Injects `text` at the current keyboard focus using pasteboard + synthetic Cmd-V.
  ///
  /// Saves the full general pasteboard (all types with data), sets the string, posts Cmd-V,
  /// then restores the original pasteboard contents in a `defer` block.
  func inject(_ text: String) {
    guard !text.isEmpty else {
      logger.info("TextInjector: skipping injection — empty text")
      return
    }

    let pasteboard = NSPasteboard.general
    let snapshot = capturePasteboard(pasteboard)

    defer {
      // Small delay so the target app has time to process Cmd-V
      Thread.sleep(forTimeInterval: 0.08)
      restorePasteboard(pasteboard, from: snapshot)
    }

    // Set text on clipboard
    pasteboard.clearContents()
    guard pasteboard.setString(text, forType: .string) else {
      logger.error("TextInjector: failed to set string on pasteboard")
      return
    }

    // Brief settle for NSPasteboard to flush
    Thread.sleep(forTimeInterval: 0.01)

    // Synthetic Cmd-V
    synthesizeCommandV()
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
  }

  // MARK: - Synthetic Cmd-V

  private func synthesizeCommandV() {
    let source = CGEventSource(stateID: .combinedSessionState)
    let vKey = CGKeyCode(0x09) // kVK_ANSI_V

    guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
    else {
      logger.error("TextInjector: failed to create CGEvent for Cmd-V")
      return
    }

    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand

    keyDown.post(tap: .cghidEventTap)
    usleep(30_000) // 30 ms between down and up
    keyUp.post(tap: .cghidEventTap)

    logger.debug("TextInjector: posted synthetic Cmd-V")
  }
}

// MARK: - PasteboardSnapshot

/// Captures all pasteboard items with their declared types and data,
/// preserving the multi-item structure for accurate restoration.
private struct PasteboardSnapshot {
  /// Outer array = pasteboard items; inner = (type, data) for each item.
  let items: [[(NSPasteboard.PasteboardType, Data)]]
}
