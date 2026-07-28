import AppKit
import ApplicationServices
import SwiftUI
import os

// MARK: - DictationHUDPanel

/// Non-activating floating panel that hosts the HUD pill.
///
/// Constrained to never take key focus: uses `.nonactivatingPanel` style mask,
/// `.statusBar` level, and `ignoresMouseEvents = true` so dictation injection
/// always targets the app the user is typing into.
@MainActor
final class DictationHUDPanel: NSPanel {
  private static let logger = Logger(subsystem: "com.xiafawu.nota", category: "dictation.hud")

  private let hostingView: NSHostingView<DictationHUDRootView>

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
    ignoresMouseEvents = true
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

    contentView = hostingView
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
  func update(state: HUDState, draft: HUDDraft = .empty, style: HUDStyle = .pill) {
    let styleChanged = style != self.style
    self.style = style
    hostingView.rootView = DictationHUDRootView(style: style, state: state, draft: draft)
    hostingView.layoutSubtreeIfNeeded()
    let size = hostingView.fittingSize

    var frame = self.frame
    // Sub-point churn is not worth restarting a 0.26s animation for, and this
    // runs on every throttled RMS tick.
    guard abs(size.width - frame.width) > 0.5 || abs(size.height - frame.height) > 0.5
    else { return }
    // Grow DOWN, not up: the HUD hangs 12pt below the focused window's bottom
    // edge (see reposition()), so a bottom-anchored resize would push a
    // two-line draft up into that window. Fixed maxY keeps the gap.
    frame.origin.y -= size.height - frame.size.height
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
  /// within the screen's visible area. Growing downward can otherwise walk the
  /// pill off the bottom of the screen.
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
      // The prompter is the one style that grows after it is placed, and it is
      // placed high enough for all of that growth. See `reservedCardHeight`.
      reservedHeight: style.reservedCardHeight ?? pillSize.height
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

// MARK: - Panel layout

/// Where the HUD hangs, as arithmetic — no NSScreen, no window server.
enum HUDPanelLayout {
  /// Gap between the anchor window's bottom edge and the pill's top edge.
  static let anchorGap: CGFloat = 12
  /// Smallest gap kept between the pill and the edges of the visible screen.
  static let screenInset: CGFloat = 8

  /// The pill's bottom-edge y for one anchor window, one screen, and a style
  /// that may still grow to `reservedHeight`.
  ///
  /// `reservedHeight` is the whole point. `DictationHUDPanel.update` grows a
  /// card **downward** with its top edge pinned, because the HUD hangs under
  /// the focused window and a bottom-anchored resize would push it up into that
  /// window. But `clamped` then shoves the frame back onto the screen, and when
  /// the anchor window's own bottom edge is already at the screen's bottom
  /// there is nowhere for the growth to go: every extra line moves the top edge
  /// up into the window, one line at a time. Reserving the growth room at
  /// placement time means the clamp never has anything to correct, so the top
  /// edge really does hold still.
  ///
  /// Styles that cannot grow (or whose placement is the untouched baseline)
  /// pass their current height and get exactly the old arithmetic.
  static func pillOriginY(
    anchorMinY: CGFloat?,
    screenFrame: NSRect,
    pillHeight: CGFloat,
    reservedHeight: CGFloat
  ) -> CGFloat {
    let ceilingY = screenFrame.maxY - pillHeight - screenInset
    let growth = max(0, reservedHeight - pillHeight)
    // Never above the ceiling: on a screen too short to hold the fully grown
    // card, staying on screen beats reserving room that does not exist.
    let floorY = min(screenFrame.minY + screenInset + growth, ceilingY)
    let desired = anchorMinY.map { $0 - anchorGap - pillHeight } ?? screenFrame.minY + 60
    return max(floorY, min(desired, ceilingY))
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

  /// Lines of rough draft shown before head-truncation kicks in.
  static let draftLineLimit = 2

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
    // Solid dark capsule (Wispr Flow / macOS dictation indicator grammar):
    // fixed dark translucent body, light content forced via dark color
    // scheme — legible over any background, never washes out. Deliberate
    // pivot away from adaptive Liquid Glass, which reads light-and-frosted
    // over light content.
    if case .hidden = state {
      Color.clear.frame(width: 0, height: 0)
    } else {
      content
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background {
          ZStack {
            pillShape.fill(Color(white: 0.09).opacity(0.9))
            if let tint = stateTint {
              pillShape.fill(tint)
            }
          }
        }
        .overlay {
          pillShape
            .strokeBorder(strokeColor, lineWidth: 0.5)
        }
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.24), radius: 10, y: 3)
        // Margin gives the shadow room to fall off INSIDE the window — a
        // window cannot draw outside its own frame, and without this the
        // shadow renders as a dark rectangle filling the pill-sized window.
        .padding(Self.shadowMargin)
      // Deliberately no `.animation(value: state)` here: it animated the
      // pill's layout at the same time DictationHUDPanel.update animated the
      // window around it, and the two curves fighting is the jitter. The
      // window frame is the sole animation authority; the only SwiftUI
      // animation left is the meter's, inside a fixed-height frame.
    }
  }

  /// Transparent margin around the pill reserved for its drop shadow.
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

  /// Hairline carries the pill's separation on dark backgrounds; warning and
  /// error tint it with their semantic color to reinforce the wash.
  private var strokeColor: Color {
    switch state {
    case .error: return .red.opacity(0.55)
    case .warning: return .orange.opacity(0.5)
    default: return .white.opacity(0.25)
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
      // Rough draft above a CENTERED mic+meter: the draft is the thing worth
      // reading, and the meter is the thing that must not drift sideways.
      VStack(alignment: .center, spacing: 8) {
        Text(roughDraft ?? "")
          .font(.callout)
          .foregroundStyle(.primary.opacity(0.85))
          .lineLimit(HUDPillMetrics.draftLineLimit)
          .truncationMode(.head)
          .multilineTextAlignment(.leading)
          // Fixed width, so the pill's width is decided by the presence of a
          // draft and never by its length; only the height moves after that.
          .frame(width: width, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
        meter
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
        .frame(height: 26)
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
