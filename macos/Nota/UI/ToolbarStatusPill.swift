import SwiftUI

struct ToolbarStatusPill: View {
  let state: ToolbarStatusPillState

  var body: some View {
    HStack(spacing: Metrics.statusHStackSpacing) {
      if state.isRunning {
        ProgressView()
          .controlSize(.small)
      }
      Text(state.text)
        .font(Tokens.statusFont)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .padding(.horizontal, Metrics.statusPillH)
    .padding(.vertical, Metrics.statusPillV)
    .liquidGlass(.regular.tint(Tokens.toolbarStatusTint), in: .capsule)
    .transition(.opacity.combined(with: .scale))
  }
}

#if DEBUG
#Preview("idle") {
  ToolbarStatusPill(state: PreviewMocks.toolbarStatusIdle)
    .padding()
}

#Preview("running") {
  ToolbarStatusPill(state: PreviewMocks.toolbarStatusRunning)
    .padding()
}
#endif
