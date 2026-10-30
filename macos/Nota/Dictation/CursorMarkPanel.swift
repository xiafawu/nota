import AppKit
import ApplicationServices
import SwiftUI
import UserNotifications
import os

// MARK: - Caret reading

/// What one Accessibility read of the target app said, in Cocoa
/// (bottom-left origin) screen coordinates. Each field is nil when the app did
/// not answer for it, or answered with something `CaretGeometry` refused.
struct CaretReading: Equatable, Sendable {
  var caret: CGRect?
  var element: CGRect?
  var window: CGRect?

  static let empty = CaretReading()
}

/// Reads the caret of `pid`'s focused text element over Accessibility.
///
/// **Off the main actor, always.** Every call here is a synchronous IPC into
/// another process that may not answer for its whole messaging timeout, and
/// the main actor is drawing the mark and holding the hotkey path.
///
/// The read is ordered so the common success costs five round-trips and a
/// wedged app costs one: the focused element first (an app that cannot answer
/// that cannot answer anything), then its selected range and the bounds of it,
/// then the element's own frame. The focused window — needed only for the
/// last-resort fallback — is read only when neither the caret nor the element
/// came back.
enum CaretLocator {
  /// The same budget `FocusedTarget` gives an AX round-trip: every one sits
  /// between the owner and their feedback.
  static let messagingTimeout: Float = 0.25

  /// Whether the mark may wake `bundleID`'s accessibility tree.
  ///
  /// Electron exposes no focused element at all until a client sets
  /// `AXManualAccessibility` on the app (measured 2026-10-30 in Claude:
  /// `kAXErrorNoValue` with it off, an answer ~1.5 s after turning it on), so
  /// without the wake every Electron caret read falls through to the window
  /// fallback. But a woken tree is also what the injector's AX strategy would
  /// find and write an AXValue into, so the tree is woken only where the
  /// injector never tries AX. A bundle earns the wake by being pinned to paste
  /// or keystrokes in `TextInjector.defaultOverrideTable`, never by name here.
  static func wakesAccessibilityTree(bundleID: String?) -> Bool {
    guard let bundleID else { return false }
    return !TextInjector().strategyChain(for: bundleID).contains(.accessibility)
  }

  /// Ask an Electron app to build its accessibility tree. A no-op error for
  /// any app that is not Electron; it persists in the app until it quits.
  static func wakeAccessibilityTree(pid: pid_t) {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, messagingTimeout)
    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
  }

  static func read(pid: pid_t, primaryScreenMaxY: CGFloat, screens: [CGRect]) -> CaretReading {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, messagingTimeout)
    let flip = { (rect: CGRect) in
      CaretGeometry.cocoaRect(fromAX: rect, primaryScreenMaxY: primaryScreenMaxY)
    }

    var reading = CaretReading()
    if let focused = element(app, kAXFocusedUIElementAttribute) {
      AXUIElementSetMessagingTimeout(focused, messagingTimeout)
      let elementFrame = frame(of: focused).map(flip)
      reading.element = CaretGeometry.validated(element: elementFrame, screens: screens)
      reading.caret = CaretGeometry.validated(
        caret: caretRect(in: focused).map(flip),
        element: reading.element,
        screens: screens
      )
    }
    if reading.caret == nil, reading.element == nil,
       let window = element(app, kAXFocusedWindowAttribute) {
      reading.window = frame(of: window).map(flip)
    }
    return reading
  }

  /// The caret in AX coordinates: the collapsed range at the selection's end,
  /// else the character before it, else the one after it — asked lazily, so a
  /// server that answers the first question is asked nothing more.
  private static func caretRect(in element: AXUIElement) -> CGRect? {
    var rangeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
    ) == .success,
      let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID()
    else { return nil }
    var range = CFRange()
    // A third-party server can claim `.success` with a value of another
    // AXValue type; `AXValueGetValue` refusing it is the check.
    guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), range.location >= 0
    else { return nil }

    let end = range.location + range.length
    if let caret = CaretGeometry.caret(
      collapsed: bounds(element, CFRange(location: end, length: 0)),
      preceding: nil,
      following: nil
    ) { return caret }
    if end > 0, let caret = CaretGeometry.caret(
      collapsed: nil,
      preceding: bounds(element, CFRange(location: end - 1, length: 1)),
      following: nil
    ) { return caret }
    return CaretGeometry.caret(
      collapsed: nil,
      preceding: nil,
      following: bounds(element, CFRange(location: end, length: 1))
    )
  }

  private static func bounds(_ element: AXUIElement, _ range: CFRange) -> CGRect? {
    var range = range
    guard let value = AXValueCreate(.cfRange, &range) else { return nil }
    var out: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(
      element, kAXBoundsForRangeParameterizedAttribute as CFString, value, &out
    ) == .success,
      let out, CFGetTypeID(out) == AXValueGetTypeID()
    else { return nil }
    var rect = CGRect.zero
    guard AXValueGetValue(out as! AXValue, .cgRect, &rect) else { return nil }
    return rect
  }

  private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return (value as! AXUIElement)
  }

  private static func frame(of element: AXUIElement) -> CGRect? {
    var positionRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      element, kAXPositionAttribute as CFString, &positionRef
    ) == .success,
      AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
      let positionRef, CFGetTypeID(positionRef) == AXValueGetTypeID(),
      let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID()
    else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
          AXValueGetValue(sizeRef as! AXValue, .cgSize, &size),
          size.width > 0, size.height > 0
    else { return nil }
    return CGRect(origin: origin, size: size)
  }
}

