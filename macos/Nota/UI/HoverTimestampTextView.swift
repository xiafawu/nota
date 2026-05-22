import AppKit

/// An `NSTextView` that reveals a transcript line's timestamp in the left gutter
/// while the cursor hovers that line, then fades it out. Timestamps are stripped
/// from the visible text at render time and carried as a `.notaTimestamp`
/// attribute (see `MarkdownRender`), so this view only has to read the attribute
/// under the cursor and position a faint label. Text storage is never mutated,
/// so selection, Cmd-C, and RTF copy are unaffected.
final class HoverTimestampTextView: NSTextView {
  private let gutterLabel = HoverPassthroughLabel(labelWithString: "")
  private var trackingArea: NSTrackingArea?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard gutterLabel.superview == nil else {
      return
    }
    gutterLabel.font = NSFonts.gutterTimestamp
    gutterLabel.textColor = .secondaryLabelColor
    gutterLabel.alignment = .right
    gutterLabel.lineBreakMode = .byClipping
    gutterLabel.alphaValue = 0
    gutterLabel.isHidden = true
    addSubview(gutterLabel)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea {
      removeTrackingArea(trackingArea)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseMoved(with event: NSEvent) {
    super.mouseMoved(with: event)
    updateGutter(at: convert(event.locationInWindow, from: nil))
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    setGutter(visible: false)
  }

  /// Find the line under `point`; if it carries a `.notaTimestamp`, position and
  /// fade in the gutter label aligned to that line. Otherwise fade out.
  private func updateGutter(at point: NSPoint) {
    guard
      let layoutManager,
      let textContainer,
      let textStorage,
      textStorage.length > 0
    else {
      setGutter(visible: false)
      return
    }

    let inset = textContainerInset
    let containerPoint = NSPoint(x: point.x - inset.width, y: point.y - inset.height)
    let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
    let usedRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)

    // glyphIndex(for:) snaps to the nearest glyph even in empty space, so guard on
    // the vertical band of the line's used rect to avoid phantom reveals when
    // hovering below the last line.
    guard containerPoint.y >= usedRect.minY, containerPoint.y <= usedRect.maxY else {
      setGutter(visible: false)
      return
    }

    let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
    guard
      charIndex < textStorage.length,
      let timestamp = textStorage.attribute(.notaTimestamp, at: charIndex, effectiveRange: nil) as? String
    else {
      setGutter(visible: false)
      return
    }

    let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
    gutterLabel.stringValue = timestamp
    let size = gutterLabel.intrinsicContentSize
    let width = min(size.width, Metrics.gutterWidth - Metrics.tsGutterTrailingGap)
    let x = Metrics.gutterWidth - Metrics.tsGutterTrailingGap - width
    let y = lineRect.minY + inset.height + (lineRect.height - size.height) / 2
    gutterLabel.frame = NSRect(x: x, y: y, width: width, height: size.height)
    setGutter(visible: true)
  }

  private func setGutter(visible: Bool) {
    if visible {
      gutterLabel.isHidden = false
    }
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = Tokens.hoverFadeDuration
      gutterLabel.animator().alphaValue = visible ? 1 : 0
    }, completionHandler: { [weak self] in
      guard let self else {
        return
      }
      if self.gutterLabel.alphaValue == 0 {
        self.gutterLabel.isHidden = true
      }
    })
  }
}

/// Label that never intercepts the mouse, so moving the cursor across it doesn't
/// stop the parent text view's `mouseMoved` stream (which would flicker the fade).
private final class HoverPassthroughLabel: NSTextField {
  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}
