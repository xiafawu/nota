import AppKit
import ApplicationServices
import SwiftUI
import os

// MARK: - DictationHUDPanel

/// Non-activating floating panel that hosts the HUD pill.
///
/// Constrained to never take key focus: `.nonactivatingPanel` style mask and
/// `.statusBar` level, so dictation injection always targets the app the user
/// is typing into. It does **accept** mouse events — the surface is a drag
/// handle (`HUDDragView`) and a dragged position is remembered — which costs
/// click-through over the HUD's own rectangle and nothing else.
@MainActor
final class DictationHUDPanel: NSPanel {
  private static let logger = Logger(subsystem: "com.xiafawu.nota", category: "dictation.hud")

  private let hostingView: NSHostingView<DictationHUDRootView>
  private let dragView = HUDDragView(inset: DictationHUDContentView.shadowMargin)

  /// Where the owner dragged the HUD, as the pill rect's **bottom-center**
  /// point in screen coordinates — nil until they drag one.
  ///
  /// Bottom-center rather than the window origin for two reasons. The bottom
  /// edge is the one the growth rule pins, so it is the only edge whose meaning
  /// survives the pill getting taller; and the horizontal center is the only
  /// x that survives a *style* switch, where the same position has to serve a
  /// 200pt pill and a 600pt prompter.
  private(set) var pinnedPillBottomCenter: CGPoint?

  /// The style currently on screen. Read by `reposition()` (each shape reserves
  /// a different amount of growth room) and by `update` (a switch between two
  /// shapes is not growth and must not be animated). The controller reads it to
  /// decide whether this update needs a reposition at all.
  private(set) var style: HUDStyle = .pill