// MARK: - Panel

/// One click-through Liquid Glass capsule: the mark, or the problem note
/// beside it.
///
/// **Not the pill's panel, and not a subclass of it.** Every rule that makes
/// `DictationHUDPanel` right is wrong at the caret: `HUDDragView` claims every
/// point for a drag (a mark beside the caret would eat the click the owner
/// uses to move it), `reposition()` hangs the pill under the focused window,
/// and the growth rule pins a bottom edge. What it shares is every rule a
/// floating surface owes: an AppKit `NSGlassEffectView` plate under the hosting
/// view (SwiftUI glass in a transparent panel renders flat), `.darkAqua` on the
/// panel itself, `level = .statusBar` assigned **after** `isFloatingPanel`, the
/// `.nonactivatingPanel` mask with nothing calling `NSApp.activate`, and a
/// verified `orderFrontRegardless` (see `DictationCursorMarkController.show`).
@MainActor
final class CursorMarkPanel: NSPanel {
  private static let logger = Logger(subsystem: "com.xiafawu.nota", category: "dictation.cursor")

  let glass = GlassBackingView(inset: CursorMarkMetrics.glassMargin)
  private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))

  init(cornerRadius: CGFloat) {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 44, height: 44),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    isOpaque = false
    backgroundColor = .clear
    // A window shadow can only draw inside the frame; the plate carries its own.
    hasShadow = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    // The whole point of this panel being its own class: it takes no clicks.
    ignoresMouseEvents = true
    hidesOnDeactivate = false
    isFloatingPanel = true
    isReleasedWhenClosed = false
    // AFTER isFloatingPanel, which silently rewrites `level` to `.floating` —
    // below a fullscreen app, which is exactly where the caret often is.
    level = .statusBar
    // A single-theme surface: the forced dark SwiftUI scheme does not reach
    // AppKit-drawn pieces, and the glass resolves against this.
    appearance = NSAppearance(named: .darkAqua)

    // The window is sized by the controller from the placement arithmetic, so
    // the hosting view must not push a size of its own back onto it.
    hostingView.sizingOptions = []
    glass.glassCornerRadius = cornerRadius
    glass.setContent(hostingView)
    contentView = glass
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  func setContent<Content: View>(_ view: Content) {
    hostingView.rootView = AnyView(view)
  }

  /// See `DictationHUDPanel.verifyWindowDevice`: `orderFrontRegardless` can
  /// return having produced no window at all, and only `windowNumber` says so.
  @discardableResult
  func verifyWindowDevice() -> Bool {
    let number = windowNumber
    guard number <= 0 else { return true }
    Self.logger.error(
      "Cursor mark panel has no window device after orderFrontRegardless (windowNumber=\(number, privacy: .public))"
    )
    return false
  }
}

