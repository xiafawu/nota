import AppKit
import SwiftUI

/// Pure scroll-restoration decisions for the transcript viewer, extracted so
/// the resize/restore coalescing contract is unit-testable without a UI.
enum RichTextScrollRestore {
  /// Maps a preserved document offset to the offset that is valid after the
  /// viewport changed, clamping to the document's scrollable range.
  static func targetOffset(
    preservedY: CGFloat,
    documentHeight: CGFloat,
    viewportHeight: CGFloat
  ) -> CGFloat {
    let maximumY = max(0, documentHeight - viewportHeight)
    return min(max(0, preservedY), maximumY)
  }

  /// A queued restoration applies only while it is still the newest request.
  /// Layout changes arrive faster than the async restore runs; dropping
  /// superseded revisions keeps stale restores from fighting the latest one.
  static func shouldApply(revision: Int, latestRevision: Int) -> Bool {
    revision == latestRevision
  }

  /// Sub-half-point drift is not worth a scroll: scrolling would feed a
  /// bounds-change notification back into layout.
  static func needsRestore(currentY: CGFloat, targetY: CGFloat) -> Bool {
    abs(currentY - targetY) > 0.5
  }
}

struct RichTextViewer: NSViewRepresentable {
  let attributedString: NSAttributedString
  /// Changes when a sibling above the transcript changes its height. The
  /// coordinator uses this lightweight revision to restore the same visible
  /// transcript offset after the NSScrollView is relaid out.
  var layoutRevision: Int = 0
  /// Reports the vertical scroll offset (0 = at top) so the host can collapse
  /// the document header once content scrolls beneath it.
  var onScroll: ((CGFloat) -> Void)? = nil
  /// The seconds this document's flagged moments were taken at (XIA-429).
  /// Handed straight to the text view, which draws one pip per marked line in
  /// the gutter it already owns.
  var markerSeconds: [TimeInterval] = []
  /// A press counter, not a position: every increment means "go to the next
  /// pip". A token rather than a line index because the *view* owns where it
  /// got to — SwiftUI would otherwise have to hold a cursor it cannot compute,
  /// since which line a marker lands on is a question about the laid-out text.
  var nextMomentToken: Int = 0

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.drawsBackground = false

    let textView = HoverTimestampTextView()
    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    // **The measure is capped, and the column is centred** (XIA-441). This used
    // to track the text view outright, so the line length was whatever the
    // window was — a 1400pt window drew ~140-character lines, and that is most
    // of what "it looks like a text editor" meant.
    //
    // `widthTracksTextView` has to go off for a cap to hold at all: it forces
    // the container to the view's width on every resize and would overwrite the
    // size set here. `layout(in:)` re-applies both numbers, because the cap is a
    // function of the current width and nothing else recomputes it.
    textView.textContainer?.widthTracksTextView = false
    RichTextViewer.layout(textView, in: scrollView.contentSize.width)
    // Zero out the container's default 5pt padding so body text shares the
    // header's leading edge exactly (both start at the gutter width).
    textView.textContainer?.lineFragmentPadding = 0
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

    scrollView.documentView = textView

