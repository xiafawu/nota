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
    // No `.liquidGlass`, for the reason spelled out in `HealthPillView`: this is
    // the other item in the same `ToolbarItemGroup`, and the group already draws
    // one glass capsule around both. The tint this dropped was
    // `.secondary.opacity(0.1)` — a neutral wash, never a semantic signal — so
    // nothing the pill *says* travelled on it.
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