  init() {
    hostingView = NSHostingView(
      rootView: DictationHUDRootView(style: .pill, state: .hidden, draft: .empty)
    )

    let rect = NSRect(x: 0, y: 0, width: 200, height: 48)
    super.init(
      contentRect: rect,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    isOpaque = false
    backgroundColor = .clear
    // No window shadow: a layer/window shadow can only draw INSIDE the window
    // frame, and a pill-sized window turns it into a dark rectangle behind
    // the capsule. The pill draws its own SwiftUI shadow inside a margin
    // (see DictationHUDContentView.shadowMargin).
    hasShadow = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    // The HUD is draggable, and a window that ignores mouse events cannot be
    // grabbed. The cost is real and bounded: clicks landing on the HUD's own
    // rectangle no longer pass through to the app underneath. Nothing else
    // changes — the panel is `.nonactivatingPanel` and never becomes key, so a
    // click on it does not raise Nota or move focus away from the app being
    // dictated into, and no style has interactive content a stray click could
    // trigger.
    ignoresMouseEvents = false
    hidesOnDeactivate = false
    isFloatingPanel = true
    // The zombie self-heal throws this panel away and builds another; with the
    // NSWindow default (true) the `close()` that does it would over-release a
    // panel the controller still holds.
    isReleasedWhenClosed = false
    // AFTER isFloatingPanel: setting it to true silently rewrites `level` to
    // .floating (CGWindowLayer 3), which sits BELOW a fullscreen app. Assigning
    // the level first — as this did — looked correct and shipped a pill that
    // vanished over fullscreen windows. .statusBar is CGWindowLayer 25.
    level = .statusBar
    // The HUD is a single-theme surface: `DictationHUDContentView` fills a fixed
    // dark body and forces `colorScheme` dark on top of it. That forcing is a
    // SwiftUI *environment* value and does NOT change this window's
    // `effectiveAppearance` — which is what every AppKit-drawn piece inside the
    // hosting view follows: the `ProgressView` in the processing state, control
    // accent resolution, and any system material. With Settings → General
    // pinning `NSApp.appearance` to Light (`AppearanceSetting.apply`), or on a
    // machine simply running Light, the panel inherited light-mode chrome and
    // the pill rendered as a washed light capsule under dark-styled content.
    // The review card has carried this line since it shipped; the pill was the
    // one that was missed.
    appearance = NSAppearance(named: .darkAqua)

    // The hosting view lives inside the drag view rather than being the content
    // view itself: SwiftUI decides its own hit testing, and the drag has to work
    // over every pixel of the surface. `HUDDragView.hitTest` claims them all.
    //
    // The drag view is also what carries the Liquid Glass plate (see
    // `GlassBackingView`): the material is an `NSGlassEffectView` laid out at the
    // pill rect, with the hosting view above it at full bounds. SwiftUI's own
    // glass modifiers were measured to render as a flat blur inside a transparent
    // panel — they refract only their own hierarchy, and a HUD's hierarchy is a
    // glyph and a line of text.
    dragView.setContent(hostingView)
    contentView = dragView

    pinnedPillBottomCenter = HUDPositionStore.load()
    dragView.onDragEnded = { [weak self] in self?.recordDraggedPosition() }
  }

  /// Remember where the owner just dropped the HUD.
  ///
  /// Their position wins over every automatic placement from here on:
  /// `reposition()` returns early while a pinned point survives validation, so
  /// neither a new session nor a screen change moves the HUD back under the
  /// focused window. Growth still works untouched — `update` pins `origin.y`,
  /// and the pinned point is that same bottom edge.
  private func recordDraggedPosition() {
    let margin = DictationHUDContentView.shadowMargin
    let pill = frame.insetBy(dx: margin, dy: margin)
    let point = CGPoint(x: pill.midX, y: pill.minY)
    pinnedPillBottomCenter = point
    HUDPositionStore.save(point)
  }

  /// Update the HUD content and resize the panel to fit.
  ///
  /// **The window frame is the one and only animation authority.** SwiftUI
  /// used to animate the pill's own layout (`.animation(value: state)`) while
  /// NSAnimationContext animated the window around it: two curves of different
  /// duration driving the same geometry, which is what read as jitter. The
  /// content view now animates nothing that can change its size, and every
  /// size/position change goes through the group below.
  ///
  /// `draft` is the in-flight recognition. `.empty` (the only value a
  /// non-live-draft session ever passes) renders the HUD exactly as before.
  /// It is deliberately not part of `HUDState`: the auto-hide bookkeeping
  /// compares states for equality, and a field that changes on every syllable
  /// would make every comparison miss.
  ///
  /// `style` picks the shape. `.pill` is the default and forwards the same
  /// bounded tail the pill has always been handed, so nothing about the default
  /// path is conditional on this parameter existing.
  ///
  /// `glassOpacity` is the owner's tint weight. It rides along with the style
  /// rather than being pushed separately because this is the one call the HUD
  /// makes on every tick and on every show: whatever Settings last saved is on
  /// the panel by its next frame, and no path has to remember to apply it.
  func update(
    state: HUDState,
    draft: HUDDraft = .empty,
    style: HUDStyle = .pill,
    glassOpacity: Double = GlassTint.standard,
    glassMaterial: GlassMaterial = .standard
  ) {
    let styleChanged = style != self.style
    self.style = style
    hostingView.rootView = DictationHUDRootView(style: style, state: state, draft: draft)
    hostingView.layoutSubtreeIfNeeded()
    let size = hostingView.fittingSize

    // Before the sub-point guard below, not after: the glass is the surface, and
    // a state change that does not move the frame (a warning arriving at the same
    // width) still changes the shape the material has to take.
    dragView.showsGlass = state != .hidden
    dragView.tintAlpha = GlassTint.clamped(glassOpacity)
    dragView.material = glassMaterial
    dragView.glassCornerRadius = HUDGlassMetrics.cornerRadius(
      style: style,
      state: state,
      cardHeight: max(size.height - DictationHUDContentView.shadowMargin * 2, 0)
    )

    var frame = self.frame
    // Sub-point churn is not worth restarting a 0.26s animation for, and this
    // runs on every throttled RMS tick.
    guard abs(size.width - frame.width) > 0.5 || abs(size.height - frame.height) > 0.5
    else { return }
    // Grow UP, not down: the pill's bottom edge is its anchor — it hangs 12pt
    // below the focused window's bottom edge (see reposition()) — and the
    // newest line is pinned to that bottom edge. Growing upward keeps the
    // reading line exactly where it was placed while the card's top edge
    // climbs. `pillOriginY` reserved the grown height at placement, so this
    // never walks the card off the top of the screen.
    frame.origin.x -= (size.width - frame.size.width) / 2
    frame.size = size
    frame = Self.clamped(frame, to: screen ?? NSScreen.main)

    if Self.animatesFrameChange(style: style, styleChanged: styleChanged, isVisible: isVisible) {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = HUDPillMetrics.frameDuration
        context.timingFunction = HUDPillMetrics.frameTiming
        animator().setFrame(frame, display: true)
      }
    } else {
      setFrame(frame, display: true)
    }
  }

  /// Whether this frame change may be animated.
  ///
  /// Two reasons it may not. The bar is a constant size, so the only frame
  /// change it can ever produce is the one-off switch into or out of the style,
  /// and animating that would be animating growth the style promises not to
  /// have. And a **style switch** is not growth in any style: the caller
  /// repositions right after it, and an animation still in flight means the
  /// reposition reads an interpolated frame and is then overwritten by the
  /// animation's destination — which is exactly the off-center panel the
  /// reposition exists to prevent.
  static func animatesFrameChange(
    style: HUDStyle,
    styleChanged: Bool,
    isVisible: Bool
  ) -> Bool {
    isVisible && style.animatesGrowth && !styleChanged
  }

