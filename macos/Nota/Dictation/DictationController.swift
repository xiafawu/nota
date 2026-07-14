import AppKit
import Foundation
import os

@MainActor
final class DictationController: ObservableObject {
  @Published private(set) var state: DictationState = .disabled(reason: "Checking permissions…")
  @Published private(set) var lastCaptureDiagnostics: CaptureDiagnostics?
  @Published private(set) var lastLatency: TimeInterval?
  @Published private(set) var lastHypothesis: String?

  let permissions: PermissionsCoordinator
  let capture: MicCapture

  private let hotkeyMonitor: HotkeyMonitor
  private let logger = Logger(subsystem: "com.xiafawu.nota", category: "dictation.controller")
  private var hasStarted = false
  private var launchObserver: NSObjectProtocol?
  private var activationObserver: NSObjectProtocol?

  // P2: speech + injection session state
  private var speechStream: (any SpeechStream)?
  private var holdBeganAt: Date?
  private var isSessionPending = false  // true while awaiting speech.start()
  private let injector = TextInjector()

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

    // P2: route PCM buffers to the active speech stream
    self.capture.onPCMBuffer = { [weak self] buffer in
      guard let self, let stream = self.speechStream else { return }
      do {
        try stream.feed(buffer)
      } catch {
        self.logger.error("SpeechStream.feed failed: \(error.localizedDescription, privacy: .public)")
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
        cancelSession()
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
      holdBeganAt = Date()
      beginCaptureAndSpeech()
    case .ended:
      endCaptureAndFinalize()
    }
  }

  // MARK: - P2 session lifecycle

  private func beginCaptureAndSpeech() {
    guard permissions.isReady, hotkeyMonitor.isRunning else { return }
    guard !capture.isCapturing, !isSessionPending else { return }

    switch state {
    case .idle:
      break
    case .failed:
      state = .idle
    default:
      return
    }

    isSessionPending = true

    // Create a fresh Apple speech stream for this session
    let stream = AppleSpeechStream()
    speechStream = stream
    lastHypothesis = nil

    // Observe partial hypotheses for diagnostics
    Task { [weak self] in
      guard let self else { return }
      for await hypothesis in stream.hypotheses {
        await MainActor.run {
          self.lastHypothesis = hypothesis.text
          self.logger.debug("Hypothesis isFinal=\(hypothesis.isFinal) text=\"\(hypothesis.text, privacy: .public)\"")
        }
      }
    }

    // Start speech recognition first, then capture once ready
    Task {
      do {
        try await stream.start()
      } catch {
        await MainActor.run {
          self.isSessionPending = false
          self.speechStream = nil
          self.state = .failed(message: error.localizedDescription)
          self.logger.error("AppleSpeechStream.start failed: \(error.localizedDescription, privacy: .public)")
        }
        return
      }

      // Speech is ready — now start microphone capture
      await MainActor.run {
        // Guard: user may have released the key while we were awaiting start
        guard self.isSessionPending else {
          stream.cancel()
          self.speechStream = nil
          return
        }
        do {
          try self.capture.start()
          self.isSessionPending = false
          self.state = .listening
          self.logger.info("Fn/Globe hold started dictation session")
        } catch {
          stream.cancel()
          self.isSessionPending = false
          self.speechStream = nil
          self.state = .failed(message: error.localizedDescription)
          self.logger.error("microphone capture failed: \(error.localizedDescription, privacy: .public)")
        }
      }
    }
  }

  private func endCaptureAndFinalize() {
    // If we're still awaiting speech.start(), cancel and return
    if isSessionPending {
      isSessionPending = false
      speechStream?.cancel()
      speechStream = nil
      state = .idle
      logger.info("Dictation session cancelled before speech started")
      return
    }

    guard capture.isCapturing else { return }
    capture.stop()
    lastCaptureDiagnostics = capture.diagnostics

    state = .finalizing

    Task {
      let finalText: String
      do {
        finalText = try await speechStream?.finish() ?? ""
      } catch is CancellationError {
        await MainActor.run {
          self.isSessionPending = false
          self.state = .idle
          self.speechStream = nil
        }
        return
      } catch {
        await MainActor.run {
          self.isSessionPending = false
          self.state = .failed(message: error.localizedDescription)
          self.speechStream = nil
          self.logger.error("SpeechStream.finish failed: \(error.localizedDescription, privacy: .public)")
        }
        return
      }

      await MainActor.run {
        self.isSessionPending = false
        let startTime = self.holdBeganAt ?? Date()
        let latency = Date().timeIntervalSince(startTime)
        self.lastLatency = latency
        self.lastHypothesis = finalText

        self.logger.info(
          "Dictation session: latency=\(String(format: "%.2f", latency))s text=\"\(finalText, privacy: .public)\""
        )

        // Inject if we have text
        if !finalText.isEmpty {
          self.state = .injecting
          self.injector.inject(finalText)
          self.logger.info("Paste injection completed for \"\(finalText, privacy: .public)\"")
        }

        self.state = .idle
        self.speechStream = nil
      }
    }
  }

  private func cancelSession() {
    speechStream?.cancel()
    speechStream = nil
    capture.stop()
    lastCaptureDiagnostics = capture.diagnostics
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
    speechStream?.cancel()
  }
}
