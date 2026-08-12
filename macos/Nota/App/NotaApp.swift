import AppKit
import SwiftUI

@main
struct NotaApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model = NotaModel()
  @StateObject private var dictationController: DictationController
  private let hudController: DictationHUDController
  /// The mini-recorder island (XIA-434). Built without the model and handed one
  /// by the menu-bar label's `onAppear` — `@StateObject` properties cannot be
  /// read from `init()`, and the status item is the surface that outlives every
  /// window anyway.
  private let islandController = MiniRecorderIslandController()

  init() {
    if let exitCode = runHeadlessSmokeTestIfRequested(arguments: Array(ProcessInfo.processInfo.arguments.dropFirst())) {
      exit(exitCode)
    }
    let controller = DictationController()
    self._dictationController = StateObject(wrappedValue: controller)
    self.hudController = DictationHUDController(controller: controller)
  }

  var body: some Scene {
    MenuBarExtra {
      DictationMenuBarView(
        controller: dictationController,
        model: model,
        island: islandController
      )
    } label: {
      // XIA-435: the slot stays warm after the ember dot goes out — the
      // dictation glyph plus whatever stage a record is still at. XIA-434 puts
      // the live session's ember dot and clock in front of both.
      NotaMenuBarLabel(
        controller: dictationController,
        ledger: ProcessingLedger.shared,
        model: model,
        island: islandController
      )
    }
    .menuBarExtraStyle(.window)

    WindowGroup("Nota", id: "document") {
      ContentView(model: model, dictationController: dictationController)
        .frame(minWidth: Metrics.windowMinWidth, minHeight: Metrics.windowMinHeight)
        .onOpenURL { url in
          model.accept(url)
        }
        // A completion notification's click opens the record; its Retry
        // re-runs the summary and only the summary (XIA-435).
        .onReceive(NotificationCenter.default.publisher(for: .notaOpenRecord)) { note in
          if let id = note.object as? String { model.openRecord(id: id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .notaRetryRecordSummary)) { note in
          if let id = note.object as? String { model.retrySummary(recordID: id) }
        }
        // The island's **Show** is deliberately NOT subscribed here: see
        // `AppDelegate.showLiveRecord`. A subscriber inside the WindowGroup's
        // content does not exist when there is no window, which is exactly the
        // case the island exists for.
        .environmentObject(model)
    }
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("Start Meeting") {
          model.startLiveSession()
        }
        .keyboardShortcut("n")
        .disabled(model.isRunning)

        Button("Quick Memo") {
          model.startLiveSession(kind: .memo)
        }
        .keyboardShortcut("m")
        .disabled(model.isRunning)

        Button("Transcribe File…") {
          model.chooseFile()
        }
        .keyboardShortcut("o")

        Button("Transcribe") {
          model.transcribe()
        }
        .keyboardShortcut("t")
        .disabled(model.selectedURL == nil || model.isRunning)

        Button("History") {
          model.toggleHistoryDrawer()
        }
        .keyboardShortcut("l")
      }
      #if DEBUG
      CommandGroup(after: .windowArrangement) {
        OpenTuningWindowButton()
      }
      #endif
    }

    // The standalone "Dictation History" window scene is retired (decision
    // 22): history now lives in the unified drawer (⌘L, Dictation tab) and
    // the popover's Recent dictations section; the standalone history view
    // was deleted with that lane.

    Settings {
      SettingsView(
        identifySpeakers: $model.identifySpeakers,
        skipSummary: $model.skipSummary,
        summaryDismissalBehavior: $model.summaryDismissalBehavior,
        dictationController: dictationController
      )
    }

    #if DEBUG
    Window("UI Tuning", id: "tuning-editor") {
      TuningEditor()
        .frame(minWidth: 880, minHeight: 640)
    }
    .windowResizability(.contentSize)
    #endif
  }
}

