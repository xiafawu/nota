import AppKit
import SwiftUI

struct RichTextViewer: NSViewRepresentable {
  let attributedString: NSAttributedString

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
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

    scrollView.documentView = textView
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView else {
      return
    }

    textView.textStorage?.setAttributedString(attributedString)
  }
}

#if DEBUG
#Preview("sample") {
  RichTextViewer(attributedString: PreviewMocks.sampleRichText)
    .frame(width: 720, height: 540)
}
#endif
