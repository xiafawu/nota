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

  // MARK: Moment pips (XIA-429)

  /// The seconds this document's moments were flagged at (XIA-433's `markers`),
  /// oldest first. Empty for an imported `.md` and for any record with no
  /// moments — and an empty list draws nothing, so a document without markers
  /// pays one array comparison for the whole feature.
  ///
  /// Pips ride the gutter the hover timestamp already owns, which is the whole
  /// argument for them over the alternatives: no timeline track to build, no
  /// list to keep in sync, no popover to open — a mark is drawn beside the line
  /// it belongs to, in 48pt of margin that is already reserved and empty.
  var markerSeconds: [TimeInterval] = [] {
    didSet {
      guard markerSeconds != oldValue else { return }
      lastRevealedLine = nil
      markedCache = nil
      needsDisplay = true
    }
  }

  /// The line the last "next moment" press landed on, so the next press moves
  /// on rather than re-scrolling to the same pip.
  private var lastRevealedLine: Int?

  /// Small enough to read as a mark in the margin rather than as a bullet the
  /// line belongs to.
  static let pipDiameter: CGFloat = 5

  /// The lane the pips occupy at the gutter's trailing edge. The hover label
  /// stops short of it whenever this document has any moments at all, because
  /// both are right-aligned to the same edge on the same line box — so hovering
  /// a marked line drew "12:04" straight over that line's pip. Reserved for the
  /// whole document rather than per line, or the label would jump sideways as
  /// the cursor crossed a marked line.
  static let pipLane: CGFloat = pipDiameter + 4

  // MARK: The scan, cached
  //
  // `draw(_:)` is called once per tile while scrolling, and enumerating every
  // attribute run of a 90-minute transcript on each of them is exactly the
  // unbounded main-thread cost CLAUDE.md already records twice. Both derived
  // lists are therefore memoized and invalidated on the two things that can
  // change them: the marker list, and the text.

  private var linesCache: [(seconds: TimeInterval, characterIndex: Int)]?
  private var markedCache: [Int]?
  private var cachedTextLength = -1

  /// Each laid-out line's start in seconds, in document order, paired with a
  /// character index into the storage. Read off `.notaTimestampSeconds`, which
  /// the renderer attached from the same capture the gutter label came from.
  private var timestampedLines: [(seconds: TimeInterval, characterIndex: Int)] {
    guard let textStorage, textStorage.length > 0 else { return [] }
    if textStorage.length != cachedTextLength {
      linesCache = nil
      markedCache = nil
      cachedTextLength = textStorage.length
    }
    if let linesCache { return linesCache }
    var lines: [(seconds: TimeInterval, characterIndex: Int)] = []
    textStorage.enumerateAttribute(
      .notaTimestampSeconds,
      in: NSRange(location: 0, length: textStorage.length)
    ) { value, range, _ in
      guard let number = value as? NSNumber else { return }
      lines.append((seconds: number.doubleValue, characterIndex: range.location))
    }
    linesCache = lines
    return lines
  }

  /// The line indices carrying a pip, memoized alongside the scan they come
  /// from. Returned with the lines so the two can never be computed against
  /// different snapshots of the storage.
  private func pipLines() -> (
    lines: [(seconds: TimeInterval, characterIndex: Int)], marked: [Int]
  ) {
    let lines = timestampedLines
    if let markedCache { return (lines, markedCache) }
    let marked = TranscriptMarkerGutter.markedLines(
      markerSeconds: markerSeconds,
      lineStarts: lines.map(\.seconds)
    )
    markedCache = marked
    return (lines, marked)
  }

  override func didChangeText() {
    super.didChangeText()
    invalidateTimestampCache()
  }

  /// Told by the host when it replaces the storage programmatically, which
  /// sends no `didChangeText`.
  func invalidateTimestampCache() {
    linesCache = nil
    markedCache = nil
    cachedTextLength = -1
    lastRevealedLine = nil
    needsDisplay = true
  }

  /// Scroll to the next flagged moment, wrapping at the end. Answers false when
  /// the document has no pip to reach — which is what lets the fact strip draw
  /// "N moments" as plain text rather than as a button that does nothing.
  @discardableResult
  func revealNextMarker() -> Bool {
    let (lines, marked) = pipLines()
    guard let next = TranscriptMarkerGutter.nextLine(after: lastRevealedLine, marked: marked),
          next < lines.count
    else {
      return false
    }
    lastRevealedLine = next
    scrollRangeToVisible(NSRange(location: lines[next].characterIndex, length: 1))
    return true
  }

  /// The pips: one dot in the gutter, on the line each moment belongs to.
  /// Drawn rather than hung off subviews — there is one per marked line, they
  /// move on every relayout, and a pool of `NSView`s to invalidate is
  /// bookkeeping this view does not otherwise carry.
  /// Where the pips go, as rects — **the same values `draw(_:)` fills**, split
  /// out so they can be asserted.
  ///
  /// A pixel probe cannot check this. Measured 2026-08-16: a `cacheDisplay`
  /// bitmap of an unhosted `NSTextView` contains none of this view's custom
  /// `draw(_:)` output at all — a solid red fill in the loop below produces
  /// zero differing pixels. The test that claimed to see a pip was reading an
  /// adjacent effect instead (`revealNextMarker` scrolls the marked view and
  /// not the bare one), so it stayed green through a pip drawn at x = -13.
  func pipRects() -> [NSRect] {
    guard !markerSeconds.isEmpty, let layoutManager, textContainer != nil else { return [] }
    let (lines, marked) = pipLines()
    let inset = textContainerInset
    return marked.compactMap { index in
      guard index < lines.count else { return nil }
      let glyph = layoutManager.glyphIndexForCharacter(at: lines[index].characterIndex)
      let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      // The gutter is whatever space is to the LEFT OF THE TEXT, which is the
      // inset — not `Metrics.gutterWidth`, which is only its floor. XIA-441
      // centres the reading column by growing that inset on a wide window, and
      // a pip pinned to the constant would sit adrift in the left margin while
      // the line it marks started 200pt further right.
      return NSRect(
        x: inset.width - Metrics.tsGutterTrailingGap - Self.pipDiameter,
        y: fragment.minY + inset.height + (fragment.height - Self.pipDiameter) / 2,
        width: Self.pipDiameter,
        height: Self.pipDiameter)
    }
  }

  /// The line fragment a pip belongs to, for the assertion that it is beside
  /// its own line rather than merely somewhere in the gutter.
  func lineFragmentForPip(at markedIndex: Int) -> NSRect? {
    guard let layoutManager, textContainer != nil else { return nil }
    let (lines, marked) = pipLines()
    guard markedIndex < marked.count, marked[markedIndex] < lines.count else { return nil }
    let glyph = layoutManager.glyphIndexForCharacter(
      at: lines[marked[markedIndex]].characterIndex)
    var rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    rect.origin.y += textContainerInset.height
    return rect
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard !markerSeconds.isEmpty else { return }
    let rects = pipRects()
    guard !rects.isEmpty else { return }
    NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
    for rect in rects where rect.intersects(dirtyRect) {
      NSBezierPath(ovalIn: rect).fill()
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard gutterLabel.superview == nil else {
      return
    }
    gutterLabel.font = NSFonts.readingGutter
    gutterLabel.textColor = GroundInk.nsColor(.timestamp)
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
    // Stop short of the pip lane when this document has moments at all: both
    // are right-aligned to the same trailing edge on the same line box, so
    // without it hovering a marked line drew the timestamp over its own pip.
    let lane = markerSeconds.isEmpty ? 0 : Self.pipLane
    // Right-aligned to the text's own leading edge (see the pip comment above):
    // the inset is the gutter, and it grows when the column is centred.
    let available = inset.width - Metrics.tsGutterTrailingGap - lane
    let width = min(size.width, available)
    let x = inset.width - Metrics.tsGutterTrailingGap - lane - width
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