// MARK: - Views

/// The mark: one capsule that is a breathing dot when quiet and a five-bar
/// waveform when wide. Its size is the window's, and nothing in here animates
/// a size — the window frame is the one animation authority; the only SwiftUI
/// animations are the dot/bars cross-fade and the bars' meter spring, both
/// inside a frame that cannot change.
struct CursorMarkView: View {
  let phase: CursorMarkPhase
  let level: Float

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HUDMeterPhase(reduceMotion: reduceMotion) { time in
      ZStack {
        if let tint {
          Capsule().fill(tint)
        }
        Circle()
          .fill(HUDInk.listening)
          .frame(width: CursorMarkMetrics.coreDiameter, height: CursorMarkMetrics.coreDiameter)
          .scaleEffect(CursorMarkMetrics.coreScale(time: time, reduceMotion: reduceMotion))
          .opacity(phase.isWide ? 0 : 1)
        HStack(spacing: CursorMarkMetrics.barSpacing) {
          ForEach(0..<CursorMarkMetrics.barCount, id: \.self) { index in
            Capsule()
              .fill(HUDInk.listening)
              .frame(width: CursorMarkMetrics.barWidth, height: barHeight(index, time: time))
          }
        }
        .frame(height: CursorMarkMetrics.barMax)
        .opacity(phase.isWide ? 1 : 0)
        .animation(RecordingMotion.meterAnimation(reduceMotion: reduceMotion), value: level)
      }
      .animation(.easeOut(duration: 0.16), value: phase.isWide)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(CursorMarkMetrics.glassMargin)
    .environment(\.colorScheme, .dark)
    .accessibilityHidden(true)
  }

  private func barHeight(_ index: Int, time: TimeInterval) -> CGFloat {
    switch phase {
    case .talking:
      return CursorMarkMetrics.talkingBarHeight(
        level: level,
        index: index,
        breathe: HUDPillMetrics.breathe(phase: time, index: index, reduceMotion: reduceMotion)
      )
    case .working:
      return CursorMarkMetrics.rollingBarHeight(
        index: index, time: time, reduceMotion: reduceMotion
      )
    case .hidden, .quiet, .problem:
      return CursorMarkMetrics.barBase
    }
  }

  /// The prototype's amber and red, as a wash over the dark-tinted glass.
  private var tint: Color? {
    switch phase.problem?.kind {
    case .warning: return Color(red: 196 / 255, green: 120 / 255, blue: 20 / 255).opacity(0.62)
    case .error: return Color(red: 200 / 255, green: 40 / 255, blue: 34 / 255).opacity(0.62)
    case nil: return nil
    }
  }
}

