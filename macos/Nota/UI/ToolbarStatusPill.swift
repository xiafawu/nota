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
        .truncationMode(state.truncatesFromTail ? .tail : .middle)
    }
    // The whole message on the tooltip, exactly as `DictationReviewView`'s
    // status line does it: one line here, the rest one hover away (P-C11).
    .help(state.helpText)
    .accessibilityLabel(state.helpText)
    .padding(.horizontal, Metrics.statusPillH)
    .padding(.vertical, Metrics.statusPillV)
    // No `.liquidGlass`, for the reason spelled out in `HealthPillView`: this is
    // the other item in the same `ToolbarItemGroup`, and the group already draws
    // one glass capsule around both. The tint this dropped was
    // `.secondary.opacity(0.1)` — a neutral wash, never a semantic signal — so
    // nothing the pill *says* travelled on it.
    //
    // No `.transition` either (FB-8). One sat here for months and never
    // played: the pill is inserted by a bare `if` inside a `ToolbarItemGroup`
    // with no animation driving it, so it appears and goes abruptly whatever
    // this line said. A transition that cannot fire reads as covered
    // behaviour that does not exist. Making it play is the owner's open
    // choice, and it would belong at the ContentView call site, not here.
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
