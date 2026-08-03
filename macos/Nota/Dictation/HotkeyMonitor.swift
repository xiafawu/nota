import CoreGraphics
import Foundation

final class HotkeyMonitor {
  var triggerKey: TriggerKey
  var activationMode: ActivationMode

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var fnIsDown = false
  private var toggleActive = false

  private(set) var isRunning = false
  private(set) var unavailableReason: String?
  var onTransition: ((HotkeyTransition) -> Void)?

  init(triggerKey: TriggerKey = .fnGlobe, activationMode: ActivationMode = .hold) {
    self.triggerKey = triggerKey
    self.activationMode = activationMode
  }

  /// Forget that a `.toggle` session is running.
  ///
  /// The monitor infers "on" from presses it saw, and a session can now end by a
  /// route it cannot see — the review card's Finish button. Left uncorrected,
  /// the next press would send `.ended` for a session that is already over and
  /// the one after it would be the press that finally started one.
  ///
  /// A no-op in `.hold`, where nothing is latched.
  func resetToggle() {
    toggleActive = false
  }

  @discardableResult
  func start() -> Bool {
    guard !isRunning else { return true }
    stop()

    guard CGPreflightListenEventAccess() else {
      unavailableReason = "Input Monitoring permission is required to observe the hotkey."
      return false
    }

    // Subscribe to the events needed for the current trigger key.
    let eventMask: CGEventMask
    switch triggerKey.kind {
    case .fnGlobe:
      eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
    case .keyCode:
      eventMask = CGEventMask(
        1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue
      )
    }

    let userInfo = Unmanaged.passUnretained(self).toOpaque()
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .listenOnly,
      eventsOfInterest: eventMask,
      callback: Self.eventTapCallback,
      userInfo: userInfo
    ) else {
      unavailableReason = "Nota could not create the global hotkey monitor. Check Input Monitoring permission."
      return false
    }

    guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
      CFMachPortInvalidate(tap)
      unavailableReason = "Nota could not attach the global hotkey monitor to the app run loop."
      return false
    }

    eventTap = tap
    runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    isRunning = true
    unavailableReason = nil
    return true
  }

  func stop() {
    if let source = runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
    if let tap = eventTap {
      CGEvent.tapEnable(tap: tap, enable: false)
      CFMachPortInvalidate(tap)
    }
    runLoopSource = nil
    eventTap = nil
    isRunning = false
    fnIsDown = false
  }

  private func handle(type: CGEventType, event: CGEvent) {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      let wasDown = fnIsDown
      fnIsDown = false
      if let eventTap {
        CGEvent.tapEnable(tap: eventTap, enable: true)
      }
      if wasDown, activationMode == .hold {
        onTransition?(.ended)
      }

    case .flagsChanged:
      handleFlagsChanged(event)

    case .keyDown:
      handleKeyDown(event)

    case .keyUp:
      handleKeyUp(event)

    default:
      break
    }
  }

  private func handleFlagsChanged(_ event: CGEvent) {
    let nextIsDown = event.flags.contains(.maskSecondaryFn)
    guard nextIsDown != fnIsDown else { return }
    fnIsDown = nextIsDown

    switch activationMode {
    case .hold:
      onTransition?(nextIsDown ? .began : .ended)
    case .toggle:
      // In toggle mode, only the press (key down) matters; release is ignored.
      if nextIsDown {
        toggleActive.toggle()
        onTransition?(toggleActive ? .began : .ended)
      }
    }
  }

  private func handleKeyDown(_ event: CGEvent) {
    guard let targetCode = triggerKey.keyCode,
          event.getIntegerValueField(.keyboardEventKeycode) == targetCode
    else { return }

    switch activationMode {
    case .hold:
      onTransition?(.began)
    case .toggle:
      toggleActive.toggle()
      onTransition?(toggleActive ? .began : .ended)
    }
  }

  private func handleKeyUp(_ event: CGEvent) {
    guard activationMode == .hold,
          let targetCode = triggerKey.keyCode,
          event.getIntegerValueField(.keyboardEventKeycode) == targetCode
    else { return }
    onTransition?(.ended)
  }

  private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    if let userInfo {
      let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
      monitor.handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
  }

  deinit {
    stop()
  }
}
