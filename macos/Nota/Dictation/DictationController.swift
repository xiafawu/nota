import AppKit
import Foundation
import os

@MainActor
final class DictationController: ObservableObject {
  @Published private(set) var state: DictationState = .disabled(reason: "Checking permissions…")
  @Published private(set) var lastCaptureDiagnostics: CaptureDiagnostics?
  @Published private(set) var lastLatency: TimeInterval?
  @Published private(set) var lastHypothesis: String?
  @Published private(set) var lastProcessedText: String?

  /// The last rules-only result before polish (for diagnostics).
  @Published private(set) var lastRulesResult: String?
  /// Non-nil when polish produced a different result than rules.
  @Published private(set) var lastPolishResult: String?
  /// Set when polish was skipped or failed.
  @Published private(set) var lastPolishWarning: String?

  let permissions: PermissionsCoordinator
  let capture: MicCapture

  /// Current settings — accessible by views for display.
  private(set) var settings: DictationSettings {
    didSet {
      DictationSettingsStore.save(settings)
      applySettings()
    }
  }

  private let hotkeyMonitor: HotkeyMonitor
  private let logger = Logger(subsystem: "com.xiafawu.nota", category: "dictation.controller")
  private var hasStarted = false
  private var launchObserver: NSObjectProtocol?
  private var activationObserver: NSObjectProtocol?

  // P2: speech + injection session state
  private var speechStream: (any SpeechStream)?
  private var holdBeganAt: Date?
  private var isSessionPending = false
  private let injector = TextInjector()

  init(
    permissions: PermissionsCoordinator? = nil,
    capture: MicCapture? = nil,
    hotkeyMonitor: HotkeyMonitor? = nil
  ) {
    self.settings = DictationSettingsStore.load()
    self.permissions = permissions ?? PermissionsCoordinator()
    self.capture = capture ?? MicCapture()
    self.hotkeyMonitor = hotkeyMonitor ?? HotkeyMonitor(
      triggerKey: self.settings.trigger,
      activationMode: self.settings.activation
    )

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

  /// Reload settings from the store and re-apply (e.g. after the Settings UI saves).
  func reloadSettings() {
    settings = DictationSettingsStore.load()
    applySettings()
  }

  // MARK: - Private helpers

  private func applySettings() {
    hotkeyMonitor.triggerKey = settings.trigger
    hotkeyMonitor.activationMode = settings.activation

    // If the hotkey monitor is already running, restart it with the new config.
    if hotkeyMonitor.isRunning {
      hotkeyMonitor.stop()
      if state.isPermissionBlocked == false {
        hotkeyMonitor.start()
      }
    }
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
        ?? "The hotkey monitor is unavailable."
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
    lastProcessedText = nil
    lastRulesResult = nil
    lastPolishResult = nil
    lastPolishWarning = nil

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
        guard self.isSessionPending else {
          stream.cancel()
          self.speechStream = nil
          return
        }
        do {
          try self.capture.start()
          self.isSessionPending = false
          self.state = .listening
          let modeLabel = self.settings.activation == .hold ? "Hold" : "Toggle"
          self.logger.info("\(modeLabel) \(self.settings.trigger.kind == .fnGlobe ? "Fn/Globe" : "keyCode") started dictation session")
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

        // --- P4: Formatter pipeline (rules → optional polish) ---
        let rulesResult = Formatter.applyRules(finalText)
        self.lastRulesResult = rulesResult
        self.lastPolishResult = nil
        self.lastPolishWarning = nil

        let textToInject: String

        if self.settings.polishEnabled, !rulesResult.isEmpty {
          let modelID = self.settings.polishModelID
            ?? ModelRegistry.defaultModel(for: .summary)

          self.logger.info("Polishing with model=\(modelID, privacy: .public)")

          Task {
            let polished: String
            do {
              polished = try await PolishClient.polish(rulesResult, modelID: modelID)
              self.lastPolishResult = polished
              self.lastPolishWarning = nil
              self.logger.info("Polish succeeded")
            } catch {
              self.lastPolishResult = nil
              self.lastPolishWarning = "Polish failed: \(error.localizedDescription). Using rules-only result."
              self.logger.warning("Polish failed: \(error.localizedDescription, privacy: .public)")
              // Fall back to rules-only.
              self.doInject(rulesResult, latency: latency)
              return
            }

            self.doInject(polished, latency: latency)
          }
        } else {
          textToInject = rulesResult
          self.doInject(textToInject, latency: latency)
        }
      }
    }
  }

  /// Shared injection step after formatting/polish is resolved.
  private func doInject(_ text: String, latency: TimeInterval) {
    lastProcessedText = text
    self.logger.info(
      "Dictation session: latency=\(String(format: "%.2f", latency))s text=\"\(text, privacy: .public)\""
    )

    if !text.isEmpty {
      self.state = .injecting
      let target = FocusedTarget.capture()
      self.logger.info("Focused target: bundle=\(target.bundleID ?? "nil", privacy: .public) secure=\(target.isSecureInput)")

      Task {
        await self.injector.inject(text, target: target)
        await MainActor.run {
          if let notice = self.injector.lastSecureFieldNotice {
            self.state = .failed(message: notice)
            Task {
              try? await Task.sleep(nanoseconds: 2_000_000_000)
              await MainActor.run { self.state = .idle }
            }
          } else {
            self.state = .idle
          }
          self.speechStream = nil
        }
      }
    } else {
      self.state = .idle
      self.speechStream = nil
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
  }
}
