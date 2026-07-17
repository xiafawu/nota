import AppKit
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
  /// Real Liquid Glass for a floating window: SwiftUI's `glassEffect` inside
  /// an `NSHostingView` can only refract sibling SwiftUI content, and a
  /// transparent panel has none — it degrades to a flat blur. AppKit's
  /// `NSGlassEffectView` composites glass against whatever is behind the
  /// WINDOW (desktop, other apps), which is the actual Liquid Glass look.
  private let glassView: NSGlassEffectView

  init() {
    hostingView = NSHostingView(rootView: DictationHUDContentView(state: .hidden))
    hostingView.translatesAutoresizingMaskIntoConstraints = false

    glassView = NSGlassEffectView()
    // .clear is the visibly-glassy variant (transparent, strong lensing);
    // .regular renders as a frosted plate that reads as plain blur over
    // typical light backdrops.
    glassView.style = .clear
    glassView.contentView = hostingView

    let rect = NSRect(x: 0, y: 0, width: 200, height: 48)
    super.init(
      contentRect: rect,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    level = .statusBar
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    ignoresMouseEvents = true
    hidesOnDeactivate = false
    isFloatingPanel = true

    contentView = glassView
  }

  /// Update the HUD content and resize the panel to fit. Size changes are
  /// animated (center-anchored) so state swaps glide instead of snapping.
  func update(state: HUDState) {
    hostingView.rootView = DictationHUDContentView(state: state)
    hostingView.setFrameSize(hostingView.fittingSize)
    let size = hostingView.fittingSize

    // Capsule: full-height rounding. Tint the glass itself for
    // warning/error states; glyphs carry the saturated color.
    glassView.cornerRadius = size.height / 2
    glassView.tintColor = Self.tint(for: state)

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

  private static func tint(for state: HUDState) -> NSColor? {
    switch state {
    case .error: return NSColor.systemRed.withAlphaComponent(0.35)
    case .warning: return NSColor.systemOrange.withAlphaComponent(0.3)
    default: return nil
    }
  }

  /// Position the panel centered below the frontmost window.
  /// Falls back to the main screen center when no window is available.
  func reposition(belowFrontmostWindow: Bool = true) {
    guard let screen = (belowFrontmostWindow ? NSApp.keyWindow?.screen : nil)
            ?? NSApp.mainWindow?.screen
            ?? NSScreen.main
    else { return }

    let screenFrame = screen.visibleFrame
    let panelSize = frame.size

    // Position: centered horizontally, just above the dock / below the frontmost window
    let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
    let windowFrame = targetWindow?.frame

    let centerX: CGFloat
    let originY: CGFloat

    if let windowFrame {
      centerX = windowFrame.midX
      // Place 12pt below the window's bottom edge, or above the dock
      originY = min(windowFrame.minY - panelSize.height - 12, screenFrame.maxY - panelSize.height - 8)
    } else {
      centerX = screenFrame.midX
      originY = screenFrame.minY + 60
    }

    let x = max(screenFrame.minX + 8, min(centerX - panelSize.width / 2, screenFrame.maxX - panelSize.width - 8))
    let y = max(screenFrame.minY + 8, originY)

    setFrameOrigin(NSPoint(x: x, y: y))
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
    // Glass lives on the panel's NSGlassEffectView (see DictationHUDPanel);
    // the SwiftUI layer is content-only so the glass refracts the desktop
    // behind the window instead of an empty hierarchy.
    if case .hidden = state {
      Color.clear.frame(width: 0, height: 0)
    } else {
      content
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .contentTransition(.opacity)
        .animation(.easeOut(duration: 0.18), value: state)
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

      HStack(spacing: 3) {
        ForEach(0..<Self.barCount, id: \.self) { i in
          Capsule()
            .fill(.primary)
            .frame(width: 3.5, height: barHeight(for: i))
        }
      }
      .frame(height: 26)
      // One spring for all bars, driven by the level: overshoot + settle is
      // what makes the meter feel alive instead of stepped.
      .animation(.spring(response: 0.28, dampingFraction: 0.55), value: level)
    }
  }

  private func barHeight(for index: Int) -> CGFloat {
    let base: CGFloat = 5
    let maxH: CGFloat = 24
    // Per-bar wobble keyed to index and level so neighbors never move in
    // lockstep — lockstep is the "cheap" tell.
    let wobble = 0.72 + 0.28 * sin(Double(index) * 1.7 + Double(level) * 21)
    let h = base + (maxH - base) * CGFloat(level) * Self.profile[index] * CGFloat(wobble)
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
