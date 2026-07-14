import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation

@MainActor
final class PermissionsCoordinator: ObservableObject {
  @Published private(set) var accessibility: PermissionStatus = .denied
  @Published private(set) var inputMonitoring: PermissionStatus = .denied
  @Published private(set) var microphone: PermissionStatus = .notDetermined

  var onStatusChange: (() -> Void)?

  init() {
    refresh()
  }

  var isReady: Bool {
    DictationPermissionGate.isReady(
      accessibility: accessibility,
      inputMonitoring: inputMonitoring,
      microphone: microphone
    )
  }

  var blockingReason: String {
    let missing = DictationPermission.allCases.compactMap { permission -> String? in
      guard !status(for: permission).isGranted else { return nil }
      return permission.title
    }

    guard !missing.isEmpty else { return "" }
    let joined: String
    if missing.count == 1 {
      joined = missing[0]
    } else {
      joined = missing.dropLast().joined(separator: ", ") + " and " + missing.last!
    }
    return "Dictation is disabled until " + joined + " permission is granted."
  }

  func status(for permission: DictationPermission) -> PermissionStatus {
    switch permission {
    case .accessibility:
      return accessibility
    case .inputMonitoring:
      return inputMonitoring
    case .microphone:
      return microphone
    }
  }

  func refresh() {
    let nextAccessibility = AXIsProcessTrustedWithOptions(
      [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
    ) ? PermissionStatus.granted : .denied

    let nextInputMonitoring = CGPreflightListenEventAccess()
      ? PermissionStatus.granted
      : .denied

    let nextMicrophone: PermissionStatus
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      nextMicrophone = .granted
    case .notDetermined:
      nextMicrophone = .notDetermined
    case .denied:
      nextMicrophone = .denied
    case .restricted:
      nextMicrophone = .restricted
    @unknown default:
      nextMicrophone = .unavailable
    }

    accessibility = nextAccessibility
    inputMonitoring = nextInputMonitoring
    microphone = nextMicrophone
    onStatusChange?()
  }

  func request(_ permission: DictationPermission) {
    switch permission {
    case .accessibility:
      _ = AXIsProcessTrustedWithOptions(
        [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
      )
      openSettings(for: permission)

    case .inputMonitoring:
      _ = CGRequestListenEventAccess()
      openSettings(for: permission)

    case .microphone:
      if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
          Task { @MainActor in
            self?.refresh()
          }
        }
      }
      openSettings(for: permission)
    }
  }

  func openSettings(for permission: DictationPermission) {
    guard let url = URL(string: permission.settingsURL) else { return }
    _ = NSWorkspace.shared.open(url)
  }
}

private extension DictationPermission {
  var settingsURL: String {
    switch self {
    case .accessibility:
      return "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
    case .inputMonitoring:
      return "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent"
    case .microphone:
      return "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
    }
  }
}
