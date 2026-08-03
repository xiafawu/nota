import SwiftUI

/// Opening an AppKit-backed surface (an `NSPopover`, a sheet) means ordering a
/// **child window** onto the screen, and AppKit refuses to do that from inside
/// a display-cycle flush: `-[NSWindow addChildWindow:ordered:]` posts
/// `containingWindowWillOrderOnScreen:`, a ViewBridge `NSRemoteView` observer
/// raises an ObjC exception, and `+[NSApplication _crashOnException:]` takes
/// the process down (macOS 27 beta, build 4acba99).
///
/// SwiftUI decides to present in `ViewGraph.updateOutputs` →
/// `NSHostingView.preferencesDidChange` → `PopoverBridge.updatePresentations`.
/// That chain runs wherever the graph happens to update — including inside
/// `NSHostingView.layout`, which is exactly where a *toolbar* item's hosting
/// view updates: a toolbar item is its own `NSHostingView`, so state a button
/// in the window's main content view mutates does not reach it until AppKit
/// next lays `NSToolbarItemViewer` out. The popover is then presented from
/// inside that layout pass.
///
/// The rule this enforces: presentation state that drives a window-backed
/// surface is set on its own runloop turn, never inside the transaction (or
/// layout pass) of whatever asked for it. One turn's delay is invisible; the
/// crash is not.
@MainActor
enum DeferredPresentation {
  /// Runs `work` after the current AppKit display cycle / SwiftUI transaction.
  /// Injected in tests so the deferral is observable without a runloop.
  typealias Scheduler = (@escaping @MainActor () -> Void) -> Void

  static let nextRunLoopTurn: Scheduler = { work in
    DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
  }

  /// Requests that a presentation flag be raised, outside the caller's pass.
  ///
  /// Already-open is a no-op at both ends. The early return drops a click on a
  /// popover that is already up; the re-check on the scheduled turn drops a
  /// redundant write (a second request from the same burst), so one burst of
  /// clicks costs exactly one SwiftUI transaction.
  ///
  /// The re-check is deliberately the only staleness rule. Requests queued in
  /// one pass drain in a single runloop turn, so nothing of the user's can
  /// interleave between them — a generation counter to reject "stale" requests
  /// would guard a case that cannot occur, at the price of state shared across
  /// unrelated surfaces.
  static func open(
    _ isPresented: Binding<Bool>,
    using scheduler: Scheduler = nextRunLoopTurn
  ) {
    guard !isPresented.wrappedValue else { return }
    scheduler {
      guard !isPresented.wrappedValue else { return }
      isPresented.wrappedValue = true
    }
  }
}