  /// Shift (never resize) a window frame so the pill inside it stays 8pt
  /// within the screen's visible area. Growing upward can otherwise walk the
  /// pill off the top of the screen.
  ///
  /// Internal, not private, so the interaction with the growth room
  /// `HUDPanelLayout.pillOriginY` reserves can be asserted without a screen:
  /// after a reposition that reserved room, growing a card to its full height
  /// must leave this function with nothing to correct.
  static func clamped(_ frame: NSRect, to screen: NSScreen?) -> NSRect {
    guard let screen else { return frame }
    return clamped(frame, visibleFrame: screen.visibleFrame)
  }

  static func clamped(_ frame: NSRect, visibleFrame visible: NSRect) -> NSRect {
    let margin = DictationHUDContentView.shadowMargin
    let pill = frame.insetBy(dx: margin, dy: margin)
    guard pill.width > 0, pill.height > 0,
          pill.width + 16 <= visible.width, pill.height + 16 <= visible.height
    else { return frame }

    var result = frame
    result.origin.x += max(0, visible.minX + 8 - pill.minX)
    result.origin.x -= max(0, pill.maxX - (visible.maxX - 8))
    result.origin.y += max(0, visible.minY + 8 - pill.minY)
    result.origin.y -= max(0, pill.maxY - (visible.maxY - 8))
    return result
  }

  /// Position the pill under the focused window of the frontmost app — the
  /// app being dictated into, never Nota's own windows. Falls back to
  /// bottom-center of the active screen (the anchor window's screen, else
  /// the cursor's, else the main screen).
  ///
  /// All math is done on the *pill* rect (window frame inset by
  /// `shadowMargin`) — the window frame includes the transparent shadow
  /// margin, so treating frame edges as pill edges renders every gap 24pt
  /// too large.
  func reposition() {
    let margin = DictationHUDContentView.shadowMargin
    let pillSize = NSSize(
      width: max(frame.width - margin * 2, 0),
      height: max(frame.height - margin * 2, 0)
    )
    let reserved = style.reservedCardHeight ?? pillSize.height

    // The owner's own position outranks the anchor window. Validated every
    // time, never trusted: the screen it was recorded on may be gone, smaller,
    // or arranged differently, and a HUD restored off-screen is a HUD that does
    // not exist. A point no current screen can host is dropped — the automatic
    // placement below is the self-heal.
    if let pinned = pinnedPillBottomCenter {
      if let point = HUDPanelLayout.validatedPinnedPoint(
        pinned,
        pillSize: pillSize,
        reservedHeight: reserved,
        visibleFrames: NSScreen.screens.map(\.visibleFrame)
      ) {
        setFrameOrigin(NSPoint(x: point.x - pillSize.width / 2 - margin, y: point.y - margin))
        return
      }
      pinnedPillBottomCenter = nil
      HUDPositionStore.clear()
    }

    let anchorFrame = Self.frontmostAppFocusedWindowFrame()
    guard let screen = anchorFrame.flatMap({ anchor in
      NSScreen.screens.first { $0.frame.intersects(anchor) }
    })
      ?? NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
      ?? NSScreen.main
    else { return }
    let screenFrame = screen.visibleFrame

    // Clamp the pill 8pt inside the visible screen, then convert back to a
    // window-frame origin by re-adding the shadow margin.
    let pillCenterX = anchorFrame?.midX ?? screenFrame.midX
    let pillX = max(
      screenFrame.minX + 8,
      min(pillCenterX - pillSize.width / 2, screenFrame.maxX - pillSize.width - 8)
    )
    let pillY = HUDPanelLayout.pillOriginY(
      anchorMinY: anchorFrame?.minY,
      screenFrame: screenFrame,
      pillHeight: pillSize.height,
      // The pill and the prompter both grow after they are placed, and both are
      // placed high enough for all of that growth. See `reservedCardHeight`.
      reservedHeight: reserved
    )

    setFrameOrigin(NSPoint(x: pillX - margin, y: pillY - margin))
  }

  /// Frame (Cocoa coordinates) of the focused window of the frontmost app,
  /// via the Accessibility API. Returns nil when the frontmost app is Nota
  /// itself or the window can't be read (no AX grant, no focused window).
  ///
  /// Shared with the review panel, which anchors to the same window so the
  /// panel appears where the pill it replaces would have been.
  static func frontmostAppFocusedWindowFrame() -> NSRect? {
    guard let app = NSWorkspace.shared.frontmostApplication,
          app.processIdentifier != ProcessInfo.processInfo.processIdentifier
    else { return nil }

    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var focusedRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      axApp, kAXFocusedWindowAttribute as CFString, &focusedRef
    ) == .success,
      let focused = focusedRef,
      CFGetTypeID(focused) == AXUIElementGetTypeID()
    else { return nil }
    let axWindow = focused as! AXUIElement

