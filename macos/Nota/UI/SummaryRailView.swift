import SwiftUI

// MARK: - Summary rail (XIA-415)

/// The summary rail: a fixed-width (380pt) SwiftUI overlay anchored in the
/// window's bottom-right corner (decision 1) that holds everything the
/// transcript's enrichment slot used to: narrative, topics, decisions, action
/// items, the outdated banner, the in-flight row, and failures with Retry —
/// plus Edit / Regenerate / Close (decision 5). One size, no compact/expanded
/// states, no divider drag (decision 3).
///
/// The rail owns its dismissal surface (full-window backdrop + hidden Escape
/// button) so every close runs the decision-13 draft policy from the one
/// place that knows the draft: not editing → close; Save it → commit + close;
/// Ask me → confirm (save / discard / keep editing).
///
/// Built out in the summary-rail lane; this file lands in the wiring commit as
/// a compiling stub.
struct SummaryRailView: View {
  @ObservedObject var model: NotaModel

  var body: some View {
    EmptyView()
  }
}
