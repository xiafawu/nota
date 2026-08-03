import AppKit
import Combine
import Foundation
import UserNotifications
import os

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
/// - Detects and heals the zombie-WindowServer state by replacing the panel
///   outright (`HUDVisibilityMonitor`).
@MainActor
final class DictationHUDController {
  private static let logger = Logger(subsystem: "com.xiafawu.nota", category: "dictation.hud")

  private weak var controller: DictationController?
  /// Replaceable, not fixed: healing the zombie state means a NEW NSPanel, and
  /// therefore a new server-side window. Nothing can revive a dead one.
  private var panel: DictationHUDPanel
  private var cancellables = Set<AnyCancellable>()
  private var hideTask: Task<Void, Never>?
  private var watchdogTask: Task<Void, Never>?
  private var screenObserver: NSObjectProtocol?

  /// Reads through to whichever panel is current, so a recreate does not leave
  /// the monitor watching the window it just threw away.
  private lazy var visibility = HUDVisibilityMonitor { [weak self] in
    self?.panel.windowNumber ?? 0
  }
  /// The draft last handed to the panel, replayed onto a fresh one.
  private var lastDraft: HUDDraft = .empty
  /// The style last handed to the panel, replayed onto a fresh one after a
  /// recreate (which starts out on `.pill`).
  private var lastStyle: HUDStyle = .pill

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

    // Kept out of `HUDState` on purpose: the auto-hide bookkeeping above
    // compares states for equality, and a field that changes on every syllable
    // would make `consumedState` never match.
    //
    // Both halves, full length: the pill and the bar take the bounded tail off
    // `boundedTail` (identical to what the pill was handed before the other
    // styles existed), and the prompter renders finalized and volatile
    // separately. Merging them here would throw away the only thing the
    // prompter is for.
    lastDraft = HUDDraft(
      finalized: controller.finalizedDraft,
      volatileTail: controller.roughDraft
    )
    let style = controller.settings.hudStyle
    // Asked of the panel rather than of a second copy of the bookkeeping: it is
    // the panel's frame that needs repositioning, and a recreated panel starts
    // on `.pill` whatever the setting has been saying. `panel.update` below
    // draws the same conclusion and skips the frame animation, so the
    // reposition that follows reads a settled frame instead of an interpolated
    // one an animation is about to overwrite.
    let styleChanged = style != panel.style
    lastStyle = style
    panel.update(state: hudState, draft: lastDraft, style: style)

    if controller.settings.showHUD, hudState != .hidden {
      // Position once per show — repositioning every tick teleports the HUD
      // and fights the animated resize; screen changes are handled above.
      let wasVisible = panel.isVisible
      if !wasVisible || styleChanged {
        panel.reposition()
      }
      panel.show()
      // Only the show that brings the pill onscreen is worth checking, and
      // only it may arm the watchdog: `update()` runs on every throttled RMS
      // tick, and re-arming a 1s timer 15 times a second means it never fires.
      if !wasVisible {
        heal()
        scheduleWatchdog()
      }
      scheduleAutoHide(for: hudState)
    } else {
      panel.hide()
      hideTask?.cancel()
      watchdogTask?.cancel()
      visibility.reset()
    }
  }

  // MARK: - Zombie self-heal

  /// Act on the monitor's verdict about the panel we just tried to show.
  private func heal() {
    switch visibility.evaluate() {
    case .none, .silent:
      break
    case .recreate:
      recreatePanel()
    case .reportUnavailable:
      reportUnavailable()
    }
  }

  /// Replace the panel and show the new one once.
  ///
  /// The old NSPanel's server-side window is the thing that is broken, so it is
  /// closed rather than re-shown. `heal()` runs again on the replacement: a
  /// second consecutive failure escalates to the notification and stops — the
  /// monitor only ever returns `.recreate` for the first failure in a run of
  /// them, so this cannot loop.
  private func recreatePanel() {
    Self.logger.error("Recreating the dictation HUD panel after a failed show.")
    let dead = panel
    dead.orderOut(nil)
    dead.close()

    let fresh = DictationHUDPanel()
    panel = fresh
    fresh.update(state: lastShownState, draft: lastDraft, style: lastStyle)
    fresh.reposition()
    fresh.show()
    heal()
  }

  private func reportUnavailable() {
    Self.logger.fault(
      "Dictation HUD unavailable: a freshly created panel still has no window device."
    )
    Task { await Self.postUnavailableNotification() }
  }

  /// Once per run, and only after a recreate has already failed: the HUD is
  /// the only feedback that dictation is listening, and silently losing it for
  /// a day is what made the original incident expensive.
  private static func postUnavailableNotification() async {
    let center = UNUserNotificationCenter.current()
    guard let granted = try? await center.requestAuthorization(options: [.alert]), granted
    else { return }
    let content = UNMutableNotificationContent()
    content.title = "Dictation HUD unavailable"
    content.body = "Restart Nota to bring the dictation pill back."
    try? await center.add(
      UNNotificationRequest(
        identifier: "com.xiafawu.nota.dictation.hud-unavailable",
        content: content,
        trigger: nil
      )
    )
  }

  /// Second line of defence: some failures pass the immediate check and only
  /// miss the screen a moment later.
  private func scheduleWatchdog() {
    watchdogTask?.cancel()
    watchdogTask = Task { [weak self] in
      try? await Task.sleep(
        nanoseconds: UInt64(HUDVisibilityMonitor.watchdogDelay * 1_000_000_000)
      )
      guard !Task.isCancelled else { return }
      self?.watchdogFired()
    }
  }

  private func watchdogFired() {
    guard let controller, controller.settings.showHUD, lastShownState != .hidden else { return }
    heal()
  }

  private func computeState(from controller: DictationController) -> HUDState {
    HUDState.compute(
      controllerState: controller.state,
      isPolishInProgress: controller.isPolishInProgress,
      lastPolishWarning: controller.lastPolishWarning,
      lastSecureFieldNotice: controller.lastSecureFieldNotice,
      lastProcessedText: controller.lastProcessedText,
      rmsLevel: controller.capture.rmsLevel,
      isReviewing: controller.isReviewing
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
    watchdogTask?.cancel()
    visibility.reset()
  }

  // MARK: - Accessibility

  /// Post VoiceOver announcements on the meaningful transitions. The panel is
  /// never key (its only mouse handling is the drag), so announcements are the
  /// only feedback a VoiceOver user gets that dictation started, finished, or
  /// failed.
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