    var positionRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      axWindow, kAXPositionAttribute as CFString, &positionRef
    ) == .success,
      AXUIElementCopyAttributeValue(
        axWindow, kAXSizeAttribute as CFString, &sizeRef
      ) == .success,
      let positionValue = positionRef, CFGetTypeID(positionValue) == AXValueGetTypeID(),
      let sizeValue = sizeRef, CFGetTypeID(sizeValue) == AXValueGetTypeID()
    else { return nil }

    var topLeft = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &topLeft),
          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
          size.width > 0, size.height > 0
    else { return nil }

    // AX positions are top-left-origin (y down from the primary screen's
    // top); Cocoa is bottom-left-origin. Flip via the primary screen height.
    guard let primary = NSScreen.screens.first else { return nil }
    let cocoaY = primary.frame.maxY - topLeft.y - size.height
    return NSRect(x: topLeft.x, y: cocoaY, width: size.width, height: size.height)
  }

  /// Order the pill onscreen. Returns whether it actually got there — see
  /// `verifyWindowDevice`.
  @discardableResult
  func show() -> Bool {
    guard !isVisible else {
      orderFrontRegardless()
      return verifyWindowDevice()
    }
    // Fade in with a small rise — HUDs that blink into place read as cheap.
    alphaValue = 0
    var frame = self.frame
    frame.origin.y -= 8
    setFrame(frame, display: false)
    orderFrontRegardless()
    frame.origin.y += 8
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      animator().alphaValue = 1
      animator().setFrame(frame, display: true)
    }
    return verifyWindowDevice()
  }

  /// True when AppKit gave this panel a server-side window.
  ///
  /// `orderFrontRegardless()` returns nothing and fails silently: on
  /// 2026-07-27 it left the panel with `windowNumber == 0` for an entire day,
  /// rendering and resizing into a window that did not exist. This one log
  /// line is what turns a repeat of that into a `log show` one-liner instead of
  /// a mystery.
  @discardableResult
  func verifyWindowDevice() -> Bool {
    let number = windowNumber
    guard number <= 0 else { return true }
    Self.logger.error(
      """
      HUD panel has no window device after orderFrontRegardless \
      (windowNumber=\(number, privacy: .public), \
      isVisible=\(self.isVisible, privacy: .public), \
      frame=\(NSStringFromRect(self.frame), privacy: .public)) — zombie WindowServer state.
      """
    )
    return false
  }

  func hide() {
    guard isVisible else { return }
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 0.18
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      animator().alphaValue = 0
    }, completionHandler: { [weak self] in
      self?.orderOut(nil)
      self?.alphaValue = 1
    })
  }
}

// MARK: - Dragging

/// The HUD's whole surface as one drag handle.
///
/// A plain `isMovableByWindowBackground` would move the window too, but it
/// reports nothing: every move would look identical to the ones `reposition()`
/// makes, and "the owner chose this position" is exactly the fact that has to
/// be remembered. So the drag is done by hand, and `onDragEnded` fires only
/// when the pointer actually travelled.
///
/// **The window frame is still animated in exactly one place.** A drag calls
/// `setFrameOrigin` directly — no animation, no `animator()` — so it can never
/// be in flight against the growth animation in `DictationHUDPanel.update`.
///
/// It is a `GlassBackingView` because the HUD's material is an AppKit
/// `NSGlassEffectView` and the drag handle is the one view that already spans
/// the whole surface. The glass is a sibling *under* the hosting view and takes
/// no clicks, so `hitTest` below still claims every point.
final class HUDDragView: GlassBackingView {
  var onDragEnded: (() -> Void)?

  private var mouseDownLocation: NSPoint?
  private var windowOriginAtMouseDown: NSPoint?
  private var moved = false

  /// Claim every point in the view. The HUD has no controls, and SwiftUI would
  /// otherwise decide per-pixel whether a drag starts.
  override func hitTest(_ point: NSPoint) -> NSView? {
    bounds.contains(convert(point, from: superview)) ? self : nil
  }

  /// AppKit's own background-drag must stay out of it: two movers, one frame.
  override var mouseDownCanMoveWindow: Bool { false }

  override func mouseDown(with event: NSEvent) {
    mouseDownLocation = NSEvent.mouseLocation
    windowOriginAtMouseDown = window?.frame.origin
    moved = false
  }

