import SwiftUI

struct EmptyMainView: View {
  let state: EmptyMainState
  let isDropTargeted: Bool

  var body: some View {
    VStack(spacing: Metrics.emptyMainSpacing) {
      Spacer()

      Image(systemName: state.isRunning ? "waveform" : "tray.and.arrow.down")
        .font(Tokens.emptyMainIconFont)
        .foregroundStyle(isDropTargeted ? Tokens.dropAccent : Tokens.emptyIconColor)
        .symbolEffect(.pulse, isActive: state.isRunning)

      VStack(spacing: Metrics.emptyTextSpacing) {
        Text(state.displayName)
          .font(Tokens.emptyMainTitleFont)
          .fontWeight(.bold)
          .foregroundStyle(.primary)
          .multilineTextAlignment(.center)

        // While running, the subtitle is the live pipeline stage; the raw
        // file path (a synthetic staging path for shared files) is never shown.
        Text(state.isRunning ? state.phase : state.displayPath)
          .font(Tokens.emptyMainPathFont)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, Metrics.emptySubtextHorizontalPadding)

        if state.isRunning {
          ProgressView()
            .progressViewStyle(.linear)
            .frame(maxWidth: Metrics.emptyProgressWidth)
            .padding(.top, Metrics.emptyTextSpacing)
        }
      }

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(Metrics.emptyMainOuterPadding)
  }
}

#if DEBUG
#Preview("idle") {
  EmptyMainView(state: PreviewMocks.emptyMainIdle, isDropTargeted: false)
    .frame(width: 720, height: 540)
}

#Preview("targeted") {
  EmptyMainView(state: PreviewMocks.emptyMainIdle, isDropTargeted: true)
    .frame(width: 720, height: 540)
}

#Preview("running") {
  EmptyMainView(state: PreviewMocks.emptyMainRunning, isDropTargeted: false)
    .frame(width: 720, height: 540)
}
#endif