/// The one-line glass note beside a tinted mark.
struct CursorNoteView: View {
  let problem: CursorProblem

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(swatch)
        .frame(width: 7, height: 7)
      Text(problem.message)
        .font(.system(size: CursorMarkMetrics.noteFontSize, weight: .semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .padding(.horizontal, CursorMarkMetrics.noteHorizontalPadding)
    .frame(height: CursorMarkMetrics.noteHeight)
    .frame(maxWidth: CursorMarkMetrics.noteMaxWidth)
    .padding(CursorMarkMetrics.glassMargin)
    .environment(\.colorScheme, .dark)
  }

  /// The note's own size, glass margin included.
  ///
  /// Measured on a throwaway hosting view with AppKit's default sizing, the
  /// pattern every fitting-size baseline in this target uses — not on the
  /// panel's own hosting view, which has `sizingOptions = []` so it can never
  /// push a size back onto a window the controller sizes, and which therefore
  /// has no intrinsic size to report.
  @MainActor
  static func measuredSize(for problem: CursorProblem) -> CGSize {
    let probe = NSHostingView(rootView: CursorNoteView(problem: problem))
    probe.layoutSubtreeIfNeeded()
    return probe.fittingSize
  }

  private var swatch: Color {
    switch problem.kind {
    case .warning: return Color(red: 0xF2 / 255, green: 0xA3 / 255, blue: 0x3A / 255)
    case .error: return Color(red: 1, green: 0x5A / 255, blue: 0x52 / 255)
    }
  }
}

// MARK: - Controller

/// Drives the Cursor HUD style: decides the phase, reads the caret, places and
/// shows the mark and its note.
///
/// Fed by `DictationHUDController.update()`, which routes a Cursor session
/// here and keeps the pill's panel hidden — so exactly one dictation surface is
/// ever live for a style.
///
/// **The caret is read only while the mark is up.** Tracking starts when the
/// mark first has something to show (the hotkey press) and stops when it
/// fades; while it runs, a detached loop re-reads every `pollInterval`, plus
/// one prompt read just after text lands, so the mark follows the text rather
/// than waiting for the next tick. The pid is the app that was frontmost at
/// key-down — in Insert on Release that is the caret captured at the press,
/// though the insertion path itself is untouched and still captures its own
/// target at release.
@MainActor
final class DictationCursorMarkController {
  private static let logger = Logger(subsystem: "com.xiafawu.nota", category: "dictation.cursor")

  /// One controller snapshot, as the mark reads it.
  struct Input: Equatable {
    var state: DictationState
    var isStartingSession: Bool
    var isReviewing: Bool
    var level: Float
    var sentencesInFlight: Int
    var isPolishInProgress: Bool
    var lastPolishWarning: String?
    var lastSecureFieldNotice: String?
    var streamingStopAwaitsText: Bool? = nil
    var position: CursorMarkPosition
    var glassOpacity: Double
    var glassMaterial: GlassMaterial
  }

  /// Replaceable, for the same reason the pill's is: healing a dead
  /// server-side window means a new NSPanel.
  private var markPanel = CursorMarkPanel(cornerRadius: CursorMarkMetrics.height / 2)
  private var notePanel = CursorMarkPanel(cornerRadius: CursorMarkMetrics.noteHeight / 2)
  private lazy var visibility = HUDVisibilityMonitor { [weak self] in
    self?.markPanel.windowNumber ?? 0
  }

  private var gate = CursorVoiceGate()
  private var lifecycle = CursorMarkLifecycle()
  private(set) var displayed: CursorMarkPhase = .hidden
  private var lastInput: Input?
  private var previousSentencesInFlight = 0
  private var previousState: DictationState = .idle

  private var isMarkShowing = false
  private var isNoteShowing = false

  private var reading: CaretReading?
  private var readingStartedAt: TimeInterval = 0
  private var pollTask: Task<Void, Never>?
  private var firstReadTimeout: Task<Void, Never>?
  private var expiryTask: Task<Void, Never>?

  /// The element VoiceOver announcements are posted against while this style
  /// is the one on screen.
  var announcementElement: NSWindow { markPanel }

  // MARK: Update

