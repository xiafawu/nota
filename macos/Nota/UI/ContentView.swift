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

  private enum Phase {
    case document, running, home
  }

  private var phase: Phase {
    if model.hasContent { return .document }
    if model.isRunning { return .running }
    return .home
  }

  /// Transient run status only: the pill never persists into the completed
  /// document view (the header carries the title there).
  private var toolbarStatusPillState: ToolbarStatusPillState? {
    guard model.isRunning else { return nil }
    let text = model.phase.isEmpty ? model.status : model.phase
    return ToolbarStatusPillState(isRunning: true, text: text)
  }

  /// Home/document swap matches the HUD show motion: fade + 8pt rise in,
  /// plain fade out.
  private static let swapTransition: AnyTransition = .asymmetric(
    insertion: .opacity.combined(with: .offset(y: Metrics.mainSwapRise)),
    removal: .opacity
  )

  var body: some View {
    ZStack {
      switch phase {
      case .document:
        documentView.transition(Self.swapTransition)
      case .running:
        runningView.transition(Self.swapTransition)
      case .home:
        homeView.transition(Self.swapTransition)
      }
    }
    .animation(Tokens.animFast, value: phase)
    // No `.toolbarBackground(.hidden)`: the bar stays borderless at rest but
    // regains its scroll-edge material once content scrolls beneath it.
    .toolbar { toolbarContent }
    .navigationTitle(phase == .running ? model.displayName : "Nota")
    .onChange(of: model.isRunning) { _, running in
      if !running {
        usageProvider.invalidateCache()
      }
    }
  }

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    if phase == .document {
      ToolbarItem(placement: .navigation) {
        Button {
          model.newTranscription()
        } label: {
          Label("Home", systemImage: "chevron.left")
        }
        .help("Back to home")
      }
    }

    ToolbarItemGroup(placement: .status) {
      if let pillState = toolbarStatusPillState {
        ToolbarStatusPill(state: pillState)
      }
    }

    ToolbarItem(placement: .primaryAction) {
      switch phase {
      case .document:
        if !model.markdown.isEmpty || model.lastOutputURL != nil {
          ShareMenu(model: model)
        }
      case .home:
        SettingsLink {
          Label("Settings", systemImage: "gearshape")
        }
        .help("Open settings")
      case .running:
        EmptyView()
      }
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
  }

  // MARK: - Home (dashboard)

  private var homeView: some View {
    HomeDashboardView(
      model: model,
      usageProvider: usageProvider
    )
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