    scrollView.contentView.postsBoundsChangedNotifications = true
    context.coordinator.observer = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification,
      object: scrollView.contentView,
      queue: .main
    ) { [weak coordinator = context.coordinator] note in
      guard let clipView = note.object as? NSClipView else { return }
      coordinator?.onScroll?(clipView.bounds.origin.y)
    }

    // The column is a function of the current width, and with
    // `widthTracksTextView` off nothing re-derives it on a resize — the text
    // would keep the width the window happened to have when it opened.
    // `updateNSView` does not fire for a window resize either, so the width has
    // to be watched directly.
    //
    // **Only when the WIDTH changed**, and that guard is not an optimisation —
    // without it the transcript shakes while you scroll it. The loop:
    // scrolling reports an offset, the host collapses the document header on
    // it, the collapse changes the scroll view's *height*, the clip view's
    // frame changes, and this observer rewrote `textContainerInset` and the
    // container size — which invalidates the whole text layout, moves the
    // document under the scroller, and reports another offset. The column
    // depends on width alone, so a height-only frame change has no business
    // touching it.
    scrollView.contentView.postsFrameChangedNotifications = true
    context.coordinator.lastLaidOutWidth = scrollView.contentSize.width
    context.coordinator.frameObserver = NotificationCenter.default.addObserver(
      forName: NSView.frameDidChangeNotification,
      object: scrollView.contentView,
      queue: .main
    ) { [weak textView, weak coordinator = context.coordinator] note in
      guard let textView, let coordinator, let clipView = note.object as? NSClipView else { return }
      let width = clipView.bounds.width
      guard RichTextViewer.Column.needsRelayout(from: coordinator.lastLaidOutWidth, to: width)
      else { return }
      coordinator.lastLaidOutWidth = width
      RichTextViewer.layout(textView, in: width)
    }

    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.onScroll = onScroll

    if context.coordinator.layoutRevision != layoutRevision {
      context.coordinator.layoutRevision = layoutRevision
      let preservedY = scrollView.contentView.bounds.origin.y
      let revision = layoutRevision
      DispatchQueue.main.async { [weak scrollView, weak coordinator = context.coordinator] in
        guard let scrollView, let coordinator else { return }
        coordinator.restoreScrollPosition(
          in: scrollView,
          preservingY: preservedY,
          revision: revision
        )
      }
    }
    guard let textView = scrollView.documentView as? NSTextView else {
      return
    }

    // Only replace the storage when the content actually changed — scroll-state
    // updates re-invoke this and a wholesale reset would re-layout mid-scroll.
    if textView.textStorage?.isEqual(to: attributedString) != true {
      textView.textStorage?.setAttributedString(attributedString)
      // The pip scan is memoized against the storage, and a programmatic
      // `setAttributedString` sends no `didChangeText`. Told explicitly here,
      // because "the length changed" is a heuristic and two documents can be
      // the same length.
      (textView as? HoverTimestampTextView)?.invalidateTimestampCache()
    }

    // …and the moments **after** the text they index into. Setting the markers
    // first meant a press arriving in the same update ran `revealNextMarker`
    // against the previous document's lines.
    if let hoverView = textView as? HoverTimestampTextView {
      hoverView.markerSeconds = markerSeconds
      // Strictly greater, so the first evaluation (both zero) does not scroll a
      // freshly-opened document to its first moment.
      if nextMomentToken > context.coordinator.momentToken {
        context.coordinator.momentToken = nextMomentToken
        hoverView.revealNextMarker()
      } else {
        context.coordinator.momentToken = nextMomentToken
      }
    }
  }

  /// Where the reading column sits, given the width it has to sit in.
  ///
  /// Pure arithmetic, for the reason `SessionTimerMetrics` and
  /// `HUDPillMetrics` are: the column can then be asserted at a dozen window
  /// widths without a window server, and the two numbers are checked against
  /// each other rather than eyeballed on one screen.
  ///
  /// Two rules. The measure never exceeds `Metrics.readingMeasure` — that is
  /// the cap the whole change is about. And the leftover is **split evenly**,
  /// so the column is centred rather than pinned to a fat left inset: a
  /// 1400pt window otherwise draws a 640pt column with 700pt of white on its
  /// right, which reads worse than the uncapped line it replaced. The inset
  /// never falls below `Metrics.gutterWidth`, because the hover timestamps and
  /// the moment pips are drawn in it.
  enum Column {
    static func containerWidth(available: CGFloat) -> CGFloat {
      let usable = max(0, available - 2 * Metrics.gutterWidth)
      return min(Metrics.readingMeasure, usable)
    }

    static func inset(available: CGFloat) -> CGFloat {
      let container = containerWidth(available: available)
      return max(Metrics.gutterWidth, (available - container) / 2)
    }

    /// Whether a new available width is worth re-laying the column out for.
    ///
    /// Pure, and separate from the observer, because what it protects is a
    /// *behaviour* rather than a number: re-applying the column writes
    /// `textContainerInset`, which invalidates the entire text layout. Doing
    /// that from a frame change that only altered the height is what made the
    /// transcript shake under a scroll (the document header collapses on
    /// scroll, which changes the height, which fired this observer).
    ///
    /// Sub-half-point drift is refused for the reason
    /// `RichTextScrollRestore.needsRestore` refuses it: the correction costs
    /// more than the error.
    static func needsRelayout(from old: CGFloat, to new: CGFloat) -> Bool {
      guard new > 0 else { return false }
      return abs(new - old) > 0.5
    }
  }

  /// Apply the column to a text view. Called at creation and on every width
  /// change — `widthTracksTextView` is off, so nothing else recomputes it.
  static func layout(_ textView: NSTextView, in available: CGFloat) {
    guard available > 0 else { return }
    let inset = Column.inset(available: available)
    textView.textContainerInset = NSSize(width: inset, height: Metrics.richTextInsetY)
    textView.textContainer?.containerSize = NSSize(
      width: Column.containerWidth(available: available),
      height: .greatestFiniteMagnitude)
  }

  final class Coordinator {
    var onScroll: ((CGFloat) -> Void)?
    var observer: NSObjectProtocol?
    /// Separate from `observer`: bounds changes are scrolls, frame changes are
    /// resizes, and only the second one re-derives the reading column.
    var frameObserver: NSObjectProtocol?
    /// The width the column was last built for. A frame change that leaves it
    /// alone is a height change, and the column does not depend on height.
    var lastLaidOutWidth: CGFloat = 0
    var layoutRevision = 0
    /// The last "next moment" press this coordinator has acted on.
    var momentToken = 0

    func restoreScrollPosition(in scrollView: NSScrollView, preservingY y: CGFloat, revision: Int) {
      guard RichTextScrollRestore.shouldApply(revision: revision, latestRevision: layoutRevision) else {
        return
      }
      let clipView = scrollView.contentView
      let documentHeight = scrollView.documentView?.frame.height ?? 0
      let targetY = RichTextScrollRestore.targetOffset(
        preservedY: y,
        documentHeight: documentHeight,
        viewportHeight: clipView.bounds.height
      )
      guard RichTextScrollRestore.needsRestore(
        currentY: clipView.bounds.origin.y,
        targetY: targetY
      ) else {
        return
      }
      var bounds = clipView.bounds
      bounds.origin.y = targetY
      clipView.scroll(to: bounds.origin)
      scrollView.reflectScrolledClipView(clipView)
    }

    deinit {
      if let observer {
        NotificationCenter.default.removeObserver(observer)
      }
      if let frameObserver {
        NotificationCenter.default.removeObserver(frameObserver)
      }
    }
  }
}

#if DEBUG
#Preview("sample") {
  RichTextViewer(attributedString: PreviewMocks.sampleRichText)
    .frame(width: 720, height: 540)
}
#endif
