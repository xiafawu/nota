import AppKit
import Foundation
import os

@MainActor
final class DictationController: ObservableObject {
  @Published private(set) var state: DictationState = .disabled(reason: "Checking permissions…")
  @Published private(set) var lastCaptureDiagnostics: CaptureDiagnostics?

  let permissions: PermissionsCoordinator
  let capture: MicCapture

  private let hotkeyMonitor: HotkeyMonitor
  private let logger = Logger(subsystem: "com.xiafawu.nota", category: "dictation.controller")
  private var hasStarted = false
  private var launchObserver: NSObjectProtocol?
  private var activationObserver: NSObjectProtocol?

  init(
    permissions: PermissionsCoordinator? = nil,
    capture: MicCapture? = nil,
    hotkeyMonitor: HotkeyMonitor? = nil
  ) {
    self.permissions = permissions ?? PermissionsCoordinator()
    self.capture = capture ?? MicCapture()
    self.hotkeyMonitor = hotkeyMonitor ?? HotkeyMonitor()

    self.permissions.onStatusChange = { [weak self] in
      self?.applyPermissionGate()
    }
    self.hotkeyMonitor.onTransition = { [weak self] transition in
      DispatchQueue.main.async { [weak self] in
        self?.handle(transition)
      }
    }
    launchObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didFinishLaunchingNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.start()
      }
    }
    activationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.refreshPermissions()
      }
    }

    applyPermissionGate()
  }

  func start() {
    guard !hasStarted else {
      refreshPermissions()
      return
    }
    hasStarted = true
    refreshPermissions()
  }

  func refreshPermissions() {
    permissions.refresh()
    applyPermissionGate()
  }

  private func applyPermissionGate() {
    guard permissions.isReady else {
      if capture.isCapturing {
        capture.stop()
        lastCaptureDiagnostics = capture.diagnostics
      }
      hotkeyMonitor.stop()
      state = .disabled(reason: permissions.blockingReason)
      return
    }

    if state.isPermissionBlocked {
      state = .idle
    }

    guard hasStarted, !hotkeyMonitor.isRunning else { return }
    guard hotkeyMonitor.start() else {
      let reason = hotkeyMonitor.unavailableReason
        ?? "The Fn/Globe hotkey monitor is unavailable."
      state = .disabled(reason: reason)
      return
    }

    if state.isPermissionBlocked {
      state = .idle
    }
  }

  private func handle(_ transition: HotkeyTransition) {
    switch transition {
    case .began:
      beginCaptureIfAvailable()
    case .ended:
      endCaptureIfNeeded()
    }
  }

  private func beginCaptureIfAvailable() {
    guard permissions.isReady, hotkeyMonitor.isRunning else { return }
    guard !capture.isCapturing else { return }

    switch state {
    case .idle:
      break
    case .failed:
      state = .idle
    default:
      return
    }

    do {
      try capture.start()
      state = .listening
      logger.info("Fn/Globe hold started microphone capture")
    } catch {
      state = .failed(message: error.localizedDescription)
      logger.error("microphone capture failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func endCaptureIfNeeded() {
    guard capture.isCapturing else { return }
    capture.stop()
    lastCaptureDiagnostics = capture.diagnostics
    state = permissions.isReady ? .idle : .disabled(reason: permissions.blockingReason)

    if let diagnostics = lastCaptureDiagnostics {
      logger.info(
        "Fn/Globe hold ended session \(diagnostics.sessionID.uuidString, privacy: .public) buffers=\(diagnostics.bufferCount)"
      )
    }
  }

  deinit {
    if let launchObserver {
      NotificationCenter.default.removeObserver(launchObserver)
    }
    if let activationObserver {
      NotificationCenter.default.removeObserver(activationObserver)
    }
    hotkeyMonitor.stop()
    capture.stop()
  }
}