  override func mouseDragged(with event: NSEvent) {
    guard let window, let start = mouseDownLocation, let origin = windowOriginAtMouseDown
    else { return }
    let now = NSEvent.mouseLocation
    // Against the mouse-down anchor, never accumulated per event: summing
    // deltas drifts, and the pointer is the thing the owner is watching.
    window.setFrameOrigin(
      NSPoint(x: origin.x + now.x - start.x, y: origin.y + now.y - start.y)
    )
    moved = true
  }

  override func mouseUp(with event: NSEvent) {
    defer {
      mouseDownLocation = nil
      windowOriginAtMouseDown = nil
      moved = false
    }
    guard moved else { return }
    onDragEnded?()
  }
}

// MARK: - Position store

/// Where the owner dragged the HUD, across launches.
///
/// Global rather than per style: the answer to "where do I want the HUD" is
/// about the owner's screen and their eyes, not about which of three shapes is
/// currently drawing. Storing the pill rect's bottom-center is what lets one
/// answer serve all three — see `DictationHUDPanel.pinnedPillBottomCenter`.
///
/// Backed by `DictationSettingsStore.defaults`, which is a private wiped suite
/// under XCTest: a test that drags the HUD must not move the owner's real one.
enum HUDPositionStore {
  private static let key = "com.xiafawu.nota.dictationHUDPosition"

  static func load() -> CGPoint? {
    guard let pair = DictationSettingsStore.defaults.array(forKey: key) as? [Double],
          pair.count == 2,
          pair.allSatisfy({ $0.isFinite })
    else { return nil }
    return CGPoint(x: pair[0], y: pair[1])
  }

  static func save(_ point: CGPoint) {
    guard point.x.isFinite, point.y.isFinite else { return }
    DictationSettingsStore.defaults.set([point.x, point.y], forKey: key)
  }

  static func clear() {
    DictationSettingsStore.defaults.removeObject(forKey: key)
  }
}

// MARK: - Panel layout

/// Where the HUD hangs, as arithmetic — no NSScreen, no window server.
enum HUDPanelLayout {
  /// Gap between the anchor window's bottom edge and the pill's top edge.
  static let anchorGap: CGFloat = 12
  /// Smallest gap kept between the pill and the edges of the visible screen.
  static let screenInset: CGFloat = 8

  /// How far above the screen's bottom inset the HUD is allowed to come to
  /// rest by default.
  ///
  /// Most windows reach nearly to the bottom of the visible frame, so
  /// "hang 12pt under the focused window" collapsed onto the hard floor for
  /// almost every anchor — the HUD sat in the last few points of the screen,
  /// half on top of the Dock, and read as falling off the bottom edge. The
  /// hard floor is still the hard floor (a screen too short for the grown card
  /// keeps it), this is only where the placement prefers to stop.
  static let restingBottomMargin: CGFloat = 56

  /// The pill's bottom-edge y for one anchor window, one screen, and a style
  /// that may still grow to `reservedHeight`.
  ///
  /// `reservedHeight` is the whole point. Growth is **upward**: the pill's
  /// bottom edge is the anchor, so `DictationHUDPanel.update` grows a card up
  /// with its bottom edge pinned. The clamp would then shove the frame back
  /// onto the screen when the grown card's top exceeds the screen's top — and
  /// since the frame's bottom is what placement decided, every extra line
  /// would push the card down one line at a time. Reserving the growth room at
  /// placement time means the clamp never has anything to correct: the ceiling
  /// is computed for the fully grown card, so the bottom edge really does hold
  /// still.
  ///
  /// Styles that cannot grow (or whose placement is the untouched baseline)
  /// pass their current height and get exactly the old arithmetic.
  static func pillOriginY(
    anchorMinY: CGFloat?,
    screenFrame: NSRect,
    pillHeight: CGFloat,
    reservedHeight: CGFloat
  ) -> CGFloat {
    // Top of the fully grown card, capped at the screen's top inset. On a
    // screen too short to hold the fully grown card, staying on screen beats
    // reserving room that does not exist.
    let ceilingY = screenFrame.maxY - screenInset - reservedHeight
    let desired = anchorMinY.map { $0 - anchorGap - pillHeight }
      ?? screenFrame.minY + screenInset + restingBottomMargin
    // Never below the screen's bottom inset, and by preference not below the
    // resting margin either — but the resting margin yields to a screen that
    // cannot hold the card above it, because on screen beats comfortable.
    let hardFloor = screenFrame.minY + screenInset
    let restingFloor = min(hardFloor + restingBottomMargin, max(hardFloor, ceilingY))
    return max(restingFloor, min(desired, ceilingY))
  }

