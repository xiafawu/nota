#if DEBUG
import AppKit
import Foundation

enum PreviewMocks {
  static let historyEmpty = HistoryPaneState(isRunning: false, rows: [])

  static let historyRowsFew = HistoryPaneState(
    isRunning: false,
    rows: [
      HistoryRowState(
        id: URL(string: "file:///mock/team-sync.summary.md")!,
        title: "Team sync",
        relativeDate: "2h"
      ),
      HistoryRowState(
        id: URL(string: "file:///mock/coffee-chat.summary.md")!,
        title: "Coffee chat",
        relativeDate: "1d"
      ),
      HistoryRowState(
        id: URL(string: "file:///mock/standup.summary.md")!,
        title: "Standup",
        relativeDate: "3d"
      )
    ]
  )

  static let historyRowsRunning = HistoryPaneState(
    isRunning: true,
    rows: historyRowsFew.rows
  )

  static let emptyMainIdle = EmptyMainState(
    isRunning: false,
    displayName: "Drop Audio",
    displayPath: "MP3, M4A, WAV, CAF, QTA, MOV, MP4"
  )

  static let emptyMainRunning = EmptyMainState(
    isRunning: true,
    displayName: "team-sync.m4a",
    displayPath: "/Users/sample/team-sync.m4a"
  )

  static let toolbarStatusIdle = ToolbarStatusPillState(
    isRunning: false,
    text: "Copied Markdown"
  )

  static let toolbarStatusRunning = ToolbarStatusPillState(
    isRunning: true,
    text: "Transcribing audio…"
  )

  static let sampleRichText: NSAttributedString = renderMarkdownAsRichText("""
  # Sample Transcript

  ## Summary

  Preview-only sample showing the markdown rendering pipeline used by the result pane.

  ## Key Topics

  - Onboarding the new team member
  - Q4 roadmap alignment
  - AI-UIconfig-skill apply progress

  ## Decisions

  - **Approved** preserve-mode refactor of `NotaApp.swift`.
  - Defer writeback service to step 7.

  ## Action Items

  - Land per-step commits
  - Verify no visual regressions against `iter-final.png`

  [00:00] **Alex:** Welcome to the call.
  [00:14] **Sam:** Good to be here, let's get started.
  """)
}
#endif
