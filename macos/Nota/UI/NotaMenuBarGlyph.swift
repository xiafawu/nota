import AppKit

/// Nota's own menu-bar mark: three waveform bars inside a capsule, the shape
/// of the recording capsules and the dictation pill. It replaced the stock
/// `mic`, which read as a macOS status icon rather than as Nota's.
///
/// Drawn in code as a **template** image so the menu bar tints it for light,
/// dark and the selected state, the same as an SF Symbol. Only idle and
/// listening use it; the warning states keep their SF glyphs, because a
/// shield or a triangle is what should replace the mark when something is wrong.
enum NotaMenuBarGlyph {
  /// Outline capsule: dictation idle.
  static let idle = make(filled: false)
  /// Solid capsule with the bars cut out: dictation listening, the way
  /// `mic` → `mic.fill` used to say it.
  static let listening = make(filled: true)

  /// The glyph's design grid (18×16), in menu-bar points.
  static let size = NSSize(width: 18, height: 16)

  private static let lineWidth: CGFloat = 1.6

  private static func make(filled: Bool) -> NSImage {
    let image = NSImage(size: size, flipped: true) { _ in
      guard let context = NSGraphicsContext.current?.cgContext else { return false }
      NSColor.black.set()

      let capsule = NSBezierPath(
        roundedRect: NSRect(x: 1, y: 2.5, width: 16, height: 11),
        xRadius: 5.5,
        yRadius: 5.5
      )
      if filled {
        capsule.fill()
        context.setBlendMode(.clear)
      } else {
        capsule.lineWidth = lineWidth
        capsule.stroke()
      }

      let bars = NSBezierPath()
      bars.lineWidth = lineWidth
      bars.lineCapStyle = .round
      for (x, top, bottom) in [(6.0, 6.5, 9.5), (9.0, 4.8, 11.2), (12.0, 6.5, 9.5)] {
        bars.move(to: NSPoint(x: x, y: top))
        bars.line(to: NSPoint(x: x, y: bottom))
      }
      bars.stroke()
      context.setBlendMode(.normal)
      return true
    }
    image.isTemplate = true
    return image
  }
}

extension DictationState {
  /// The menu-bar item's image. Idle and listening wear Nota's mark; every
  /// other state keeps its SF Symbol.
  var menuBarImage: NSImage? {
    switch self {
    case .idle: return NotaMenuBarGlyph.idle
    case .listening: return NotaMenuBarGlyph.listening
    default:
      return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    }
  }
}
