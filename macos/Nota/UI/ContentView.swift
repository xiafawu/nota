import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @ObservedObject var model: NotaModel
  @StateObject private var usageProvider: UsageStatsProvider

  init(model: NotaModel) {
    self.model = model
    let projectDir = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["NOTA_PROJECT_DIR"]
        ?? "/Users/xiafawu/Developer/Nota"
    )
    _usageProvider = StateObject(wrappedValue: UsageStatsProvider(projectDirectory: projectDir))
  }

  private var toolbarStatusPillState: ToolbarStatusPillState? {
    guard model.isRunning || model.status != "Drop audio to transcribe" else {
      return nil
    }
    let text = model.isRunning && !model.phase.isEmpty ? model.phase : model.status
    return ToolbarStatusPillState(isRunning: model.isRunning, text: text)
  }

  var body: some View {
    if model.hasContent {
      documentView
    } else if model.isRunning {
      runningView
    } else {
      homeView
    }
  }

  // MARK: - Document (rich content)

  private var documentView: some View {
    MainPaneView(
      content: .rich(DocumentRender(
        meta: parseDocumentMeta(model.markdown),
        body: model.richText
      )),
      isDropTargeted: $model.isDropTargeted,
      speakerChips: $model.speakerChips,
      onDropURL: { url in model.accept(url) },
      onRename: { label, newName in model.renameChip(label: label, newName: newName) },
      onRefreshPreflight: { model.runPreflight(refresh: true) }
    )
    .toolbar {
      ToolbarItem(placement: .navigation) {
        Button {
          model.newTranscription()
        } label: {
          Label("Home", systemImage: "chevron.left")
        }
        .help("Back to home")
      }

      ToolbarItemGroup(placement: .status) {
        if let pillState = toolbarStatusPillState {
          ToolbarStatusPill(state: pillState)
        }
      }

      ToolbarItem(placement: .primaryAction) {
        if !model.markdown.isEmpty || model.lastOutputURL != nil {
          ShareMenu(model: model)
        }
      }
    }
    .toolbarBackground(.hidden, for: .windowToolbar)
    .onChange(of: model.isRunning) { _, running in
      if !running {
        usageProvider.invalidateCache()
      }
    }
  }

  // MARK: - Running (progress)

  private var runningView: some View {
    MainPaneView(
      content: .empty(EmptyMainState(
        isRunning: true,
        displayName: model.displayName,
        displayPath: model.displayPath,
        phase: model.phase
      )),
      isDropTargeted: $model.isDropTargeted,
      speakerChips: $model.speakerChips,
      onDropURL: { url in model.accept(url) },
      onRename: { label, newName in model.renameChip(label: label, newName: newName) },
      onRefreshPreflight: { model.runPreflight(refresh: true) }
    )
    .toolbar {
      ToolbarItemGroup(placement: .status) {
        if let pillState = toolbarStatusPillState {
          ToolbarStatusPill(state: pillState)
        }
      }
    }
    .toolbarBackground(.hidden, for: .windowToolbar)
    .animation(Tokens.animFast, value: model.isRunning)
    .onChange(of: model.isRunning) { _, running in
      if !running {
        usageProvider.invalidateCache()
      }
    }
  }

  // MARK: - Home (dashboard)

  private var homeView: some View {
    HomeDashboardView(
      model: model,
      usageProvider: usageProvider
    )
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          model.newTranscription()
        } label: {
          Label("New Transcription", systemImage: "plus")
        }
        .help("Start a new transcription")
      }

      ToolbarItemGroup(placement: .status) {
        if let pillState = toolbarStatusPillState {
          ToolbarStatusPill(state: pillState)
        }
      }
    }
    .toolbarBackground(.hidden, for: .windowToolbar)
    .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.isDropTargeted) { providers in
      guard let provider = providers.first else { return false }
      provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
        let url: URL?
        if let data = item as? Data {
          url = URL(dataRepresentation: data, relativeTo: nil)
        } else if let nsURL = item as? NSURL {
          url = nsURL as URL
        } else {
          url = nil
        }
        if let url {
          Task { @MainActor in model.accept(url) }
        }
      }
      return true
    }
    .animation(Tokens.animFast, value: model.isRunning)
    .onChange(of: model.isRunning) { _, running in
      if !running {
        usageProvider.invalidateCache()
      }
    }
  }
}

// MARK: - Share menu (extracted for reuse)

private struct ShareMenu: View {
  @ObservedObject var model: NotaModel

  var body: some View {
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