  func update(_ input: Input) {
    lastInput = input
    let now = ProcessInfo.processInfo.systemUptime

    let voiceHeard: Bool
    if input.state == .listening {
      voiceHeard = gate.update(level: input.level, now: now)
    } else {
      gate.reset()
      voiceHeard = false
    }

    let phase = CursorMarkPhase.compute(
      controllerState: input.state,
      isStartingSession: input.isStartingSession,
      isReviewing: input.isReviewing,
      voiceHeard: voiceHeard,
      sentencesInFlight: input.sentencesInFlight,
      isPolishInProgress: input.isPolishInProgress,
      lastPolishWarning: input.lastPolishWarning,
      lastSecureFieldNotice: input.lastSecureFieldNotice,
      streamingStopAwaitsText: input.streamingStopAwaitsText
    )
    displayed = lifecycle.display(phase, now: now)
    scheduleExpiry()

    // Text just landed: a sentence left the queue, or the release-time insert
    // finished. Re-read the caret now rather than on the next poll.
    let insertFinished = previousState == .injecting && input.state != .injecting
    if input.sentencesInFlight < previousSentencesInFlight || insertFinished {
      readSoon()
    }
    previousSentencesInFlight = input.sentencesInFlight
    previousState = input.state

    // The session's last text went in: the mark fades from where it is, at
    // once. It used to linger 0.3 s to follow the insert to the new caret; the
    // owner asked for it to leave as soon as everything is typed (2026-10-30).
    guard displayed != .hidden else {
      hideSurfaces()
      return
    }
    startTrackingIfNeeded()
    render()
  }

  /// Take everything down: the owner switched style, or turned the HUD off.
  func dismiss() {
    displayed = .hidden
    gate.reset()
    expiryTask?.cancel()
    expiryTask = nil
    hideSurfaces()
  }

  // MARK: Rendering

  private func render() {
    guard let input = lastInput, let reading else { return }

    let visible = visibleFrame(for: reading)
    let anchor = CursorMarkPlacement.anchor(
      caret: reading.caret,
      element: reading.element,
      fallback: CursorMarkPlacement.fallbackPoint(
        windowFrame: reading.window, visibleFrame: visible
      )
    )
    let markRect = CursorMarkPlacement.markFrame(
      anchor: anchor,
      width: CursorMarkMetrics.width(for: displayed),
      position: input.position,
      visibleFrame: visible
    )

    style(markPanel, input)
    markPanel.setContent(CursorMarkView(phase: displayed, level: input.level))

    var noteWindow: CGRect?
    if let problem = displayed.problem {
      style(notePanel, input)
      notePanel.setContent(CursorNoteView(problem: problem))
      let margin = CursorMarkMetrics.glassMargin
      let fitting = CursorNoteView.measuredSize(for: problem)
      let noteRect = CursorMarkPlacement.noteFrame(
        mark: markRect,
        noteSize: CGSize(width: fitting.width - margin * 2, height: fitting.height - margin * 2),
        visibleFrame: visible
      )
      noteWindow = noteRect.insetBy(dx: -margin, dy: -margin)
    }

    let markWindow = markRect.insetBy(
      dx: -CursorMarkMetrics.glassMargin, dy: -CursorMarkMetrics.glassMargin
    )
    place(markWindow: markWindow, noteWindow: noteWindow)

    if !isMarkShowing { show() }
    if noteWindow != nil {
      if !isNoteShowing {
        isNoteShowing = true
        PanelMotion.fadeIn(notePanel, rise: 0, clickThrough: true) {
          notePanel.orderFrontRegardless()
          return notePanel.verifyWindowDevice()
        }
      }
    } else if isNoteShowing {
      isNoteShowing = false
      PanelMotion.fadeOut(notePanel)
    }
  }

  private func style(_ panel: CursorMarkPanel, _ input: Input) {
    panel.glass.showsGlass = true
    panel.glass.tintAlpha = GlassTint.clamped(input.glassOpacity)
    panel.glass.material = input.glassMaterial
  }

