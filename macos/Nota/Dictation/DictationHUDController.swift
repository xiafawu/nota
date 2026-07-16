import AppKit
import Combine
import Foundation

// MARK: - DictationHUDController

/// Observes `DictationController` state changes and drives the floating HUD panel.
///
/// - Subscribes to controller `objectWillChange` (deferred via `.receive(on:)` to
///   read fresh published values).
/// - Subscribes to `capture.rmsLevel` separately (throttled) so the live level
///   meter updates smoothly without flooding Combine subscriptions.
/// - Handles auto-hide timers for success (1s) and warning/error (3s) states.
@MainActor
final class DictationHUDController {
  private weak var controller: DictationController?
  private let panel: DictationHUDPanel
  private var cancellables = Set<AnyCancellable>()
  private var hideTask: Task<Void, Never>?

  init(controller: DictationController) {
    self.controller = controller
    self.panel = DictationHUDPanel()

    // Observe controller @Published changes.
    // `.receive(on: DispatchQueue.main)` defers the sink to the next main
    // runloop tick, ensuring the published properties have been updated by the
    // time the handler reads them (objectWillChange fires in willSet).
    controller.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.update()
      }
      .store(in: &cancellables)

    // Observe RMS level changes separately, throttled to ~15fps.
    controller.capture.$rmsLevel
      .throttle(for: .milliseconds(66), scheduler: DispatchQueue.main, latest: true)
      .sink { [weak self] _ in
        guard let self, let controller = self.controller, controller.state == .listening
        else { return }
        self.update()
      }
      .store(in: &cancellables)

    // Initial state
    update()
  }

  // MARK: - Update

  private func update() {
    guard let controller else { return }

    let hudState = HUDState.compute(
      controllerState: controller.state,
      isPolishInProgress: controller.isPolishInProgress,
      lastPolishWarning: controller.lastPolishWarning,
      lastSecureFieldNotice: controller.lastSecureFieldNotice,
      lastProcessedText: controller.lastProcessedText,
      rmsLevel: controller.capture.rmsLevel
    )

    panel.update(state: hudState)

    if controller.settings.showHUD, hudState != .hidden {
      panel.reposition(belowFrontmostWindow: true)
      panel.show()
      scheduleAutoHide(for: hudState)
    } else {
      panel.hide()
      hideTask?.cancel()
    }
  }

  // MARK: - Auto-hide

  private func scheduleAutoHide(for state: HUDState) {
    hideTask?.cancel()

    let duration: TimeInterval
    switch state {
    case .success:
      duration = 1.0
    case .warning, .error:
      duration = 3.0
    default:
      return  // no auto-hide for listening / processing
    }

    hideTask = Task { [weak self, weak controller] in
      try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
      guard !Task.isCancelled else { return }
      await MainActor.run { [weak self] in
        // Only hide if controller state is still idle (hasn't started a new session)
        guard let controller, controller.state == .idle else { return }
        self?.panel.hide()
      }
    }
  }
}
