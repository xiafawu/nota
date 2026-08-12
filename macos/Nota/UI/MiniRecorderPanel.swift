import AppKit
import SwiftUI
import os

// MARK: - The window, as the controller sees it

/// One island window. Injectable so the presenter's "checked onto the screen,
/// one recreate, then a visible failure" escalation can be driven without a
/// window server.
@MainActor
protocol MiniRecorderWindowing: AnyObject {
  /// Put the island on screen. **Returns whether it actually got there** —
  /// `orderFrontRegardless()` has silently produced no window before
  /// (`windowNumber == 0` for a day, 2026-07-27), and a swallowed no-op here is
  /// a recording session with no indicator anywhere.
  @discardableResult
  func present() -> Bool
  func dismiss()
  /// Place the card, honouring a dragged position if one survives validation.
  func reposition()
  var glassTintAlpha: Double { get set }
  var glassMaterial: GlassMaterial { get set }
}

/// The island as the controller sees it. The same shape
/// `DictationReviewPresenting` established: `show` reports whether it reached
/// the screen, every mutator is a no-op when nothing is up, and the settings
/// that can move while a surface is on screen are presenter-level properties.
@MainActor
protocol MiniRecorderPresenting: AnyObject {
  var isPresenting: Bool { get }
  @discardableResult
  func show(_ render: MiniIslandRender, perform: @escaping (MiniIslandAction) -> Void) -> Bool
  func update(_ render: MiniIslandRender)
  func dismiss()
  var glassTintAlpha: Double { get set }
  var glassMaterial: GlassMaterial { get set }
}

// MARK: - Presenter

@MainActor
final class MiniRecorderPresenter: MiniRecorderPresenting {
  private static let logger = Logger(subsystem: "com.xiafawu.nota", category: "island")

  /// The card's view model, shared with whatever window is current: a recreate
  /// swaps the NSPanel and keeps the state the owner was looking at.
  let model = MiniIslandModel()

  private var window: MiniRecorderWindowing?
  private let makeWindow: @MainActor (MiniIslandModel) -> MiniRecorderWindowing
  private(set) var isPresenting = false

  var glassTintAlpha: Double = GlassTint.standard {
    didSet { window?.glassTintAlpha = GlassTint.clamped(glassTintAlpha) }
  }

  var glassMaterial: GlassMaterial = .standard {
    didSet { window?.glassMaterial = glassMaterial }
  }

  init(
    makeWindow: @escaping @MainActor (MiniIslandModel) -> MiniRecorderWindowing = {
      MiniRecorderPanel(model: $0)
    }
  ) {
    self.makeWindow = makeWindow
  }

  @discardableResult
  func show(_ render: MiniIslandRender, perform: @escaping (MiniIslandAction) -> Void) -> Bool {
    model.perform = perform
    model.apply(render)

    if window != nil, isPresenting { return true }

    let existing = window ?? configuredWindow()
    window = existing
    if orderOn(existing) {
      isPresenting = true
      return true
    }

    // A dead server-side window can only be replaced, and exactly **once** —
    // the bounded heal `HUDVisibilityMonitor` does for the pill. Two failures in
    // a row is a WindowServer nobody here can argue with, and the answer is to
    // say so rather than to keep building panels.
    existing.dismiss()
    window = nil

    let fresh = configuredWindow()
    guard orderOn(fresh) else {
      Self.logger.fault("Mini-recorder island could not be put on screen after one recreate")
      fresh.dismiss()
      isPresenting = false
      return false
    }
    window = fresh
    isPresenting = true
    return true
  }

  private func configuredWindow() -> MiniRecorderWindowing {
    let window = makeWindow(model)
    window.glassTintAlpha = GlassTint.clamped(glassTintAlpha)
    window.glassMaterial = glassMaterial
    return window
  }

  private func orderOn(_ window: MiniRecorderWindowing) -> Bool {
    window.reposition()
    return window.present()
  }

  func update(_ render: MiniIslandRender) {
    guard isPresenting else { return }
    model.apply(render)
  }

  func dismiss() {
    guard isPresenting else { return }
    isPresenting = false
    window?.dismiss()
  }
}

// MARK: - The panel

/// The island's `NSPanel`.
///
/// Six things it inherits, each of which is a bug somebody already paid for:
///
/// 1. **AppKit Liquid Glass** (`GlassBackingView`). A SwiftUI `.glassEffect`
///    inside a transparent panel refracts only its own hierarchy and renders as
///    a flat blur — measured; `NSGlassEffectView` refracts the screen behind the
///    panel, which is the entire point on something that floats.
/// 2. **`appearance = .darkAqua` on the panel itself.** A SwiftUI
///    `.colorScheme` is an environment value and does not change an NSWindow's
///    `effectiveAppearance`, which is what every AppKit-drawn piece inside
///    follows.
/// 3. **`orderFrontRegardless` verified**, one recreate (in the presenter), then
///    a visible failure.
/// 4. **`.nonactivatingPanel`, and nothing on this path activates Nota.** The
///    island is never typed into, so unlike the review card it does **not**
///    override `canBecomeKey`.
/// 5. **Its own position store** (`IslandPositionStore`) — the HUD pins a
///    bottom-center and the review card a top-left, and a shared point would
///    mean dragging one surface moved another through an anchor that means
///    nothing on the far side.
/// 6. **`level` assigned AFTER `isFloatingPanel`.** See the assignment below.
@MainActor
final class MiniRecorderPanel: NSPanel, MiniRecorderWindowing {
  private static let logger = Logger(subsystem: "com.xiafawu.nota", category: "island")

