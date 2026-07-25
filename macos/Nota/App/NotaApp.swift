import AppKit
import SwiftUI

@main
struct NotaApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model = NotaModel()
  @StateObject private var dictationController: DictationController
  private let hudController: DictationHUDController

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
      DictationMenuBarView(controller: dictationController)
    } label: {
      DictationStatusLabel(controller: dictationController)
    }
    .menuBarExtraStyle(.window)

    WindowGroup("Nota", id: "document") {
      ContentView(model: model)
        .frame(minWidth: Metrics.windowMinWidth, minHeight: Metrics.windowMinHeight)
        .onOpenURL { url in
          model.accept(url)
        }
        .environmentObject(model)
    }
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("New Transcription") {
          model.newTranscription()
        }
        .keyboardShortcut("n")
        .disabled(model.isRunning)

        Button("Open Audio...") {
          model.chooseFile()
        }
        .keyboardShortcut("o")

        Button("Transcribe") {
          model.transcribe()
        }
        .keyboardShortcut("t")
        .disabled(model.selectedURL == nil || model.isRunning)
      }
      #if DEBUG
      CommandGroup(after: .windowArrangement) {
        OpenTuningWindowButton()
      }
      #endif
    }

    Settings {
      SettingsView(
        identifySpeakers: $model.identifySpeakers,
        skipSummary: $model.skipSummary,
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
  func applicationDidFinishLaunching(_ notification: Notification) {
    hideFromDockUnderTests()
    ensureShareInboxExists()
    enforceSingleInstance()
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

  /// Dock-icon click with no visible windows must bring the main window back:
  /// the MenuBarExtra scene keeps the app alive after the last window closes,
  /// and AppKit's default reopen does nothing for a retained SwiftUI window.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    guard !flag else { return true }
    let main = sender.windows.first { $0.identifier?.rawValue.hasPrefix("document") == true }
      ?? sender.windows.first { !($0 is NSPanel) && $0.canBecomeMain }
    guard let window = main else { return true }
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    sender.activate(ignoringOtherApps: true)
    return false
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    application.activate(ignoringOtherApps: true)
    NotificationCenter.default.post(name: .notaOpenURLs, object: urls)
  }
}

extension Notification.Name {
  static let notaOpenURLs = Notification.Name("NotaOpenURLs")
}
