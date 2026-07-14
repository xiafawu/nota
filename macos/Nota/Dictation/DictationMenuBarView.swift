import AppKit
import SwiftUI

struct DictationStatusLabel: View {
  @ObservedObject var controller: DictationController

  var body: some View {
    Label {
      Text("Nota Dictation — \(controller.state.statusTitle)")
    } icon: {
      Image(systemName: controller.state.symbolName)
    }
    .accessibilityLabel("Nota Dictation: \(controller.state.statusTitle)")
    .onAppear {
      controller.start()
    }
  }
}

struct DictationMenuBarView: View {
  @ObservedObject var controller: DictationController
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      statusHeader

      if case .disabled(let reason) = controller.state {
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

      Button {
        openDocumentWindow()
      } label: {
        Label("Open Nota", systemImage: "rectangle.on.rectangle")
      }

      Button {
        NSApp.terminate(nil)
      } label: {
        Label("Quit Nota", systemImage: "power")
      }
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
      Label("Hold Fn/Globe to listen", systemImage: "globe")
        .font(.callout)

      if case .failed(let message) = controller.state {
        Label(message, systemImage: "exclamationmark.triangle")
          .font(.callout)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let diagnostics = controller.lastCaptureDiagnostics {
        Text(diagnosticsSummary(diagnostics))
          .font(.caption)
          .foregroundStyle(.secondary)
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

  private func diagnosticsSummary(_ diagnostics: CaptureDiagnostics) -> String {
    let duration = diagnostics.duration.map { String(format: "%.2fs", $0) } ?? "active"
    return "Last capture: \(diagnostics.bufferCount) PCM buffers, \(diagnostics.sampleCount) samples, \(duration)"
  }

  private func openDocumentWindow() {
    openWindow(id: "document")
    DispatchQueue.main.async {
      NSApp.activate(ignoringOtherApps: true)
    }
  }
}

struct PermissionsOnboardingView: View {
  @ObservedObject var coordinator: PermissionsCoordinator

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Enable dictation")
        .font(.headline)

      Text("Nota needs all three permissions before the global hold-to-talk monitor can run.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Text("System-wide injection is reserved for a Developer ID signed, hardened-runtime, notarized direct-download build. This ad-hoc development build is capture-only.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      ForEach(DictationPermission.allCases) { permission in
        permissionRow(permission)
      }

      Button {
        coordinator.refresh()
      } label: {
        Label("Refresh Permissions", systemImage: "arrow.clockwise")
      }
      .buttonStyle(.bordered)
      .padding(.top, 2)
    }
    .accessibilityElement(children: .contain)
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
          Button("Open Settings") {
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
