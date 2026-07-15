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
