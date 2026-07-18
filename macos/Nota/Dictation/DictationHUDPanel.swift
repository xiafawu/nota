import AppKit
import ApplicationServices
import SwiftUI

// MARK: - DictationHUDPanel

/// Non-activating floating panel that hosts the HUD pill.
///
/// Constrained to never take key focus: uses `.nonactivatingPanel` style mask,
/// `.statusBar` level, and `ignoresMouseEvents = true` so dictation injection
/// always targets the app the user is typing into.
@MainActor
final class DictationHUDPanel: NSPanel {
  private let hostingView: NSHostingView<DictationHUDContentView>

  init() {
    hostingView = NSHostingView(rootView: DictationHUDContentView(state: .hidden))

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
    level = .statusBar
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    ignoresMouseEvents = true
    hidesOnDeactivate = false
    isFloatingPanel = true

    contentView = hostingView
  }

  /// Update the HUD content and resize the panel to fit. Size changes are
  /// animated (center-anchored) so state swaps glide instead of snapping.
  func update(state: HUDState) {
    hostingView.rootView = DictationHUDContentView(state: state)
    hostingView.setFrameSize(hostingView.fittingSize)
    let size = hostingView.fittingSize

    var frame = self.frame
    guard size != frame.size else { return }
    frame.origin.x -= (size.width - frame.size.width) / 2
    frame.size = size

    if isVisible {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.22
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animator().setFrame(frame, display: true)
      }
    } else {
      setFrame(frame, display: true)
    }
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

    let pillCenterX: CGFloat
    let pillOriginY: CGFloat

    if let anchorFrame {
      pillCenterX = anchorFrame.midX
      // Pill top edge 12pt below the anchor window's bottom edge.
      pillOriginY = anchorFrame.minY - 12 - pillSize.height
    } else {
      pillCenterX = screenFrame.midX
      pillOriginY = screenFrame.minY + 60
    }

    // Clamp the pill 8pt inside the visible screen, then convert back to a
    // window-frame origin by re-adding the shadow margin.
    let pillX = max(
      screenFrame.minX + 8,
      min(pillCenterX - pillSize.width / 2, screenFrame.maxX - pillSize.width - 8)
    )
    let pillY = max(
      screenFrame.minY + 8,
      min(pillOriginY, screenFrame.maxY - pillSize.height - 8)
    )

    setFrameOrigin(NSPoint(x: pillX - margin, y: pillY - margin))
  }

  /// Frame (Cocoa coordinates) of the focused window of the frontmost app,
  /// via the Accessibility API. Returns nil when the frontmost app is Nota
  /// itself or the window can't be read (no AX grant, no focused window).
  private static func frontmostAppFocusedWindowFrame() -> NSRect? {
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

  func show() {
    guard !isVisible else {
      orderFrontRegardless()
      return
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

// MARK: - HUD Content View

struct DictationHUDContentView: View {
  let state: HUDState

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
        .contentTransition(.opacity)
        .animation(.easeOut(duration: 0.18), value: state)
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
      ListeningView(level: level)
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

  private static let barCount = 9
  /// Center-weighted silhouette — Apple's voice UIs (Siri, Voice Memos)
  /// peak in the middle and taper outward, rather than ramping left-to-right
  /// like an equalizer.
  private static let profile: [CGFloat] = [0.35, 0.55, 0.8, 0.95, 1.0, 0.95, 0.8, 0.55, 0.35]

  var body: some View {
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
