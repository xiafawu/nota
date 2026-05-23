import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @ObservedObject var model: NotaModel

  private var historyState: HistoryPaneState {
    HistoryPaneState(
      isRunning: model.isRunning,
      rows: model.history.map { entry in
        HistoryRowState(id: entry.id, title: entry.title, relativeDate: entry.relativeDate, tags: entry.tags)
      }
    )
  }

  private var mainContent: MainPaneContent {
    if model.hasContent {
      return .rich(DocumentRender(meta: parseDocumentMeta(model.markdown), body: model.richText))
    }
    return .empty(EmptyMainState(
      isRunning: model.isRunning,
      displayName: model.displayName,
      displayPath: model.displayPath
    ))
  }

  private var toolbarStatusPillState: ToolbarStatusPillState? {
    guard model.isRunning || model.status != "Drop audio to transcribe" else {
      return nil
    }
    return ToolbarStatusPillState(isRunning: model.isRunning, text: model.status)
  }

  var body: some View {
    NavigationSplitView {
      HistoryPaneView(
        state: historyState,
        selectedID: $model.selectedHistoryID,
        onNewTranscription: { model.newTranscription() },
        onOpen: { id in
          if let entry = model.history.first(where: { $0.id == id }) {
            model.openHistory(entry)
          }
        },
        onReveal: { id in
          NSWorkspace.shared.activateFileViewerSelecting([id])
        },
        onDelete: { id in
          if let entry = model.history.first(where: { $0.id == id }) {
            model.deleteHistory(entry)
          }
        }
      )
      .navigationSplitViewColumnWidth(min: Metrics.sidebarMin, ideal: Metrics.sidebarIdeal, max: Metrics.sidebarMax)
    } detail: {
      MainPaneView(
        content: mainContent,
        isDropTargeted: $model.isDropTargeted,
        speakerChips: $model.speakerChips,
        onDropURL: { url in
          model.accept(url)
        },
        onRename: { label, newName in
          model.renameChip(label: label, newName: newName)
        }
      )
      .navigationSplitViewColumnWidth(min: Metrics.detailMin, ideal: Metrics.detailIdeal)
    }
    .toolbar {
      ToolbarItemGroup(placement: .status) {
        if let pillState = toolbarStatusPillState {
          ToolbarStatusPill(state: pillState)
        }
      }

      ToolbarItem(placement: .primaryAction) {
        Menu {
          Section("Copy") {
            Button {
              model.copyRichText()
            } label: {
              Label("Copy Rich Text", systemImage: "doc.on.clipboard")
            }
            .liquidGlassButton()
            Button {
              model.copyMarkdown()
            } label: {
              Label("Copy Markdown", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .liquidGlassButton()
          }
          Section("Export") {
            Button {
              model.exportRichText()
            } label: {
              Label("Export Rich Text...", systemImage: "textformat")
            }
            .liquidGlassButton()
            Button {
              model.exportMarkdown()
            } label: {
              Label("Export Markdown...", systemImage: "number")
            }
            .liquidGlassButton()
          }
          Section {
            Button {
              model.revealOutput()
            } label: {
              Label("Reveal in Finder", systemImage: "finder")
            }
            .liquidGlassButton()
            .disabled(model.lastOutputURL == nil)
          }
        } label: {
          Label("Share", systemImage: "square.and.arrow.up")
        }
        .menuIndicator(.hidden)
        .help("Copy, export, or reveal transcript")
        .liquidGlassButton()
        .disabled(model.markdown.isEmpty && model.lastOutputURL == nil)
      }
    }
    .animation(Tokens.animFast, value: model.isRunning)
    .toolbarBackground(.hidden, for: .windowToolbar)
    .onChange(of: model.selectedHistoryID) { _, newValue in
      guard let newValue, let entry = model.history.first(where: { $0.id == newValue }) else {
        return
      }
      if entry.url.standardizedFileURL != model.lastOutputURL?.standardizedFileURL {
        model.openHistory(entry)
      }
    }
  }
}