  private let hostingView: IslandHostingView<MiniRecorderIslandView>
  private let backingView = GlassBackingView(inset: MiniIslandMetrics.shadowMargin)

  /// Where the owner dragged the island, as the CARD rect's **top-left** in
  /// screen coordinates. Top-left because this card is a constant size in every
  /// phase — nothing about it grows, so there is no edge whose meaning has to
  /// survive growth the way the HUD's bottom edge does.
  private(set) var pinnedCardTopLeft: CGPoint?

  private var dragAnchor: (mouse: NSPoint, origin: NSPoint)?

  init(model: MiniIslandModel) {
    hostingView = IslandHostingView(rootView: MiniRecorderIslandView(model: model))
    super.init(
      contentRect: NSRect(origin: .zero, size: MiniIslandMetrics.windowSize),
      // Borderless: the card draws its own chrome. Nonactivating: the island
      // must never make Nota the active app — it exists because the owner is
      // looking at something else.
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    isOpaque = false
    backgroundColor = .clear
    // A window shadow can only draw INSIDE the frame, which turns it into a
    // dark rectangle behind a capsule. The shadow lives in the SwiftUI margin.
    hasShadow = false
    hidesOnDeactivate = false
    // The heal `close()`s a panel the presenter still holds.
    isReleasedWhenClosed = false
    // The card is dragged by a SwiftUI gesture, and that gesture is the only
    // mover: AppKit's background drag reports nothing, and "the owner chose
    // this position" is precisely the fact that has to be remembered.
    isMovableByWindowBackground = false
    // The island has buttons, so it must take mouse events. The cost is the
    // HUD's: clicks on the island's own rectangle stop passing through. It is
    // nonactivating and never key, so a click still cannot raise Nota.
    ignoresMouseEvents = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    isFloatingPanel = true
    // AFTER isFloatingPanel: setting `isFloatingPanel = true` SILENTLY REWRITES
    // `level` to .floating (CGWindowLayer 3), which sits BELOW a fullscreen app.
    // This panel exists to float over a fullscreen video call, so the trap that
    // merely inconveniences the HUD would make this surface useless.
    // .statusBar is CGWindowLayer 25.
    level = .statusBar
    // Every AppKit-drawn piece inside the hosting view follows the WINDOW's
    // appearance, not the SwiftUI environment — and Settings → General may have
    // pinned NSApp.appearance to Light.
    appearance = NSAppearance(named: .darkAqua)

    backingView.glassCornerRadius = MiniIslandMetrics.cornerRadius
    backingView.setContent(hostingView)
    contentView = backingView

    pinnedCardTopLeft = IslandPositionStore.load()
    model.onDragChanged = { [weak self] in self?.dragChanged() }
    model.onDragEnded = { [weak self] in self?.dragEnded() }
  }

  /// The island is never typed into, so it never becomes key — unlike the
  /// review card, which overrides this. Said explicitly because the difference
  /// between the two panels is deliberate.
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  var glassTintAlpha: Double = GlassTint.standard {
    didSet { backingView.tintAlpha = GlassTint.clamped(glassTintAlpha) }
  }

  var glassMaterial: GlassMaterial = .standard {
    didSet { backingView.material = glassMaterial }
  }

  // MARK: Presentation

  @discardableResult
  func present() -> Bool {
    // `orderFrontRegardless()` rather than `makeKeyAndOrderFront(_:)`: ordering
    // front from an inactive app is otherwise deferred until the app activates,
    // and nothing on this path ever activates Nota.
    orderFrontRegardless()
    return verifyWindowDevice()
  }

  func dismiss() {
    orderOut(nil)
  }

  /// True when AppKit gave this panel a server-side window.
  @discardableResult
  func verifyWindowDevice() -> Bool {
    let number = windowNumber
    guard number <= 0 else { return true }
    Self.logger.error(
      """
      Island panel has no window device after orderFrontRegardless \
      (windowNumber=\(number, privacy: .public), \
      isVisible=\(self.isVisible, privacy: .public)) — zombie WindowServer state.
      """
    )
    return false
  }

  // MARK: Dragging

  /// Follow the pointer, measured against `NSEvent.mouseLocation` — absolute
  /// screen coordinates — never against the gesture's own translation, whose
  /// coordinate space is anchored to the window this call is moving.
  func dragChanged() {
    if dragAnchor == nil {
      dragAnchor = (mouse: NSEvent.mouseLocation, origin: frame.origin)
    }
    guard let anchor = dragAnchor else { return }
    let now = NSEvent.mouseLocation
    setFrameOrigin(
      NSPoint(
        x: anchor.origin.x + now.x - anchor.mouse.x,
        y: anchor.origin.y + now.y - anchor.mouse.y
      )
    )
  }

  func dragEnded() {
    defer { dragAnchor = nil }
    guard dragAnchor != nil else { return }
    let margin = MiniIslandMetrics.shadowMargin
    let card = frame.insetBy(dx: margin, dy: margin)
    let point = CGPoint(x: card.minX, y: card.maxY)
    pinnedCardTopLeft = point
    IslandPositionStore.save(point)
  }

  // MARK: Placement

  func reposition() {
    let margin = MiniIslandMetrics.shadowMargin
    let card = MiniIslandMetrics.cardSize
    let visibleFrames = NSScreen.screens.map(\.visibleFrame)

    // The owner's own position outranks the automatic placement, and is
    // validated rather than trusted every time: a point no current screen can
    // host is DROPPED and the automatic placement is the self-heal. Clamping it
    // onto whatever display is left would call an arbitrary point their choice.
    if let pinned = pinnedCardTopLeft {
      if let topLeft = IslandPanelLayout.validatedTopLeft(
        pinned,
        cardSize: card,
        visibleFrames: visibleFrames
      ) {
        setFrameOrigin(NSPoint(x: topLeft.x - margin, y: topLeft.y - card.height - margin))
        return
      }
      pinnedCardTopLeft = nil
      IslandPositionStore.clear()
    }

    let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
      ?? NSScreen.main
    guard let visible = screen?.visibleFrame else { return }
    let topLeft = IslandPanelLayout.defaultTopLeft(cardSize: card, visible: visible)
    setFrameOrigin(NSPoint(x: topLeft.x - margin, y: topLeft.y - card.height - margin))
  }
}

// MARK: - Hosting

/// The island's hosting view, for one override.
///
/// **`acceptsFirstMouse` is true**, and this is the app's first floating panel
/// that has interactive controls *and* refuses to become key: the HUD has no
/// controls, and the review card overrides `canBecomeKey` to true because the
/// owner types in it. AppKit's default is to swallow the click that would
/// otherwise activate a window — which on a panel that can never be activated
/// means Mark and Stop would take two presses every time, and the whole point
/// of this surface is one press while the owner is looking at another app. No
/// test in this bundle can see it (the action tests drive `perform(_:)`, never
/// a click), so it is written down here rather than discovered by hand a second
/// time.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Position

/// Where the owner dragged the island, across launches.
///
/// **Its own key**, deliberately not `HUDPositionStore`'s and not
/// `ReviewPositionStore`'s. The mechanism is shared — validate-or-drop on
/// restore, the owner's point outranks the automatic placement — and the stored
/// value is not: the HUD pins a pill's bottom-center because it grows upward and
/// changes shape, this card is constant-size and pins its top-left. One shared
/// point would mean dragging either surface moved the other, through an anchor
/// that means nothing on the far side.
///
/// Backed by `DictationSettingsStore.defaults`, which is a private wiped suite
/// under XCTest: a test that drags the island must not move the owner's real one.
enum IslandPositionStore {
  static let key = "com.xiafawu.nota.miniRecorderPosition"

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

/// Where the island sits, as arithmetic — no NSScreen, no window server.
enum IslandPanelLayout {
  /// Smallest gap kept between the card and the edges of the visible screen.
  static let screenInset: CGFloat = 8
  /// Where the island rests when the owner has not moved it: near the bottom of
  /// the screen, clear of the Dock, on the same reasoning as
  /// `HUDPanelLayout.restingBottomMargin` — the last few points of a screen read
  /// as half off it.
  static let restingBottomMargin: CGFloat = 56

