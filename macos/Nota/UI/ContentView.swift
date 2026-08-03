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
    .overlay {
      if model.isHistoryDrawerPresented {
        historyDrawerLayer
          .transition(.move(edge: .trailing).combined(with: .opacity))
      }
    }
    .animation(Tokens.animFast, value: model.isHistoryDrawerPresented)
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

  /// S3 drawer host: an invisible full-window layer dismisses on click-outside
  /// (the drawer floats above it); Escape dismisses via a hidden cancel
  /// button. The drawer itself is a plain SwiftUI view — no NSPanel.
  private var historyDrawerLayer: some View {
    ZStack(alignment: .topTrailing) {
      Color.black.opacity(0.0001)
        .contentShape(Rectangle())
        .onTapGesture { model.isHistoryDrawerPresented = false }
        .ignoresSafeArea()

      HistoryDrawerView(model: model) {
        model.isHistoryDrawerPresented = false
      }
      .padding(CraftTokens.spacing16)
      .zIndex(1)

      // Escape (cancelAction) dismisses while the drawer is up.
      Button("") { model.isHistoryDrawerPresented = false }
        .keyboardShortcut(.cancelAction)
        .hidden()
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
      if phase == .home {
        // Stub for XIA-400: the quiet health pill. Green "Ready" when healthy;
        // the real preflight-fed pill replaces this in impl 4.
        HomeReadyPill()
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

    // S3: the drawer opens from the toolbar in the home AND document phases.
    if phase == .home || phase == .document {
      ToolbarItem(placement: .primaryAction) {
        Button {
          model.toggleHistoryDrawer()
        } label: {
          Label("History", systemImage: "clock")
        }
        .help("History (⌘L)")
        .liquidGlassButton()
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
      HomeDashboardView.handleDrop(providers: providers, model: model)
    }
  }
}

/// The quiet health-pill slot on the home toolbar: green dot + "Ready".
/// Placeholder for XIA-400, which feeds it from the preflight model and adds
/// the glass popover.
private struct HomeReadyPill: View {
  var body: some View {
    HStack(spacing: Metrics.statusHStackSpacing) {
      Circle()
        .fill(.green)
        .frame(width: 7, height: 7)
      Text("Ready")
        .font(Tokens.statusFont)
    }
    .padding(.horizontal, Metrics.statusPillH)
    .padding(.vertical, Metrics.statusPillV)
    .liquidGlass(.regular, in: .capsule)
    .help("All systems ready")
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
