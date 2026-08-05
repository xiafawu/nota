import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainPaneView: View {
  /// The live dictation session lives on the model (single owner); the pane
  /// reads it from the environment and never owns session state itself.
  @EnvironmentObject private var model: NotaModel
  /// Observed directly (not via the model) so the local cluster's four-state
  /// Summary button re-renders on generation progress and failures without
  /// re-rendering the whole pane.
  @ObservedObject private var enrichment = EnrichmentController.shared
  let content: MainPaneContent
  @Binding var isDropTargeted: Bool
  @Binding var speakerChips: [SpeakerChip]
  let onDropURL: (URL) -> Void
  let onRename: (_ label: String, _ newName: String) -> Void
  /// Accept/dismiss a chip's pending speaker suggestion (decision 4).
  var onAcceptSuggestion: (_ label: String) -> Void = { _ in }
  var onDismissSuggestion: (_ label: String) -> Void = { _ in }

  var body: some View {
    ZStack {
      switch content {
      case .empty(let state):
        EmptyMainView(state: state, isDropTargeted: isDropTargeted)
      case .rich(let document):
        RichDocumentPane(
          document: document,
          speakerChips: $speakerChips,
          onRename: onRename,
          onAcceptSuggestion: onAcceptSuggestion,
          onDismissSuggestion: onDismissSuggestion,
          enrichment: EnrichmentController.shared
        )
      case .liveMeeting:
        LiveMeetingView(
          session: model.liveSession,
          kind: model.activeSessionKind,
          onStart: { model.startLiveSession() },
          onStop: { model.stopLiveSession() }
        )
      }

      if isDropTargeted {
        RoundedRectangle(cornerRadius: Metrics.dropFullBleedCornerRadius)
          .strokeBorder(Tokens.dropAccent, lineWidth: Metrics.dropTargetStrokeWidth)
          .allowsHitTesting(false)
          .transition(.opacity)
      }

      // Bottom-right local cluster (ADR 0005): per-transcript actions float
      // over the content area, inset from its trailing and bottom edges —
      // never pinned to the window frame. Summary + Share; no record (imported
      // markdown) hides the Summary button, which is meaningless without one.
      if isRichContent {
        localCluster
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

  /// The bottom-right local cluster: Summary (four states, decision 9) and
  /// Share (decision 11 — the toolbar's ShareMenu reused as-is, host only).
  /// Two individual round glass buttons, icon-only with tooltips (ADR 0005),
  /// floating over the content, inset from its trailing and bottom edges.
  /// The label box every cluster button draws into. Fixing the *label* rather
  /// than the control is what keeps the two buttons the same size: the glass
  /// button style adds its own padding around whatever it is given, so two
  /// labels of different widths (an icon and the word "Share") produce two
  /// differently shaped controls — which is exactly what a reused toolbar
  /// `Label` did here before.
  static let clusterGlyphSize: CGFloat = 17

  private var localCluster: some View {
    HStack(spacing: CraftTokens.spacing8) {
      if enrichment.record != nil {
        summaryClusterButton
      }
      ShareMenu(model: model, style: .localCluster)
    }
    .padding(.trailing, CraftTokens.spacing16)
    .padding(.bottom, CraftTokens.spacing16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
  }

  /// The four-state Summary button (decisions 9/10):
  /// - no summary → outlined circle with a plus, "Generate summary"
  /// - summary exists → filled circle, "Summary"
  /// - generating → progress ring; clicking opens the rail (Cancel lives
  ///   inside the rail, not on the button)
  /// - stale (`summaryOutdated`) → filled with a small warning dot —
  ///   staleness is marked here and nowhere else (decision 12)
  ///
  /// Dual-purpose (decision 10): with no summary one click starts generation
  /// AND opens the rail showing the in-flight row; with a summary it opens
  /// the rail. There is no path to an empty rail, so the dashed
  /// "No summary yet" placeholder card is retired.
  private var summaryClusterButton: some View {
    let isGenerating = enrichment.activity == .summarizing
    let hasSummary = enrichment.record?.hasSummaryNarrative == true
    let isStale = enrichment.record?.isSummaryOutdated == true
    // While a tag generation runs the summary verb is unavailable; the ring
    // is reserved for summary generation.
    let isEnabled = enrichment.activity == .idle || isGenerating

    return Button {
      model.isSummaryRailPresented = true
      if !isGenerating && !hasSummary {
        enrichment.generateSummary()
      }
    } label: {
      // One glyph-sized label in every state, so the glass button style keeps
      // one size across all four (decision 9) — the ring in particular must
      // not resize the control mid-generation.
      ZStack {
        if isGenerating {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: hasSummary ? "text.alignleft" : "plus")
            .font(.system(size: 14, weight: .semibold))
        }
      }
      .frame(width: Self.clusterGlyphSize, height: Self.clusterGlyphSize)
    }
    // Real Liquid Glass from the button style, not a hand-drawn
    // `Circle().fill(.thinMaterial)`: a material is a blur, glass refracts,
    // and only the style carries the hover and pressed states.
    .localClusterButton(prominent: hasSummary && !isGenerating)
    // The stale dot rides OUTSIDE the style's shape so the glass does not
    // blur it and the button's own size is unchanged by it (decision 12).
    .overlay(alignment: .topTrailing) {
      if isStale {
        Circle()
          .fill(.yellow)
          .frame(width: 9, height: 9)
          .overlay(Circle().strokeBorder(.black.opacity(0.3), lineWidth: 1))
          .offset(x: 2, y: -2)
          .allowsHitTesting(false)
      }
    }
    .animation(Tokens.animFast, value: isGenerating)
    .animation(Tokens.animFast, value: hasSummary)
    .disabled(!isEnabled)
    .help(hasSummary ? "Summary" : "Generate summary")
    .accessibilityLabel(hasSummary ? "Summary" : "Generate summary")
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

// MARK: - Rich document pane (header + transcript)

private struct RichDocumentPane: View {
  let document: DocumentRender
  @Binding var speakerChips: [SpeakerChip]
  let onRename: (_ label: String, _ newName: String) -> Void
  var onAcceptSuggestion: (_ label: String) -> Void = { _ in }
  var onDismissSuggestion: (_ label: String) -> Void = { _ in }
  @ObservedObject var enrichment: EnrichmentController

  /// True once the rich-text body has scrolled beneath the header; drives the
  /// header collapse and the top fade on the body.
  @State private var isBodyScrolled = false

  var body: some View {
    VStack(spacing: 0) {
      if let meta = document.meta {
        DocumentHeaderView(
          meta: meta,
          chips: $speakerChips,
          compact: isBodyScrolled,
          onRename: onRename,
          onAcceptSuggestion: onAcceptSuggestion,
          onDismissSuggestion: onDismissSuggestion,
          tagEditing: tagEditing
        )
        Divider()
      }
      // Decision 29: nothing sits between the header and the transcript —
      // the enrichment slot is gone, the summary lives in the rail overlay.
      RichTextViewer(
        attributedString: MainPaneView.applySpeakerColors(to: document.body, chips: speakerChips),
        onScroll: { offset in
          let scrolled = offset > Metrics.docHeaderCompactThreshold
          guard scrolled != isBodyScrolled else { return }
          withAnimation(Tokens.animFast) { isBodyScrolled = scrolled }
        }
      )
      .mask(bodyFadeMask)
    }
    .animation(Tokens.animFast, value: isBodyScrolled)
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

  /// Tags become editable chips only when the document has a history record —
  /// the record is truth for tag content; imported markdown keeps static pills.
  /// The generate-tags affordance rides the row (decision 28), carrying its
  /// progress, its failure, and the edited-tags confirm gate.
  private var tagEditing: EnrichmentTagEditing? {
    guard let record = enrichment.record else { return nil }
    return EnrichmentTagEditing(
      tags: record.tags,
      isGenerating: enrichment.activity == .tagging,
      errorMessage: enrichment.errorActivity == .tagging ? enrichment.errorMessage : nil,
      needsConfirm: enrichmentNeedsConfirm(record: record, target: .tags),
      onAdd: { enrichment.addTag($0) },
      onRemove: { enrichment.removeTag($0) },
      onGenerate: { enrichment.generateTags() }
    )
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
  .environmentObject(NotaModel())
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
  .environmentObject(NotaModel())
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
  .environmentObject(NotaModel())
  .frame(width: 720, height: 540)
}

#Preview("live meeting idle") {
  MainPaneView(
    content: .liveMeeting,
    isDropTargeted: .constant(false),
    speakerChips: .constant([]),
    onDropURL: { _ in },
    onRename: { _, _ in }
  )
  .environmentObject(NotaModel())
  .frame(width: 720, height: 540)
}
#endif
