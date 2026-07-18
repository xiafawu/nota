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
/// - Positions the panel once per show; repositions only when the screen
///   configuration changes.
/// - Handles auto-hide timers (`HUDState.autoHideDelay`) and marks the hidden
///   state consumed so a stale notice cannot resurrect the pill.
@MainActor
final class DictationHUDController {
  private weak var controller: DictationController?
  private let panel: DictationHUDPanel
  private var cancellables = Set<AnyCancellable>()
  private var hideTask: Task<Void, Never>?
  private var screenObserver: NSObjectProtocol?

  /// The state auto-hide dismissed. The underlying controller fields
  /// (`lastPolishWarning` / `lastSecureFieldNotice` / `lastProcessedText`)
  /// stay set while idle, so without this any later `objectWillChange` tick
  /// would recompute the same warning/success state and re-show the pill.
  /// Hide = consume; a new session clears it.
  private var consumedState: HUDState?
  private var lastShownState: HUDState = .hidden

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

    // The one reposition trigger besides show: displays added/removed/resized.
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.panel.isVisible else { return }
        self.panel.reposition()
      }
    }

    // Initial state
    update()
  }

  deinit {
    if let screenObserver {
      NotificationCenter.default.removeObserver(screenObserver)
    }
  }

  // MARK: - Update

  private func update() {
    guard let controller else { return }

    var hudState = computeState(from: controller)

    switch hudState {
    case .listening, .processing:
      // A new session invalidates any consumed notice.
      consumedState = nil
    default:
      if let consumedState, hudState == consumedState {
        hudState = .hidden
      }
    }

    announceTransition(from: lastShownState, to: hudState)
    lastShownState = hudState

    panel.update(state: hudState)

    if controller.settings.showHUD, hudState != .hidden {
      // Position once per show — repositioning every tick teleports the pill
      // and fights the animated resize; screen changes are handled above.
      if !panel.isVisible {
        panel.reposition()
      }
      panel.show()
      scheduleAutoHide(for: hudState)
    } else {
      panel.hide()
      hideTask?.cancel()
    }
  }

  private func computeState(from controller: DictationController) -> HUDState {
    HUDState.compute(
      controllerState: controller.state,
      isPolishInProgress: controller.isPolishInProgress,
      lastPolishWarning: controller.lastPolishWarning,
      lastSecureFieldNotice: controller.lastSecureFieldNotice,
      lastProcessedText: controller.lastProcessedText,
      rmsLevel: controller.capture.rmsLevel
    )
  }

  // MARK: - Auto-hide

  private func scheduleAutoHide(for state: HUDState) {
    hideTask?.cancel()

    guard let duration = state.autoHideDelay else { return }

    hideTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
      guard !Task.isCancelled else { return }
      self?.autoHide(scheduledFor: state)
    }
  }

  private func autoHide(scheduledFor scheduled: HUDState) {
    guard let controller else { return }
    // Only hide if nothing replaced the state this timer was scheduled for.
    guard computeState(from: controller) == scheduled else { return }
    consumedState = scheduled
    lastShownState = .hidden
    panel.hide()
  }

  // MARK: - Accessibility

  /// Post VoiceOver announcements on the meaningful transitions. The panel is
  /// click-through and never key, so announcements are the only feedback a
  /// VoiceOver user gets that dictation started, finished, or failed.
  private func announceTransition(from old: HUDState, to new: HUDState) {
    let announcement: (message: String, priority: NSAccessibilityPriorityLevel)?
    switch (old, new) {
    case (.listening, .listening), (.success, .success), (.error, .error):
      announcement = nil
    case (_, .listening):
      announcement = ("Dictation listening", .medium)
    case (_, .success):
      announcement = ("Dictation inserted", .medium)
    case (_, .error(let message)):
      announcement = ("Dictation failed. \(message)", .high)
    default:
      announcement = nil
    }
    guard let announcement else { return }

    NSAccessibility.post(
      element: panel,
      notification: .announcementRequested,
      userInfo: [
        .announcement: announcement.message,
        .priority: announcement.priority.rawValue,
      ]
    )
  }
}
