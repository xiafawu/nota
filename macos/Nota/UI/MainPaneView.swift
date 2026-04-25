import SwiftUI
import UniformTypeIdentifiers

struct MainPaneView: View {
  let content: MainPaneContent
  @Binding var isDropTargeted: Bool
  let onDropURL: (URL) -> Void

  var body: some View {
    ZStack {
      switch content {
      case .empty(let state):
        EmptyMainView(state: state, isDropTargeted: isDropTargeted)
      case .rich(let attributedString):
        RichTextViewer(attributedString: attributedString)
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
    onDropURL: { _ in }
  )
  .frame(width: 720, height: 540)
}

#Preview("empty targeted") {
  MainPaneView(
    content: .empty(PreviewMocks.emptyMainIdle),
    isDropTargeted: .constant(true),
    onDropURL: { _ in }
  )
  .frame(width: 720, height: 540)
}

#Preview("rich content") {
  MainPaneView(
    content: .rich(PreviewMocks.sampleRichText),
    isDropTargeted: .constant(false),
    onDropURL: { _ in }
  )
  .frame(width: 720, height: 540)
}
#endif