#if DEBUG
private struct OpenTuningWindowButton: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("UI Tuning…") {
      openWindow(id: "tuning-editor")
    }
    .keyboardShortcut("u", modifiers: [.command, .option])
  }
}
#endif

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var showLiveRecordObserver: NSObjectProtocol?

  func applicationDidFinishLaunching(_ notification: Notification) {
    hideFromDockUnderTests()
    ensureShareInboxExists()
    enforceSingleInstance()
    AppearanceSetting.current.apply()
    // The island's **Show** (XIA-434). Handled HERE — not inside the
    // WindowGroup's content — because the case the island exists for is
    // precisely the one where there is no `ContentView` to be subscribed: the
    // owner started a meeting, ⌘W'd the window and switched to Zoom. A
    // subscriber inside the scene's content does not exist then, so Show did
    // nothing at all: no activation, no window, no error.
    //
    // This is the one place Nota is brought forward on that path, and it is an
    // explicit press on a button labelled Show. Nothing about *presenting* the
    // island activates the app, which is the rule that matters.
    showLiveRecordObserver = NotificationCenter.default.addObserver(
      forName: .notaShowLiveRecord,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.showLiveRecord() }
    }
  }

  /// Bring the document window forward, creating it when the WindowGroup has
  /// released its last one — the same fallback `applicationShouldHandleReopen`
  /// already owed, and for the same reason.
  @MainActor
  private func showLiveRecord() {
    NSApp.activate(ignoringOtherApps: true)
    let document = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("document") == true }
      ?? NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeMain }
    guard let window = document else {
      // `DictationStatusLabel` — which lives in the menu-bar label and is
      // therefore alive for the whole life of the process — answers this with
      // SwiftUI's `openWindow`.
      NotificationCenter.default.post(name: .notaReopenMainWindow, object: nil)
      return
    }
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
  }

  /// Create `~/.nota/inbox` so the share extension can stage into it.
  ///
  /// The extension is sandboxed and its entitlement grants `/.nota/inbox/` only
  /// — deliberately not `/.nota/`, which would expose the API-key file
  /// (`~/.nota/config`) and `speakers.json` to a sandboxed process. Creating the
  /// intermediate `~/.nota` is therefore a write to `~/` that the extension is
  /// not permitted to make, and on a machine where Nota has never written any
  /// state (keys exported in the shell, Settings never opened, CLI never run)
  /// the extension's own `createDirectory` fails with EACCES and the first share
  /// dies. This app is unsandboxed, so the same call always succeeds here.
  ///
  /// Runs before `enforceSingleInstance()` so a duplicate launch still repairs
  /// the directory on its way out. Best-effort: a failure must not block launch,
  /// and the install-time `mkdir -p` in scripts/deploy-macos-app.sh covers the
  /// case where the extension runs before this app has ever been launched.
  private func ensureShareInboxExists() {
    guard let inbox = try? notaInboxDirectory() else { return }
    try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
  }

  /// xcodebuild launches this app as the unit-test host; a regular activation
  /// policy gives every test run a Dock icon (and a lingering ghost one if a
  /// spawned child outlives the host). Accessory keeps test hosts out of the
  /// Dock entirely while still allowing windows for hosted UI tests.
  private func hideFromDockUnderTests() {
    let env = ProcessInfo.processInfo.environment
    guard env["XCTestConfigurationFilePath"] != nil
      || env["XCTestBundlePath"] != nil
      || env["XCTestSessionIdentifier"] != nil else { return }
    NSApp.setActivationPolicy(.accessory)
  }

  /// Quit immediately if another Nota with the same bundle id is already
  /// running (e.g. a stale DerivedData copy vs /Applications). The OLDER
  /// instance wins: it already owns the CGEvent tap and TCC grants; two live
  /// instances would each inject text on every dictation. Set
  /// NOTA_ALLOW_MULTI=1 to bypass for debugging.
  private func enforceSingleInstance() {
    // Never enforce inside a unit-test host: xcodebuild launches this app as
    // the test harness while the deployed copy may be running — terminating
    // here kills the runner before it connects ("early unexpected exit").
    let env = ProcessInfo.processInfo.environment
    guard env["XCTestConfigurationFilePath"] == nil,
          env["XCTestBundlePath"] == nil,
          env["NOTA_ALLOW_MULTI"] != "1",
          let bundleID = Bundle.main.bundleIdentifier else { return }

    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
      .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }

    guard let survivor = others.first else { return }
    NSLog("Nota: another instance is already running (pid %d, %@) — quitting this one",
          survivor.processIdentifier,
          survivor.bundleURL?.path ?? "unknown path")
    survivor.activate()
    NSApp.terminate(nil)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  /// ⌘Q with work in flight asks **once**, and only then (XIA-435).
  ///
  /// The honest thing it has to say is that nothing is at risk: the audio and
  /// the transcript are already on disk under the record either way. What
  /// quitting costs is the summary, and the next launch's sweep leaves such a
  /// record reading "Interrupted · transcript saved" with its Retry — so the
  /// answer to "what happens if I say yes" is written down in the place the
  /// owner will next look.
  ///
  /// The decision and its wording are `QuitPrompt.decide`, which a test can
  /// reach; this is the alert that shows it. `ProcessingLedger.shared` is why
  /// it is a singleton — the delegate has no route to `NotaModel`.
  /// Quitting also **kills the summary child**, so the prompt's promise is
  /// true. A Foundation child survives its parent: left alone the orphan either
  /// finishes (and the record is not "unsummarized" as the alert said) or is
  /// still running when the owner relaunches, at which point the launch sweep
  /// offers a Retry that spawns a *second* `nota history summarize <id>` —
  /// a second paid model call, and two uncoordinated writers on one record's
  /// JSON. The in-memory ledger cannot see the orphan; the quit destroyed it.
  /// See `RunningSummaries`.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let ask = QuitPrompt.decide(inFlight: ProcessingLedger.shared.inFlight) else {
      RunningSummaries.shared.terminateAll()
      return .terminateNow
    }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = ask.messageText
    alert.informativeText = ask.informativeText
    alert.addButton(withTitle: ask.quitButtonTitle)
    alert.addButton(withTitle: ask.cancelButtonTitle)
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
    // "Quit Anyway" — leave the record exactly as the prompt describes:
    // unsummarized, with its audio and transcript on disk, at `summarizing`,
    // which is the state the next launch's sweep turns into
    // "Interrupted · transcript saved" plus its Retry.
    RunningSummaries.shared.terminateAll()
    return .terminateNow
  }

  /// Dock-icon click with no visible windows must bring the main window back:
  /// the MenuBarExtra scene keeps the app alive after the last window closes,
  /// and AppKit's default reopen does nothing for a retained SwiftUI window.
  /// When the WindowGroup has released its last window entirely, the status
  /// label asks SwiftUI's `openWindow` environment to create it again.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    guard !flag else {
      sender.activate(ignoringOtherApps: true)
      return true
    }
    let main = sender.windows.first { $0.identifier?.rawValue.hasPrefix("document") == true }
      ?? sender.windows.first { !($0 is NSPanel) && $0.canBecomeMain }
    if let window = main {
      if window.isMiniaturized { window.deminiaturize(nil) }
      window.makeKeyAndOrderFront(nil)
      sender.activate(ignoringOtherApps: true)
    } else {
      NotificationCenter.default.post(name: .notaReopenMainWindow, object: nil)
    }
    return false
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    application.activate(ignoringOtherApps: true)
    NotificationCenter.default.post(name: .notaOpenURLs, object: urls)
  }
}

extension Notification.Name {
  static let notaOpenURLs = Notification.Name("NotaOpenURLs")
  static let notaReopenMainWindow = Notification.Name("NotaReopenMainWindow")
  /// The popover's "Show all N in Nota →" (decision 26): open the main window
  /// and land the history drawer on the Dictation tab.
  static let notaShowHistoryDrawer = Notification.Name("NotaShowHistoryDrawer")
}
