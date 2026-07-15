import CoreGraphics
import Foundation

final class HotkeyMonitor {
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var fnIsDown = false

  private(set) var isRunning = false
  private(set) var unavailableReason: String?
  var onTransition: ((HotkeyTransition) -> Void)?

  @discardableResult
  func start() -> Bool {
    guard !isRunning else { return true }
    stop()

    guard CGPreflightListenEventAccess() else {
      unavailableReason = "Input Monitoring permission is required to observe the Fn/Globe key."
      return false
    }

    let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
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
      if wasDown {
        onTransition?(.ended)
      }

    case .flagsChanged:
      let nextIsDown = event.flags.contains(.maskSecondaryFn)
      guard nextIsDown != fnIsDown else { return }
      fnIsDown = nextIsDown
      onTransition?(nextIsDown ? .began : .ended)

    default:
      break
    }
  }

  private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    if let userInfo {
      let monitor = Unmanaged<HotkeyMonitor>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
      monitor.handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
  }

  deinit {
    stop()
  }
}
