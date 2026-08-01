import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @ObservedObject var model: NotaModel
  /// Observed separately from `model` (which holds it as a plain `let`): the
  /// phase decision reads `liveSession.state`, so ContentView must re-render
  /// when the session publishes its own changes.
  @ObservedObject private var liveSession: LiveMeetingSession
  @StateObject private var usageProvider: UsageStatsProvider

  init(model: NotaModel) {
    self.model = model
    _liveSession = ObservedObject(wrappedValue: model.liveSession)
    let projectDir = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["NOTA_PROJECT_DIR"]
        ?? "/Users/xiafawu/Developer/Nota"
    )
    _usageProvider = StateObject(wrappedValue: UsageStatsProvider(projectDirectory: projectDir))
  }

  private enum Phase {
    case document, running, home, liveMeeting
  }

  private var phase: Phase {
    // A live session pins the pane until it settles (idle); failed keeps the
    // error banner on screen instead of silently dropping back to home.
    if liveSession.state != .idle { return .liveMeeting }
    if model.hasContent { return .document }
    if model.isRunning { return .running }
    return .home
  }

  private var navigationTitle: String {
    switch phase {
    case .running: return model.displayName
    case .liveMeeting: return "Live Meeting"
    case .document, .home: return "Nota"
    }
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
      case .liveMeeting:
        liveMeetingView.transition(Self.swapTransition)
      }
    }
    .animation(Tokens.animFast, value: phase)
    // No `.toolbarBackground(.hidden)`: the bar stays borderless at rest but
    // regains its scroll-edge material once content scrolls beneath it.
    .toolbar { toolbarContent }
    .navigationTitle(navigationTitle)
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

    // The live-session toggle lives on the toolbar in every non-running phase:
    // it is the entry point into live dictation and the stop control while one
    // is active. Hidden while the CLI pipeline runs — a live session would
    // compete for the same window state.
    if phase != .running {
      ToolbarItem(placement: .primaryAction) {
        liveMeetingButton
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
      case .running, .liveMeeting:
        EmptyView()
      }
    }
  }

  /// Record/stop toggle for live dictation. Idle or failed → start a session;
  /// recording/stopping → finish it. Disabled only while the backend is
  /// tearing the session down (the pane's Stop control is too).
  private var liveMeetingButton: some View {
    Button {
      switch liveSession.state {
      case .idle, .failed:
        model.startLiveSession()
      case .recording, .stopping:
        model.stopLiveSession()
      }
    } label: {
      switch liveSession.state {
      case .idle, .failed:
        Label("Live Meeting", systemImage: "mic")
      case .recording:
        Label("Stop Live Meeting", systemImage: "stop.fill")
      case .stopping:
        Label("Finalizing…", systemImage: "stop.fill")
      }
    }
    .help(liveMeetingButtonHelp)
    .disabled(liveSession.state == .stopping)
    .liquidGlassButton()
  }

  private var liveMeetingButtonHelp: String {
    switch liveSession.state {
    case .idle, .failed: return "Record a live meeting"
    case .recording, .stopping: return "Stop the live meeting"
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

  // MARK: - Live meeting (dictation)

  private var liveMeetingView: some View {
    MainPaneView(
      content: .liveMeeting,
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
