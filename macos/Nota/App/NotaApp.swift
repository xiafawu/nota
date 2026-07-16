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
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    application.activate(ignoringOtherApps: true)
    NotificationCenter.default.post(name: .notaOpenURLs, object: urls)
  }
}

extension Notification.Name {
  static let notaOpenURLs = Notification.Name("NotaOpenURLs")
}