  static func defaultTopLeft(cardSize: CGSize, visible: NSRect) -> CGPoint {
    let x = min(
      max(visible.midX - cardSize.width / 2, visible.minX + screenInset),
      max(visible.maxX - screenInset - cardSize.width, visible.minX + screenInset)
    )
    let bottom = max(visible.minY + restingBottomMargin, visible.minY + screenInset)
    let y = min(bottom + cardSize.height, visible.maxY - screenInset)
    return CGPoint(x: x, y: y)
  }

  /// The owner's dragged top-left, made safe to restore, or nil when no current
  /// screen can host it. Returning nil is the self-heal.
  static func validatedTopLeft(
    _ point: CGPoint,
    cardSize: CGSize,
    visibleFrames: [NSRect]
  ) -> CGPoint? {
    guard let visible = visibleFrames.first(where: { $0.contains(point) }) else { return nil }
    guard cardSize.width + screenInset * 2 <= visible.width,
          cardSize.height + screenInset * 2 <= visible.height
    else { return nil }

    let x = min(
      max(point.x, visible.minX + screenInset),
      visible.maxX - screenInset - cardSize.width
    )
    let y = min(
      max(point.y, visible.minY + screenInset + cardSize.height),
      visible.maxY - screenInset
    )
    return CGPoint(x: x, y: y)
  }
}
