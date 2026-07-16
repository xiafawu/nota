import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum DictationState: Equatable {
  case disabled(reason: String)
  case idle
  case listening
  case finalizing
  case injecting
  case failed(message: String)

  var statusTitle: String {
    switch self {
    case .disabled:
      return "Permission Required"
    case .idle:
      return "Idle"
    case .listening:
      return "Listening"
    case .finalizing:
      return "Stopping"
    case .injecting:
      return "Injecting"
    case .failed:
      return "Unavailable"
    }
  }

  var symbolName: String {
    switch self {
    case .disabled:
      return "exclamationmark.shield"
    case .idle:
      return "mic"
    case .listening:
      return "mic.fill"
    case .finalizing:
      return "hourglass"
    case .injecting:
      return "arrow.down.circle"
    case .failed:
      return "exclamationmark.triangle"
    }
  }

  var isPermissionBlocked: Bool {
    if case .disabled = self { return true }
    return false
  }
}

enum HotkeyTransition {
  case began
  case ended
}

enum DictationPermission: String, CaseIterable, Identifiable {
  case accessibility
  case inputMonitoring
  case microphone

  var id: String { rawValue }

  var title: String {
    switch self {
    case .accessibility:
      return "Accessibility"
    case .inputMonitoring:
      return "Input Monitoring"
    case .microphone:
      return "Microphone"
    }
  }

  var detail: String {
    switch self {
    case .accessibility:
      return "Required for the system-wide dictation distribution path."
    case .inputMonitoring:
      return "Lets Nota observe the Fn/Globe hold-to-talk transition."
    case .microphone:
      return "Streams microphone audio only while the hotkey is held."
    }
  }
}

enum PermissionStatus: Equatable {
  case granted
  case notDetermined
  case denied
  case restricted
  case unavailable

  var isGranted: Bool {
    self == .granted
  }

  var displayName: String {
    switch self {
    case .granted:
      return "Granted"
    case .notDetermined:
      return "Not requested"
    case .denied:
      return "Not granted"
    case .restricted:
      return "Restricted"
    case .unavailable:
      return "Unavailable"
    }
  }
}

enum DictationPermissionGate {
  static func isReady(
    accessibility: PermissionStatus,
    inputMonitoring: PermissionStatus,
    microphone: PermissionStatus
  ) -> Bool {
    accessibility.isGranted && inputMonitoring.isGranted && microphone.isGranted
  }
}

struct CaptureDiagnostics: Equatable {
  let sessionID: UUID
  let startedAt: Date
  var stoppedAt: Date?
  var bufferCount: Int
  var sampleCount: Int
  var lastBufferAt: Date?

  var duration: TimeInterval? {
    guard let stoppedAt else { return nil }
    return stoppedAt.timeIntervalSince(startedAt)
  }
}

enum MicCaptureError: LocalizedError {
  case permissionDenied
  case noInputDevice
  case invalidInputFormat
  case converterUnavailable
  case engineStartFailed(String)

  var errorDescription: String? {
    switch self {
    case .permissionDenied:
      return "Microphone permission is not granted."
    case .noInputDevice:
      return "No microphone input is available."
    case .invalidInputFormat:
      return "Nota could not read a valid microphone format."
    case .converterUnavailable:
      return "Nota could not prepare the 16 kHz mono audio converter."
    case .engineStartFailed(let detail):
      return "Microphone capture could not start: " + detail
    }
  }
}

// MARK: - P3 Hybrid injection types

/// Snapshot of the OS-focused input target, captured immediately before injection.
struct FocusedTarget: Equatable {
  let bundleID: String?
  let isSecureInput: Bool
  let accessibilityElement: AXUIElement?

  /// Captures the current OS-focused UI element and its metadata.
  static func capture() -> FocusedTarget {
    guard let frontApp = NSWorkspace.shared.frontmostApplication else {
      return FocusedTarget(
        bundleID: nil,
        isSecureInput: false,
        accessibilityElement: nil
      )
    }

    let bundleID = frontApp.bundleIdentifier
    let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
    var focusedValue: CFTypeRef?
    let axResult = AXUIElementCopyAttributeValue(
      appElement,
      kAXFocusedUIElementAttribute as CFString,
      &focusedValue
    )

    let axElement: AXUIElement?
    if axResult == .success, let element = focusedValue {
      axElement = (element as! AXUIElement)
    } else {
      axElement = nil
    }

    let isSecure: Bool
    if let element = axElement {
      isSecure = element.hasSecureRole
    } else {
      isSecure = false
    }

    return FocusedTarget(
      bundleID: bundleID,
      isSecureInput: isSecure,
      accessibilityElement: axElement
    )
  }
}
extension AXUIElement {
  /// Checks whether this AX element is a secure / password text field.
  var hasSecureRole: Bool {
    var roleValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(self, kAXRoleAttribute as CFString, &roleValue) == .success,
          let role = roleValue as? String else {
      return false
    }
    if role == "AXSecureTextField" {
      return true
    }
    // Some password fields use a subrole on regular text fields.
    var subroleValue: CFTypeRef?
    if AXUIElementCopyAttributeValue(self, kAXSubroleAttribute as CFString, &subroleValue) == .success,
       let subrole = subroleValue as? String,
       subrole == "AXSecureTextField" {
      return true
    }
    return false
  }
}

/// Strategy for injecting text into the focused field.
enum InjectionStrategy: Equatable, CustomStringConvertible {
  /// AXUIElementSetAttributeValue (value or selected-text replacement).
  case accessibility
  /// Per-character CGEvent keyboard events.
  case keyEvents
  /// Clipboard save → Cmd-V → clipboard restore.
  case paste

  var description: String {
    switch self {
    case .accessibility: return "AX"
    case .keyEvents: return "CGEvent"
    case .paste: return "paste"
    }
  }
}

/// Per-bundle-ID injection override.
struct PerAppOverride: Equatable {
  /// Force a specific strategy instead of the default AX→CGEvent→paste chain.
  /// `nil` means use the default chain starting from `.accessibility`.
  let forceStrategy: InjectionStrategy?
  /// Extra delay in milliseconds before restoring the pasteboard after Cmd-V.
  /// `nil` means use the default (80 ms).
  let pasteRestoreDelayMs: UInt?
}

// MARK: - P4 Settings types

// Recognition engine selection.
enum EngineChoice: String, Codable, CaseIterable, Sendable {
  case apple
  case assemblyAIRealtime

  var label: String {
    switch self {
    case .apple: return "Apple On-Device"
    case .assemblyAIRealtime: return "AssemblyAI Realtime"
    }
  }
}

/// How dictation activation works: hold a key vs press/release to toggle.
enum ActivationMode: String, Codable, CaseIterable, Sendable {
  case hold
  case toggle
}

/// Which key triggers dictation.
struct TriggerKey: Codable, Equatable, Sendable {
  enum Kind: String, Codable, CaseIterable, Sendable { case fnGlobe, keyCode }
  var kind: Kind
  /// Key code for the `.keyCode` kind; ignored for `.fnGlobe`.
  var keyCode: UInt16?
  static let fnGlobe = TriggerKey(kind: .fnGlobe, keyCode: nil)
}

/// Swift-only dictation preferences persisted via UserDefaults.
struct DictationSettings: Codable, Equatable, Sendable {
  var engine: EngineChoice = .apple
  var trigger: TriggerKey = .fnGlobe
  var activation: ActivationMode = .hold
  var polishEnabled: Bool = false
  /// Model id from ModelRegistry for polish; nil means use the default summary model.
  var polishModelID: String? = nil
  /// Show floating HUD pill during dictation sessions.
  var showHUD: Bool = true
}
