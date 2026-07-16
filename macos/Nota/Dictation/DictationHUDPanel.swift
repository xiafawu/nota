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

  init() {
    hostingView = NSHostingView(rootView: DictationHUDContentView(state: .hidden))
    hostingView.translatesAutoresizingMaskIntoConstraints = false

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

    contentView = hostingView
  }

  /// Update the HUD content and resize the panel to fit.
  func update(state: HUDState) {
    hostingView.rootView = DictationHUDContentView(state: state)
    hostingView.setFrameSize(hostingView.fittingSize)
    let size = hostingView.fittingSize
    var frame = self.frame
    frame.size = size
    setFrame(frame, display: true)
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
    orderFrontRegardless()
  }

  func hide() {
    orderOut(nil)
  }
}

// MARK: - HUD Content View

struct DictationHUDContentView: View {
  let state: HUDState

  var body: some View {
    Group {
      switch state {
      case .hidden:
        Color.clear.frame(width: 0, height: 0)
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
}

// MARK: - Sub-views

private struct ListeningView: View {
  let level: Float

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "mic.fill")
        .foregroundStyle(.red)
        .font(.system(size: 14, weight: .medium))

      HStack(spacing: 3) {
        ForEach(0..<8, id: \.self) { i in
          RoundedRectangle(cornerRadius: 1.5)
            .fill(barColor(for: i))
            .frame(width: 4, height: barHeight(for: i))
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.ultraThinMaterial, in: Capsule())
  }

  private func barHeight(for index: Int) -> CGFloat {
    let fraction = Float(index + 1) / 8.0
    let base: CGFloat = 4
    let max: CGFloat = 24
    if level >= fraction {
      return base + (max - base) * CGFloat((level - fraction) / (1 - fraction) * 0.8 + 0.2)
    }
    if level >= fraction * 0.6 {
      return base + (max - base) * 0.25
    }
    return base
  }

  private func barColor(for index: Int) -> Color {
    let fraction = Float(index + 1) / 8.0
    if fraction <= 0.4 { return .green }
    if fraction <= 0.65 { return .yellow }
    return .red
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
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.ultraThinMaterial, in: Capsule())
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
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.ultraThinMaterial, in: Capsule())
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
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.ultraThinMaterial, in: Capsule())
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
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.ultraThinMaterial, in: Capsule())
  }
}