  /// The owner's dragged point, made safe to restore, or nil when no current
  /// screen can host it.
  ///
  /// Returning nil is the self-heal: the caller drops the stored position and
  /// falls back to the automatic placement. Clamping instead would drag a point
  /// recorded on a disconnected 4K display onto the built-in screen and call it
  /// the owner's choice.
  ///
  /// A point a screen *does* hold is still clamped, because a screen can shrink
  /// (resolution change, menu bar, Dock) under a position that used to fit, and
  /// because the card has to keep its growth room: `reservedHeight` above the
  /// bottom edge, all of it on screen.
  static func validatedPinnedPoint(
    _ point: CGPoint,
    pillSize: CGSize,
    reservedHeight: CGFloat,
    visibleFrames: [NSRect]
  ) -> CGPoint? {
    guard let visible = visibleFrames.first(where: { $0.contains(point) }) else { return nil }
    guard pillSize.width + screenInset * 2 <= visible.width else { return nil }

    let halfWidth = pillSize.width / 2
    let x = min(
      max(point.x, visible.minX + screenInset + halfWidth),
      visible.maxX - screenInset - halfWidth
    )
    let hardFloor = visible.minY + screenInset
    let ceilingY = visible.maxY - screenInset - reservedHeight
    let y = max(hardFloor, min(point.y, max(hardFloor, ceilingY)))
    return CGPoint(x: x, y: y)
  }
}

// MARK: - Pill metrics

/// Sizing and motion constants for the pill, kept out of the views so the
/// width-stability guarantee can be asserted without laying anything out.
enum HUDPillMetrics {
  /// Width the rough-draft block claims as soon as there is any draft at all.
  ///
  /// The pill must widen exactly ONCE — when text starts — and then hold
  /// still. Letting the block size to its text made it step wider on almost
  /// every recognized word, which is the "awkward per-word width jumps" the
  /// redesign is about. A fixed block trades a little empty space on the first
  /// word for a pill that never moves sideways while the user is speaking.
  static let draftWidth: CGFloat = 420

  /// Lines of session text shown before head-truncation kicks in. Generous
  /// because the growing pill keeps every finalized line — 8 wrapped lines of
  /// a 420pt block is roughly three long sentences — and head-truncation only
  /// ever takes the oldest lines once a session outgrows it.
  static let draftLineLimit = 8

  /// The pill's own padding, gap and meter height, hoisted out of the views so
  /// the tallest the pill can become is arithmetic rather than a guess. The
  /// numbers are the ones `DictationHUDContentView` and `ListeningView` were
  /// already using; nothing about the rendering changes by naming them.
  static let horizontalPadding: CGFloat = 18
  static let verticalPadding: CGFloat = 12
  /// Gap between the header row (mic + meter) and the draft block below it.
  static let headerSpacing: CGFloat = 8
  /// Fixed height of the meter row — the pill's header.
  static let meterHeight: CGFloat = 26

  /// Height of one line of the draft block, from the font the block draws in,
  /// so the reserve corresponds to lines the owner can count.
  static var draftLineHeight: CGFloat {
    let font = NSFont.preferredFont(forTextStyle: .callout)
    return ceil(font.ascender - font.descender + font.leading)
  }

  /// Height of the pill (excluding the transparent shadow margin) carrying
  /// `lines` lines of draft, or the meter alone at `lines == 0`.
  static func cardHeight(lineCount lines: Int) -> CGFloat {
    let meterBlock = verticalPadding * 2 + meterHeight
    guard lines > 0 else { return meterBlock }
    return meterBlock + headerSpacing + CGFloat(lines) * draftLineHeight
  }

  /// The tallest the pill can become: `draftLineLimit` lines plus the header.
  ///
  /// This is what `reposition()` reserves ABOVE the pill. The pill grows upward
  /// with its bottom edge pinned, so without the reserve a pill anchored under
  /// a window near the top of the screen grows into `clamped`, which shoves the
  /// whole frame back down — and the bottom edge the growth rule pins walks
  /// downward one line at a time. That is exactly the "it grows downward again"
  /// regression: the growth direction was right, the placement never reserved
  /// room for it because the pill still declared itself a style that cannot
  /// grow.
  static var maxCardHeight: CGFloat { cardHeight(lineCount: draftLineLimit) }

  static let frameDuration: TimeInterval = 0.26

  /// Spring-ish settle: fast out, long decelerating tail, no overshoot (an
  /// overshooting window frame reads as a glitch, not as bounce).
  static let frameTiming = CAMediaTimingFunction(controlPoints: 0.22, 0.9, 0.24, 1)

