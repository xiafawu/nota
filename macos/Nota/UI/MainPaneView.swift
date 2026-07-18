import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainPaneView: View {
  let content: MainPaneContent
  @Binding var isDropTargeted: Bool
  @Binding var speakerChips: [SpeakerChip]
  let onDropURL: (URL) -> Void
  let onRename: (_ label: String, _ newName: String) -> Void
  var onRefreshPreflight: () -> Void = {}

  /// True once the rich-text body has scrolled beneath the header; drives the
  /// header collapse and the top fade on the body.
  @State private var isBodyScrolled = false

  var body: some View {
    ZStack {
      switch content {
      case .empty(let state):
        EmptyMainView(state: state, isDropTargeted: isDropTargeted)
      case .preflight(let state):
        PreflightHomeView(
          result: state.result,
          isChecking: state.isChecking,
          onRefresh: onRefreshPreflight
        )
      case .rich(let document):
        VStack(spacing: 0) {
          if let meta = document.meta {
            DocumentHeaderView(
              meta: meta,
              chips: $speakerChips,
              compact: isBodyScrolled,
              onRename: onRename
            )
            Divider()
          }
          RichTextViewer(
            attributedString: Self.applySpeakerColors(to: document.body, chips: speakerChips),
            onScroll: { offset in
              let scrolled = offset > Metrics.docHeaderCompactThreshold
              if scrolled != isBodyScrolled {
                withAnimation(Tokens.animFast) { isBodyScrolled = scrolled }
              }
            }
          )
          .mask(bodyFadeMask)
        }
        .animation(Tokens.animFast, value: isBodyScrolled)
      }

      if isDropTargeted {
        RoundedRectangle(cornerRadius: Metrics.dropFullBleedCornerRadius)
          .strokeBorder(Tokens.dropAccent, lineWidth: Metrics.dropTargetStrokeWidth)
          .allowsHitTesting(false)
          .transition(.opacity)
      }
    }
    .animation(Tokens.animSnap, value: isDropTargeted)
    .animation(Tokens.animFast, value: isRichContent)
    .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
      guard let provider = providers.first else {
        return false
      }

      provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
        let url: URL?
        if let data = item as? Data {
          url = URL(dataRepresentation: data, relativeTo: nil)
        } else if let nsURL = item as? NSURL {
          url = nsURL as URL
        } else {
          url = nil
        }

        if let url {
          Task { @MainActor in
            onDropURL(url)
          }
        }
      }
      return true
    }
  }

  /// Scroll-edge fade: once content scrolls beneath the header, the top of the
  /// body dissolves instead of hard-clipping against the hairline. Fixed-height
  /// gradient — a percentage gradient would scale with document height.
  private var bodyFadeMask: some View {
    VStack(spacing: 0) {
      LinearGradient(
        colors: [
          .black.opacity(isBodyScrolled ? Tokens.docBodyFadeGhostOpacity : 1),
          .black,
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(height: Metrics.docBodyTopFadeHeight)
      Rectangle().fill(Color.black)
    }
  }

  private var isRichContent: Bool {
    if case .rich = content { return true }
    return false
  }

  /// Echo each chip's identity hue onto its transcript speaker runs. Speaker
  /// runs are the "Name: " prefixes rendered in `NSFonts.speaker` that carry a
  /// `.notaTimestamp` attribute (see MarkdownRender), which keeps generic bold
  /// text untouched.
  static func applySpeakerColors(
    to body: NSAttributedString,
    chips: [SpeakerChip]
  ) -> NSAttributedString {
    guard !chips.isEmpty, body.length > 0 else { return body }

    var colorForName: [String: NSColor] = [:]
    for (index, chip) in chips.enumerated() {
      let display = chip.name.isEmpty ? chip.label : chip.name
      colorForName[display] = SpeakerColors.nsColor(at: index)
    }

    let output = NSMutableAttributedString(attributedString: body)
    let fullRange = NSRange(location: 0, length: output.length)
    let text = output.string as NSString
    output.enumerateAttributes(in: fullRange) { attributes, range, _ in
      guard
        attributes[.notaTimestamp] != nil,
        let font = attributes[.font] as? NSFont,
        font == NSFonts.speaker
      else {
        return
      }
      let run = text.substring(with: range)
      guard run.hasSuffix(": ") else { return }
      let name = String(run.dropLast(2))
      guard let color = colorForName[name] else { return }
      output.addAttribute(.foregroundColor, value: color, range: range)
    }
    return output
  }
}

#if DEBUG
#Preview("empty idle") {
  MainPaneView(
    content: .empty(PreviewMocks.emptyMainIdle),
    isDropTargeted: .constant(false),
    speakerChips: .constant([]),
    onDropURL: { _ in },
    onRename: { _, _ in }
  )
  .frame(width: 720, height: 540)
}

#Preview("empty targeted") {
  MainPaneView(
    content: .empty(PreviewMocks.emptyMainIdle),
    isDropTargeted: .constant(true),
    speakerChips: .constant([]),
    onDropURL: { _ in },
    onRename: { _, _ in }
  )
  .frame(width: 720, height: 540)
}

#Preview("rich content") {
  MainPaneView(
    content: .rich(PreviewMocks.sampleDocument),
    isDropTargeted: .constant(false),
    speakerChips: .constant([]),
    onDropURL: { _ in },
    onRename: { _, _ in }
  )
  .frame(width: 720, height: 540)
}
#endif
