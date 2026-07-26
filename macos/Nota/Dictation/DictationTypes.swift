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
      return "Working…"
    case .injecting:
      return "Inserting…"
    case .failed:
      return "Failed — Try Again"
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
      return "ellipsis.circle"
    case .injecting:
      return "text.insert"
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

/// Snapshot of the OS-focused input target, captured immediately before
/// injection (batch delivery) or at session start (streaming delivery).
struct FocusedTarget: Equatable {
  let bundleID: String?
  let isSecureInput: Bool
  let accessibilityElement: AXUIElement?
  /// The process that owned focus at capture time.
  ///
  /// Load-bearing, not diagnostic: CGEvent typing and the synthetic Cmd-V are
  /// *posted* to this pid. Without it they go to whatever is frontmost when the
  /// event is delivered, which for a streaming session is whatever the user
  /// switched to while the sentence was being polished.
  var processID: pid_t?

  /// How long an AX round-trip into the target app may take before it is
  /// abandoned. The default is 6 s, and every one of these calls sits between
  /// the user and their text.
  private static let axMessagingTimeout: Float = 0.25

  /// Captures the currently focused UI element and its metadata.
  ///
  /// Async, and deliberately so: only the `NSWorkspace` lookup needs the main
  /// thread, while reading the focused element is a synchronous IPC into
  /// another process that can sit there for its whole messaging timeout. This
  /// runs the instant the hotkey goes down, where a blocked main actor is a
  /// frozen HUD and a microphone that opens after the first word.
  static func capture() async -> FocusedTarget {
    guard let frontApp = await MainActor.run(body: { frontmostApp() }) else {
      return FocusedTarget(
        bundleID: nil,
        isSecureInput: false,
        accessibilityElement: nil,
        processID: nil
      )
    }

    let axElement = focusedElement(pid: frontApp.pid)
    return FocusedTarget(
      bundleID: frontApp.bundleID,
      isSecureInput: axElement?.hasSecureRole ?? false,
      accessibilityElement: axElement,
      processID: frontApp.pid
    )
  }

  /// Identity of the frontmost app. `NSWorkspace` is main-thread API, but this
  /// reads local state only — it never messages the other process.
  @MainActor
  private static func frontmostApp() -> (bundleID: String?, pid: pid_t)? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    return (app.bundleIdentifier, app.processIdentifier)
  }

  /// The focused UI element of `pid`, or nil when it cannot be read.
  private static func focusedElement(pid: pid_t) -> AXUIElement? {
    let appElement = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(appElement, axMessagingTimeout)

    var focusedValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      appElement,
      kAXFocusedUIElementAttribute as CFString,
      &focusedValue
    ) == .success, let focusedValue else { return nil }
    // A third-party AX server can return `.success` with some other CF type in
    // the out-parameter; force-casting that traps and takes dictation with it.
    guard CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
    return (focusedValue as! AXUIElement)
  }

  /// Whether the target is a secure field **now**.
  ///
  /// `isSecureInput` is a snapshot. Batch delivery captured it microseconds
  /// before writing, so the two agreed; a streaming session writes many times
  /// against one snapshot and the focus inside the target app can land in a
  /// password field between them. Every write re-asks.
  ///
  /// Fails safe in both directions: a target already known to be secure stays
  /// refused, and an unreadable element (AX not trusted, app gone) falls back
  /// to the captured answer rather than inventing a new one.
  func isSecureInputNow() -> Bool {
    if isSecureInput { return true }
    guard let processID else { return accessibilityElement?.hasSecureRole ?? false }
    guard let live = Self.focusedElement(pid: processID) else {
      return accessibilityElement?.hasSecureRole ?? false
    }
    return live.hasSecureRole
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

/// Whether an injection replaces the focused field's contents or extends them.
enum InjectionMode: Equatable, Sendable {
  /// One insertion per session: AX writes the whole value, CGEvent and paste
  /// insert at the caret. The only mode used when streaming delivery is off.
  case standard
  /// Streaming delivery: `text` is a delta appended after everything already
  /// delivered. Nothing previously delivered is ever rewritten.
  case append
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
  /// Type polished sentences into the target app while the user is still
  /// speaking, instead of inserting everything at once on release.
  ///
  /// Default OFF, and deliberately so: streaming delivery appends text to a
  /// live document and can never take it back. Every other code path behaves
  /// exactly as it did before this flag existed while it is false.
  var streamingDelivery: Bool = false

  private enum CodingKeys: String, CodingKey {
    case engine, trigger, activation, polishEnabled, polishModelID, showHUD
    case streamingDelivery
  }

  init() {}

  /// Tolerant decode, one field at a time.
  ///
  /// The synthesized `Decodable` ignores property defaults and throws on a
  /// missing key, and `DictationSettingsStore.load()` turns any throw into
  /// "reset to factory defaults" — so shipping a new setting would silently
  /// wipe the user's engine, trigger, polish, and HUD preferences on first
  /// launch. Each field falling back to its own default makes adding a setting
  /// cost the user nothing. A wholly unreadable payload still resets, which is
  /// the intended behavior for corruption.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = DictationSettings()
    engine = (try? container.decode(EngineChoice.self, forKey: .engine)) ?? defaults.engine
    trigger = (try? container.decode(TriggerKey.self, forKey: .trigger)) ?? defaults.trigger
    activation = (try? container.decode(ActivationMode.self, forKey: .activation))
      ?? defaults.activation
    polishEnabled = (try? container.decode(Bool.self, forKey: .polishEnabled))
      ?? defaults.polishEnabled
    polishModelID = try? container.decode(String.self, forKey: .polishModelID)
    showHUD = (try? container.decode(Bool.self, forKey: .showHUD)) ?? defaults.showHUD
    streamingDelivery = (try? container.decode(Bool.self, forKey: .streamingDelivery))
      ?? defaults.streamingDelivery
  }
}
