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
    // While a run is in flight the empty pane shows the waveform/progress state;
    // otherwise the home is the preflight health dashboard.
    if model.isRunning {
      return .empty(EmptyMainState(
        isRunning: true,
        displayName: model.displayName,
        displayPath: model.displayPath,
        phase: model.phase
      ))
    }
    return .preflight(PreflightHomeState(
      result: model.preflight,
      isChecking: model.isCheckingPreflight
    ))
  }

  private var toolbarStatusPillState: ToolbarStatusPillState? {
    guard model.isRunning || model.status != "Drop audio to transcribe" else {
      return nil
    }
    // While running, mirror the live pipeline phase so the pill and the main
    // view never disagree; fall back to `status` for terminal states (Complete,
    // failures) and the brief pre-phase window.
    let text = model.isRunning && !model.phase.isEmpty ? model.phase : model.status
    return ToolbarStatusPillState(isRunning: model.isRunning, text: text)
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
        },
        onRefreshPreflight: {
          model.runPreflight(refresh: true)
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
        // Only surface the Copy/Export/Reveal menu once there's a transcript to
        // act on. Showing it disabled during processing read as a dead control.
        if !model.markdown.isEmpty || model.lastOutputURL != nil {
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
        }
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