  /// The one frame authority for both windows: one animation group, one
  /// curve, so the note never trails the mark it belongs to. The morph takes
  /// the longer duration; following the caret the shorter one. Under Reduce
  /// Motion every frame change is a cut and only the fades remain — the
  /// prototype's rule.
  private func place(markWindow: CGRect, noteWindow: CGRect?) {
    let markMoves = !markPanel.frame.isClose(to: markWindow)
    let noteMoves = noteWindow.map { !notePanel.frame.isClose(to: $0) } ?? false
    guard markMoves || noteMoves else { return }

    let widthChanged = abs(markPanel.frame.width - markWindow.width) > 0.5
    let animate = isMarkShowing && markPanel.isVisible && !PanelMotion.reduceMotion
    guard animate else {
      if markMoves { markPanel.setFrame(markWindow, display: true) }
      if let noteWindow, noteMoves { notePanel.setFrame(noteWindow, display: true) }
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = widthChanged
        ? CursorMarkMetrics.morphDuration : CursorMarkMetrics.moveDuration
      context.timingFunction = HUDPillMetrics.frameTiming
      if markMoves { markPanel.animator().setFrame(markWindow, display: true) }
      if let noteWindow, noteMoves {
        if isNoteShowing {
          notePanel.animator().setFrame(noteWindow, display: true)
        } else {
          notePanel.setFrame(noteWindow, display: true)
        }
      }
    }
  }

  /// The screen the caret (or element, or window) is on, else the active one.
  private func visibleFrame(for reading: CaretReading) -> CGRect {
    let anchor = reading.caret ?? reading.element ?? reading.window
    let screen: NSScreen?
    if let anchor {
      let point = CGPoint(x: anchor.midX, y: anchor.midY)
      screen = NSScreen.screens.first { $0.frame.contains(point) }
        ?? DictationHUDPanel.activeScreen(anchor: anchor)
    } else {
      screen = DictationHUDPanel.activeScreen(anchor: nil)
    }
    return screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
  }

  // MARK: Show / hide

  private func show() {
    Self.logger.info("Cursor mark shown: phase=\(String(describing: self.displayed), privacy: .public)")
    isMarkShowing = true
    PanelMotion.fadeIn(markPanel, rise: 0, clickThrough: true) {
      markPanel.orderFrontRegardless()
      return markPanel.verifyWindowDevice()
    }
    switch visibility.evaluate() {
    case .none, .silent:
      break
    case .recreate:
      recreatePanels()
    case .reportUnavailable:
      Self.logger.fault("Cursor mark unavailable: a freshly created panel still has no window device.")
      Task { await Self.postUnavailableNotification() }
    }
  }

  /// The pill's bounded heal, for the mark: throw the dead panels away, build
  /// new ones, show once more. The monitor answers `.recreate` only for the
  /// first failure in a run, so this cannot loop.
  private func recreatePanels() {
    Self.logger.error("Recreating the cursor mark panels after a failed show.")
    for dead in [markPanel, notePanel] {
      dead.orderOut(nil)
      dead.close()
    }
    markPanel = CursorMarkPanel(cornerRadius: CursorMarkMetrics.height / 2)
    notePanel = CursorMarkPanel(cornerRadius: CursorMarkMetrics.noteHeight / 2)
    isMarkShowing = false
    isNoteShowing = false
    render()
  }

  private static func postUnavailableNotification() async {
    let center = UNUserNotificationCenter.current()
    guard let granted = try? await center.requestAuthorization(options: [.alert]), granted
    else { return }
    let content = UNMutableNotificationContent()
    content.title = "Dictation cursor mark unavailable"
    content.body = "Restart Nota to bring the mark at your text cursor back."
    try? await center.add(
      UNNotificationRequest(
        identifier: "com.xiafawu.nota.dictation.cursor-unavailable",
        content: content,
        trigger: nil
      )
    )
  }

  private func hideSurfaces() {
    stopTracking()
    if isMarkShowing {
      Self.logger.info("Cursor mark hidden")
      isMarkShowing = false
      PanelMotion.fadeOut(markPanel)
    }
    if isNoteShowing {
      isNoteShowing = false
      PanelMotion.fadeOut(notePanel)
    }
    visibility.reset()
  }

  // MARK: Problem expiry

