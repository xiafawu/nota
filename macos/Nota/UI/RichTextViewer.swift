import AppKit
import SwiftUI

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
      DispatchQueue.main.async { [weak scrollView, weak coordinator = context.coordinator] in
        guard let scrollView, let coordinator else { return }
        coordinator.restoreScrollPosition(in: scrollView, preservingY: preservedY)
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

    func restoreScrollPosition(in scrollView: NSScrollView, preservingY y: CGFloat) {
      let clipView = scrollView.contentView
      let documentHeight = scrollView.documentView?.frame.height ?? 0
      let maximumY = max(0, documentHeight - clipView.bounds.height)
      let targetY = min(max(0, y), maximumY)
      guard abs(clipView.bounds.origin.y - targetY) > 0.5 else { return }

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
