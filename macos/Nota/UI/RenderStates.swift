import AppKit
import Foundation

struct HistoryPaneState {
  var isRunning: Bool
  var rows: [HistoryRowState]
}

struct HistoryRowState: Identifiable, Hashable {
  let id: HistoryEntry.ID
  let title: String
  let relativeDate: String
  let tags: [String]
}

struct MainPaneState {
  var content: MainPaneContent
}

enum MainPaneContent {
  case empty(EmptyMainState)
  case preflight(PreflightHomeState)
  case rich(DocumentRender)
}

/// Home state when no document is open: the preflight result (nil until the
/// first check returns) plus whether a check is in flight.
struct PreflightHomeState {
  var result: PreflightResult?
  var isChecking: Bool
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
}

struct ToolbarStatusPillState {
  var isRunning: Bool
  var text: String
}
