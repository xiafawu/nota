import AppKit
import SwiftUI

struct DictationStatusLabel: View {
  @ObservedObject var controller: DictationController
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    // Icon-only status item; the full state text lives in the accessibility
    // label and the popover, not the menu bar.
    Image(systemName: controller.state.symbolName)
      .accessibilityLabel("Nota Dictation: \(controller.state.statusTitle)")
      .onAppear {
        controller.start()
      }
      .onReceive(NotificationCenter.default.publisher(for: .notaReopenMainWindow)) { _ in
        openWindow(id: "document")
        DispatchQueue.main.async {
          NSApp.activate(ignoringOtherApps: true)
        }
      }
  }
}

struct DictationMenuBarView: View {
  @ObservedObject var controller: DictationController
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      statusHeader

      // When permissions block dictation the onboarding below is the single
      // source for that explanation; only non-permission reasons render here.
      if case .disabled(let reason) = controller.state, controller.permissions.isReady {
        Text(reason)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if !controller.permissions.isReady {
        PermissionsOnboardingView(coordinator: controller.permissions)
      } else {
        readyContent
      }

      Divider()

      VStack(alignment: .leading, spacing: 1) {
        Button("Open Nota") {
          openDocumentWindow()
        }

        Button {
          openHistoryWindow()
        } label: {
          Label(
            "Dictation History (\(controller.dictationHistory.count))",
            systemImage: "clock.arrow.circlepath"
          )
        }

        Button("Settings…") {
          openSettingsWindow()
        }

        Button("About Nota") {
          openAboutPanel()
        }

        Button("Quit Nota") {
          NSApp.terminate(nil)
        }
      }
      .buttonStyle(MenuRowButtonStyle())
      // Let the hover wash extend past the text edge while the labels stay
      // aligned with the content above.
      .padding(.horizontal, -8)
    }
    .padding(16)
    .frame(width: 360)
    .onAppear {
      controller.start()
    }
  }

  private var statusHeader: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: controller.state.symbolName)
        .font(.title2)
        .foregroundStyle(statusTint)
        .frame(width: 28)

      VStack(alignment: .leading, spacing: 3) {
        Text("Nota Dictation")
          .font(.headline)
        Text(controller.state.statusTitle)
          .font(.subheadline)
          .foregroundStyle(statusTint)
      }

      Spacer()
    }
    .accessibilityElement(children: .combine)
  }

  private var readyContent: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(dictationInstruction, systemImage: "globe")
        .font(.callout)

      if let text = controller.lastProcessedText, controller.state == .idle {
        Text("Last: \"\(text)\"")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .truncationMode(.tail)
      }

      if let warning = controller.lastPolishWarning, controller.state == .idle {
        Label(warning, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      if case .failed(let message) = controller.state {
        Label(message, systemImage: "exclamationmark.triangle")
          .font(.callout)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var statusTint: Color {
    switch controller.state {
    case .disabled:
      return .orange
    case .idle:
      return .secondary
    case .listening:
      return .green
    case .finalizing, .injecting:
      return .blue
    case .failed:
      return .red
    }
  }

  private func openDocumentWindow() {
    openWindow(id: "document")
    DispatchQueue.main.async {
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  private func openHistoryWindow() {
    openWindow(id: "dictation-history")
    DispatchQueue.main.async {
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  private func openSettingsWindow() {
    openSettings()
    DispatchQueue.main.async {
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  private func openAboutPanel() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(nil)
  }

  private var dictationInstruction: String {
    let triggerLabel: String
    switch controller.settings.trigger.kind {
    case .fnGlobe: triggerLabel = "Fn/Globe"
    case .keyCode: triggerLabel = "custom key"
    }

    switch controller.settings.activation {
    case .hold: return "Hold \(triggerLabel) to dictate"
    case .toggle: return "Press \(triggerLabel) to toggle dictation"
    }
  }
}

/// Menu-row treatment for popover actions: full-width hit target with a hover
/// wash and pressed state, matching how window-style extras present commands.
private struct MenuRowButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    MenuRowLabel(configuration: configuration)
  }

  private struct MenuRowLabel: View {
    let configuration: Configuration
    @State private var isHovering = false

    var body: some View {
      configuration.label
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : (isHovering ? 0.07 : 0)))
        )
        .onHover { hovering in
          isHovering = hovering
        }
    }
  }
}

struct PermissionsOnboardingView: View {
  @ObservedObject var coordinator: PermissionsCoordinator

  private static let permissionPollInterval: Duration = .seconds(2)

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Enable dictation")
        .font(.headline)

      Text("Nota needs all three permissions before the global hold-to-talk monitor can run.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Text("Some apps receive dictated text as a paste rather than typed keystrokes.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      ForEach(DictationPermission.allCases) { permission in
        permissionRow(permission)
      }
    }
    .accessibilityElement(children: .contain)
    // Poll while onboarding is visible so rows update after the user grants
    // access in System Settings, without a manual refresh control.
    .task {
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.permissionPollInterval)
        coordinator.refresh()
      }
    }
  }

  private func permissionRow(_ permission: DictationPermission) -> some View {
    let status = coordinator.status(for: permission)
    return HStack(alignment: .top, spacing: 8) {
      Image(systemName: status.isGranted ? "checkmark.circle.fill" : "exclamationmark.circle")
        .foregroundStyle(status.isGranted ? .green : .orange)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(permission.title)
            .font(.callout.weight(.medium))
          Spacer()
          Text(status.displayName)
            .font(.caption)
            .foregroundStyle(status.isGranted ? .green : .secondary)
        }

        Text(permission.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        if !status.isGranted {
          Button("Grant in System Settings…") {
            coordinator.request(permission)
          }
          .buttonStyle(.link)
          .padding(.top, 1)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }
}
