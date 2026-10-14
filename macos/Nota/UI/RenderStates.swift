import AppKit
import Foundation

struct MainPaneState {
  var content: MainPaneContent
}

enum MainPaneContent {
  case empty(EmptyMainState)
  case rich(DocumentRender)
  /// Live dictation session rendered against `NotaModel.liveSession`; the
  /// content case carries no state — the pane reads the session from the
  /// model's environment object.
  case liveMeeting
}

/// A rendered document: parsed header metadata (nil for legacy/headerless
/// content) plus the rich-text body that scrolls beneath the SwiftUI header.
struct DocumentRender {
  let meta: DocMeta?
  let body: NSAttributedString
}

struct EmptyMainState {
  var isRunning: Bool
  var displayName: String
  var displayPath: String
  /// Live stage label shown while running (e.g. "Transcribing…"). Empty when idle.
  var phase: String = ""
}

struct ToolbarStatusPillState {
  var isRunning: Bool
  var text: String

  /// What the tooltip and the accessibility label say: the **whole** message,
  /// never the one truncated line the toolbar has room for (P-C11). This pill
  /// is the only surface a handed-off background failure can reach — the record
  /// wrote no markdown, so there is no drawer row and no document — and a
  /// fragment of the only account of that failure is not an account of it.
  var helpText: String { text }

  /// A running phase label ("Transcribing…") is short and reads from its head;
  /// a failure notice is a sentence, and middle truncation ate the informative
  /// half of it. Same reasoning as the stale-summary banner (P-D8).
  var truncatesFromTail: Bool { !isRunning }
}

/// One alert the window shows on the owner's behalf: a verb that did not do
/// what was asked, said once, in plain words, with OK as the only answer
/// (FB-1). `ContentView` mounts it a single time for the whole window, because
/// the surface that asked can be gone by the time the answer exists — a
/// discard takes its own pane down.
///
/// Written per action and never on a tick: `NotaModel` is observed by the
/// whole window and by the island controller, so a value that changed on a
/// timer would re-render both at that rate (the XIA-432 trap).
struct OwnerAlert: Equatable {
  let title: String
  let message: String
}