  /// Width the draft block occupies for `draft`, or nil when there is no draft
  /// and the pill is meter-only. Constant by construction — see `draftWidth`.
  static func draftBlockWidth(for draft: String?) -> CGFloat? {
    guard let draft, !draft.isEmpty else { return nil }
    return draftWidth
  }
}

// MARK: - HUD Content View

struct DictationHUDContentView: View {
  let state: HUDState
  /// Streaming rough draft (already clamped by `StreamingDelivery.roughDraftTail`).
  var roughDraft: String?

  var body: some View {
    // **The body is the glass, and the glass is not drawn here.** The pill's
    // material is an `NSGlassEffectView` laid out at exactly this rect by
    // `GlassBackingView`, because a SwiftUI glass modifier inside a transparent
    // panel refracts only its own hierarchy and reads as a flat blur. What is
    // left in SwiftUI is the content, the semantic wash for the two states that
    // have one, and — unchanged — the padding, which is what every pinned
    // fitting-size baseline measures.
    if case .hidden = state {
      Color.clear.frame(width: 0, height: 0)
    } else {
      content
        .padding(.horizontal, HUDPillMetrics.horizontalPadding)
        .padding(.vertical, HUDPillMetrics.verticalPadding)
        // Warning and error only. A neutral fill here would be the flat body
        // again, painted over the material that replaced it; a wash is the one
        // thing glass cannot say for itself.
        .background { if let tint = stateTint { pillShape.fill(tint) } }
        // Likewise the hairline: the glass carries its own rim, and a second
        // stroke on top of it is the doubled outline the toolbar pills already
        // taught us to stop drawing. Warning and error keep theirs, because it
        // is semantic rather than structural.
        .overlay { if let stroke = semanticStrokeColor {
          pillShape.strokeBorder(stroke, lineWidth: 0.5)
        } }
        .environment(\.colorScheme, .dark)
        // Margin gives the glass its inset inside the window — a window cannot
        // draw outside its own frame, and the material's own shadow and rim need
        // the room the pill's SwiftUI shadow used to fall into.
        .padding(Self.shadowMargin)
      // Deliberately no `.animation(value: state)` here: it animated the
      // pill's layout at the same time DictationHUDPanel.update animated the
      // window around it, and the two curves fighting is the jitter. The
      // window frame is the sole animation authority; the only SwiftUI
      // animation left is the meter's, inside a fixed-height frame.
    }
  }

  /// Transparent margin around the pill: the glass plate's inset, and the room
  /// its shadow falls into.
  static let shadowMargin: CGFloat = 24

  /// Warning/error messages allow two lines; a Capsule's end-caps grow with
  /// height and a two-line pill stretches into a lozenge. A fixed continuous
  /// corner matches the capsule at single-line height but caps the growth.
  private var pillShape: HUDPillShape {
    switch state {
    case .warning, .error:
      return HUDPillShape(cappedCornerRadius: 20)
    default:
      return HUDPillShape(cappedCornerRadius: nil)
    }
  }

  /// Warning/error wash blended over the dark body; glyphs keep the
  /// saturated semantic color. Error reads clearly stronger than warning so
  /// the tint carries the semantic at a glance, not the glyph alone.
  private var stateTint: Color? {
    switch state {
    case .error: return .red.opacity(0.32)
    case .warning: return .orange.opacity(0.2)
    default: return nil
    }
  }

  /// The stroke that says something, as opposed to the one that separated the
  /// pill from its background — the glass's own rim does that now. Nil for every
  /// state that has nothing semantic to say.
  private var semanticStrokeColor: Color? {
    switch state {
    case .error: return .red.opacity(0.55)
    case .warning: return .orange.opacity(0.5)
    default: return nil
    }
  }

  @ViewBuilder
  private var content: some View {
    switch state {
    case .hidden:
      EmptyView()
    case .listening(let level):
      ListeningView(level: level, roughDraft: roughDraft)
    case .processing(let step):
      ProcessingView(step: step)
    case .success(let snippet):
      SuccessView(snippet: snippet)
    case .warning(let message):
      WarningView(message: message)
    case .error(let message):
      ErrorView(message: message)
    }
  }
}

/// The pill background: a Capsule when `cappedCornerRadius` is nil, otherwise
/// a continuous rounded rectangle whose corner radius never exceeds the
/// capsule's (half the height) — identical to the capsule at single-line
/// height, but flat-sided instead of lozenge-shaped when the content wraps.
private struct HUDPillShape: InsettableShape {
  var cappedCornerRadius: CGFloat?
  var insetAmount: CGFloat = 0

