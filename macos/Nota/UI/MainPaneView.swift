import SwiftUI
import UniformTypeIdentifiers

struct MainPaneView: View {
  let content: MainPaneContent
  @Binding var isDropTargeted: Bool
  @Binding var speakerChips: [SpeakerChip]
  let onDropURL: (URL) -> Void
  let onRename: (_ label: String, _ newName: String) -> Void
  var onRefreshPreflight: () -> Void = {}

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
            DocumentHeaderView(meta: meta, chips: $speakerChips, onRename: onRename)
            Divider()
          }
          RichTextViewer(attributedString: document.body)
        }
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

  private var isRichContent: Bool {
    if case .rich = content { return true }
    return false
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
