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
}

struct MainPaneState {
  var content: MainPaneContent
}

enum MainPaneContent {
  case empty(EmptyMainState)
  case rich(NSAttributedString)
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