  func path(in rect: CGRect) -> Path {
    let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
    guard rect.width > 0, rect.height > 0 else { return Path() }
    guard let cappedCornerRadius else { return Capsule().path(in: rect) }
    let radius = min(cappedCornerRadius, min(rect.width, rect.height) / 2)
    return Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
  }

  func inset(by amount: CGFloat) -> HUDPillShape {
    var shape = self
    shape.insetAmount += amount
    return shape
  }
}

// MARK: - Sub-views

private struct ListeningView: View {
  let level: Float
  /// Streaming only: the recognizer's un-finalized tail. Nil renders the meter
  /// alone, exactly as the pill looked before streaming delivery existed.
  var roughDraft: String?

  private static let barCount = 9
  /// Center-weighted silhouette — Apple's voice UIs (Siri, Voice Memos)
  /// peak in the middle and taper outward, rather than ramping left-to-right
  /// like an equalizer.
  private static let profile: [CGFloat] = [0.35, 0.55, 0.8, 0.95, 1.0, 0.95, 0.8, 0.55, 0.35]

  var body: some View {
    if let width = HUDPillMetrics.draftBlockWidth(for: roughDraft) {
      // Header (the centered mic + meter) on TOP, the draft below it. The panel
      // grows UPWARD with its bottom edge pinned, so the newest line of the
      // draft is the one that sits on the anchor and never moves, and the header
      // rides up as the session gets longer. The earlier order — draft above the
      // meter — put the *meter* on the fixed edge and made the reading line
      // climb away from it.
      VStack(alignment: .center, spacing: HUDPillMetrics.headerSpacing) {
        meter
        Text(roughDraft ?? "")
          .font(.callout)
          .foregroundStyle(.primary.opacity(0.85))
          .lineLimit(HUDPillMetrics.draftLineLimit)
          // Head truncation, not tail: once the session outgrows the block the
          // OLDEST lines go, so the bottom line is always the newest words.
          .truncationMode(.head)
          .multilineTextAlignment(.leading)
          // Fixed width, so the pill's width is decided by the presence of a
          // draft and never by its length; only the height moves after that.
          .frame(width: width, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      }
    } else {
      meter
    }
  }

  private var meter: some View {
    HStack(spacing: 8) {
      Image(systemName: "mic.fill")
        .foregroundStyle(.red)
        .font(.system(size: 15, weight: .medium))

      // The timeline phase adds a slow low-amplitude breathing so the meter
      // never freezes at steady input — a still meter reads as dead.
      TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
        let phase = timeline.date.timeIntervalSinceReferenceDate
        HStack(spacing: 3) {
          ForEach(0..<Self.barCount, id: \.self) { i in
            Capsule()
              .fill(.primary)
              .frame(width: 3.5, height: barHeight(for: i, phase: phase))
          }
        }
        .frame(height: HUDPillMetrics.meterHeight)
        // One spring for all bars, driven by the level: overshoot + settle is
        // what makes the meter feel alive instead of stepped.
        .animation(.spring(response: 0.28, dampingFraction: 0.55), value: level)
      }
    }
  }

  private func barHeight(for index: Int, phase: TimeInterval) -> CGFloat {
    let base: CGFloat = 5
    let maxH: CGFloat = 24
    // Per-bar wobble keyed to index and level so neighbors never move in
    // lockstep — lockstep is the "cheap" tell.
    let wobble = 0.72 + 0.28 * sin(Double(index) * 1.7 + Double(level) * 21)
    // Idle breathing: neighbors offset so the swell travels across the bars.
    let breathe = 0.05 + 0.04 * sin(phase * 2.1 + Double(index) * 0.8)
    let drive = CGFloat(level) * Self.profile[index] * CGFloat(wobble) + CGFloat(breathe)
    let h = base + (maxH - base) * drive
    return min(maxH, max(base, h))
  }
}

private struct ProcessingView: View {
  let step: String

  var body: some View {
    HStack(spacing: 8) {
      ProgressView()
        .scaleEffect(0.8)
        .frame(width: 14, height: 14)
      Text(step)
        .font(.subheadline)
    }
  }
}

private struct SuccessView: View {
  let snippet: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .font(.system(size: 14, weight: .medium))

      if !snippet.isEmpty {
        Text("\"\(snippet.prefix(40))\(snippet.count > 40 ? "…" : "")\"")
          .font(.subheadline)
          .lineLimit(1)
      }
    }
  }
}

private struct WarningView: View {
  let message: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .font(.system(size: 14, weight: .medium))

      Text(message)
        .font(.subheadline)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct ErrorView: View {
  let message: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "xmark.circle.fill")
        .foregroundStyle(.red)
        .font(.system(size: 14, weight: .medium))

      Text(message)
        .font(.subheadline)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
