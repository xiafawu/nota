import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @ObservedObject var model: NotaModel
  /// The dictation controller, passed through for the history drawer's
  /// Dictation tab (decision 16) and the popover bridge (decision 26).
  @ObservedObject private var dictationController: DictationController
  /// Observed separately from `model` (which holds it as a plain `let`): the
  /// phase decision reads `liveSession.state`, so ContentView must re-render
  /// when the session publishes its own changes.
  @ObservedObject private var liveSession: LiveMeetingSession
  @StateObject private var usageProvider: UsageStatsProvider
  /// Shared by the toolbar pill and the home cards: a gated card click opens
  /// the same health popover. It is only ever raised through
  /// `DeferredPresentation.open` — the popover is anchored in a toolbar item,
  /// and setting this inline presents it inside the toolbar's layout pass.
  @State private var isHealthPopoverPresented = false
  /// The drawer's slide-over motion collapses to a plain fade under Reduce
  /// Motion (XIA-404 glass audit).
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(model: NotaModel, dictationController: DictationController) {
    self.model = model
    self.dictationController = dictationController
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
    case .liveMeeting: return model.activeSessionKind == .memo ? "Memo" : "Live Meeting"
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
          .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
      }
      if model.isSummaryRailPresented {
        // Decision 1: the rail is a SwiftUI overlay in the window's ZStack —
        // same mechanism as the drawer, not a Window scene or NSPanel. It
        // rises from the bottom-right corner (its own button) rather than
        // sliding from the opposite side. Dismissal (click-outside, Escape,
        // Close) runs the decision-13 draft policy inside the rail.
        SummaryRailView(model: model)
          .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
          .zIndex(2)
      }
    }
    .animation(Tokens.animFast, value: model.isHistoryDrawerPresented)
    .animation(Tokens.animFast, value: model.isSummaryRailPresented)
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

      HistoryDrawerView(
        model: model,
        dictationController: dictationController
      ) {
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
        HealthPillView(
          result: model.preflight,
          isChecking: model.isCheckingPreflight,
          onRefresh: { model.runPreflight(refresh: true) },
          isPresented: $isHealthPopoverPresented
        )
      }
    }

    ToolbarItem(placement: .primaryAction) {
      switch phase {
      case .home:
        SettingsLink {
          Label("Settings", systemImage: "gearshape")
        }
        .help("Open settings")
      case .document, .running, .liveMeeting:
        // Decision 11 (ADR 0005): per-transcript actions live in the content
        // area's bottom-right cluster, not the toolbar. The toolbar's
        // trailing edge holds global chrome only: History + Settings.
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
      onAcceptSuggestion: { label in model.acceptSuggestion(label: label) },
      onDismissSuggestion: { label in model.dismissSuggestion(label: label) }
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
      onRename: { label, newName in model.renameChip(label: label, newName: newName) }
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
      onAcceptSuggestion: { label in model.acceptSuggestion(label: label) },
      onDismissSuggestion: { label in model.dismissSuggestion(label: label) }
    )
  }

  // MARK: - Home (dashboard)

  private var homeView: some View {
    HomeDashboardView(
      model: model,
      usageProvider: usageProvider,
      onOpenHealthPopover: { DeferredPresentation.open($isHealthPopoverPresented) }
    )
    .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.isDropTargeted) { providers in
      HomeDashboardView.handleDrop(providers: providers, model: model)
    }
  }
}

// MARK: - Share menu (extracted for reuse)
// Internal (not private): decision 11 moves Share out of the toolbar into the
// bottom-right local cluster beside Summary (MainPaneView); the view itself
// is reused as-is, only its host changes.

struct ShareMenu: View {
  /// Where this menu is being hosted. The two hosts want different chrome and
  /// the difference is not cosmetic: in a **toolbar**, macOS 26 draws the
  /// Liquid Glass capsule around the item itself, so the menu supplies only a
  /// label. In the **local cluster** it is a free-floating control over the
  /// content and has to draw its own glass — as a circle, icon-only, matching
  /// the Summary button beside it (ADR 0005).
  ///
  /// This enum exists because moving the view between hosts silently changed
  /// what its own `.liquidGlassButton()` did: harmless under a toolbar that
  /// was already drawing glass, a label-width capsule once it wasn't.
  enum Style {
    case toolbar
    case localCluster
  }

  @ObservedObject var model: NotaModel
  var style: Style = .toolbar

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
      switch style {
      case .toolbar:
        Label("Share", systemImage: "square.and.arrow.up")
      case .localCluster:
        Image(systemName: "square.and.arrow.up")
          .font(.system(size: 14, weight: .semibold))
          .frame(
            width: MainPaneView.clusterGlyphSize,
            height: MainPaneView.clusterGlyphSize
          )
      }
    }
    .menuIndicator(.hidden)
    .help("Copy, export, or reveal transcript")
    .accessibilityLabel("Share")
    .modifier(ShareMenuChrome(style: style))
  }
}

/// Applies the chrome each host needs. Kept as a modifier rather than a
/// ternary because the two arms return different view types.
private struct ShareMenuChrome: ViewModifier {
  let style: ShareMenu.Style

  func body(content: Content) -> some View {
    switch style {
    case .toolbar:
      // The toolbar already draws the glass capsule around its items on
      // macOS 26; a second one here is the doubled outline CLAUDE.md warns
      // about. The style stays for the reduce-transparency fallback.
      content.liquidGlassButton()
    case .localCluster:
      content.localClusterButton()
    }
  }
}
