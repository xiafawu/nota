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
    // Left inset doubles as the hover-timestamp gutter (symmetric, so the right
    // margin matches for a balanced reading column).
    textView.textContainerInset = NSSize(width: Metrics.gutterWidth, height: Metrics.richTextInsetY)
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
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
    }
  }

  final class Coordinator {
    var onScroll: ((CGFloat) -> Void)?
    var observer: NSObjectProtocol?
    var layoutRevision = 0

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
    }
  }
}

#if DEBUG
#Preview("sample") {
  RichTextViewer(attributedString: PreviewMocks.sampleRichText)
    .frame(width: 720, height: 540)
}
#endif