  private func scheduleExpiry() {
    expiryTask?.cancel()
    expiryTask = nil
    guard let expiry = lifecycle.expiry else { return }
    let delay = max(0, expiry - ProcessInfo.processInfo.systemUptime) + 0.01
    expiryTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard !Task.isCancelled, let self, let input = self.lastInput else { return }
      self.update(input)
    }
  }

  // MARK: Caret tracking

  private func startTrackingIfNeeded() {
    guard pollTask == nil else { return }
    let ownPID = ProcessInfo.processInfo.processIdentifier
    let frontApp = NSWorkspace.shared.frontmostApplication
    let front = frontApp?.processIdentifier
    // Nota's own windows have no caret the mark belongs to.
    let pid = front == ownPID ? nil : front
    let wakes = CaretLocator.wakesAccessibilityTree(bundleID: frontApp?.bundleIdentifier)
    let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
    let screens = NSScreen.screens.map(\.frame)
    let interval = UInt64(CursorMarkMetrics.pollInterval * 1_000_000_000)

    pollTask = Task.detached(priority: .userInitiated) { [weak self] in
      // The tree takes a second or two to come up the first time; the poll
      // below moves the mark from the fallback to the caret once it does.
      if wakes, let pid { CaretLocator.wakeAccessibilityTree(pid: pid) }
      while !Task.isCancelled {
        let started = ProcessInfo.processInfo.systemUptime
        let reading = pid.map {
          CaretLocator.read(pid: $0, primaryScreenMaxY: primaryMaxY, screens: screens)
        } ?? .empty
        guard !Task.isCancelled else { return }
        await self?.received(reading, startedAt: started)
        try? await Task.sleep(nanoseconds: interval)
      }
    }
    trackedPID = pid
    trackedPrimaryMaxY = primaryMaxY
    trackedScreens = screens

    // An app that sits on its AX timeout must not keep the mark off screen:
    // after a short wait it appears at the fallback and moves when (if) the
    // real answer comes.
    firstReadTimeout = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 300_000_000)
      guard !Task.isCancelled, let self, self.reading == nil, self.pollTask != nil else { return }
      self.reading = .empty
      self.render()
    }
  }

  private var trackedPID: pid_t?
  private var trackedPrimaryMaxY: CGFloat = 0
  private var trackedScreens: [CGRect] = []

  /// One extra read just after text lands.
  private func readSoon() {
    guard pollTask != nil, let pid = trackedPID else { return }
    let primaryMaxY = trackedPrimaryMaxY
    let screens = trackedScreens
    let delay = UInt64(CursorMarkMetrics.landedReadDelay * 1_000_000_000)
    Task.detached(priority: .userInitiated) { [weak self] in
      try? await Task.sleep(nanoseconds: delay)
      let started = ProcessInfo.processInfo.systemUptime
      let reading = CaretLocator.read(pid: pid, primaryScreenMaxY: primaryMaxY, screens: screens)
      await self?.received(reading, startedAt: started)
    }
  }

  /// A read finished. Reads overlap (the poll and a landed read), so the
  /// newest *started* one wins and an older answer arriving late is dropped.
  private func received(_ new: CaretReading, startedAt: TimeInterval) {
    guard pollTask != nil, startedAt >= readingStartedAt else { return }
    readingStartedAt = startedAt
    let changed = new != reading
    reading = new
    if changed, displayed != .hidden { render() }
  }

  private func stopTracking() {
    pollTask?.cancel()
    pollTask = nil
    firstReadTimeout?.cancel()
    firstReadTimeout = nil
    reading = nil
    readingStartedAt = 0
    trackedPID = nil
  }
}

private extension CGRect {
  /// Within half a point on every edge: sub-point churn is not worth an
  /// animation, and the caret is re-read five times a second.
  func isClose(to other: CGRect) -> Bool {
    abs(minX - other.minX) <= 0.5 && abs(minY - other.minY) <= 0.5
      && abs(width - other.width) <= 0.5 && abs(height - other.height) <= 0.5
  }
}
