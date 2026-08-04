import AppKit
import SwiftUI
import UniformTypeIdentifiers
/// Named coordinate space anchored to the document pane (stable while the
/// summary drawer resizes). The divider drag resolves its gesture values in
/// this space: measuring in the divider's own local space would re-anchor the
/// measurement to the divider's new position on every height change, which
/// feeds the divider's own motion back into the next event and oscillates.
private enum PaneCoordinateSpace {
  static let name = "Nota.DocumentPane"
}

struct MainPaneView: View {
  /// The live dictation session lives on the model (single owner); the pane
  /// reads it from the environment and never owns session state itself.
  @EnvironmentObject private var model: NotaModel
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

// MARK: - Rich document pane (header + enrichment slot + transcript)

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
  /// Bumped only when the summary drawer changes the transcript's viewport.
  /// `RichTextViewer` uses it to restore the same document offset after the
  /// enclosing VStack is relaid out.
  @State private var transcriptLayoutRevision = 0
  /// True while the summary divider is being dragged. Scroll-driven header
  /// changes are deferred until the drag ends so the header (whose height
  /// change would move the divider under the pointer) stays put mid-drag.
  @State private var isResizingDrawer = false
  /// Most recent transcript offset reported by `RichTextViewer`; used to
  /// reconcile the header scroll state once a drawer resize ends.
  @State private var lastBodyScrollOffset: CGFloat = 0

  var body: some View {
    GeometryReader { proxy in
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
        EnrichmentSlotView(
          controller: enrichment,
          availableHeight: proxy.size.height,
          onLayoutChange: { transcriptLayoutRevision += 1 },
          onResizeStateChange: { active in
            if active {
              isResizingDrawer = true
            } else {
              isResizingDrawer = false
              reconcileBodyScrolledState()
            }
          }
        )
        RichTextViewer(
          attributedString: MainPaneView.applySpeakerColors(to: document.body, chips: speakerChips),
          layoutRevision: transcriptLayoutRevision,
          onScroll: { offset in
            lastBodyScrollOffset = offset
            let scrolled = offset > Metrics.docHeaderCompactThreshold
            guard scrolled != isBodyScrolled else { return }
            // Mid-drag the header stays put: animating (or even snapping) the
            // compact/expanded transition would shift the divider under the
            // pointer. The end-of-drag reconciliation applies the true state.
            guard !isResizingDrawer else { return }
            withAnimation(Tokens.animFast) { isBodyScrolled = scrolled }
          }
        )
        .mask(bodyFadeMask)
      }
    }
    .coordinateSpace(name: PaneCoordinateSpace.name)
    .animation(Tokens.animFast, value: isBodyScrolled)
  }

  /// Applies the header scroll state that accumulated while the summary
  /// divider was being dragged, with the standard animation.
  private func reconcileBodyScrolledState() {
    let scrolled = lastBodyScrollOffset > Metrics.docHeaderCompactThreshold
    guard scrolled != isBodyScrolled else { return }
    withAnimation(Tokens.animFast) { isBodyScrolled = scrolled }
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
  private var tagEditing: EnrichmentTagEditing? {
    guard let record = enrichment.record else { return nil }
    return EnrichmentTagEditing(
      tags: record.tags,
      onAdd: { enrichment.addTag($0) },
      onRemove: { enrichment.removeTag($0) }
    )
  }
}

// MARK: - Enrichment slot (single container: placeholder → in-flight → summary)

private struct EnrichmentSlotView: View {
  @ObservedObject var controller: EnrichmentController
  var availableHeight: CGFloat = .infinity
  var onLayoutChange: () -> Void = {}
  /// Reports whether the summary divider drag is active so the host can keep
  /// the document header from animating (and shifting the divider) mid-drag.
  var onResizeStateChange: (Bool) -> Void = { _ in }

  @State private var isEditingSummary = false
  @State private var summaryDraft = ""
  @State private var confirmTarget: EnrichmentField?
  @State private var isSummaryExpanded = false
  @State private var summaryDrawerHeight = SummaryDrawerLayout.expandedDefaultHeight
  @State private var summaryResizeStartHeight: CGFloat?
  /// Pointer Y (in the pane coordinate space) where the drag began.
  @State private var summaryResizeStartY: CGFloat?
  /// Measured width of the decisions/action-items block, driving the
  /// two-columns-vs-stacked choice (see `structuredSummary`).
  @State private var structuredColumnsWidth: CGFloat = 0

  /// Minimum measured width at which decisions + action items render side by
  /// side; below it they stack. Each column keeps a readable wrapped measure
  /// (~28 characters of `.subheadline`) at this threshold.
  private static let twoColumnMinWidth: CGFloat = 480

  private var slotState: EnrichmentSlotState {
    enrichmentSlotState(
      record: controller.record,
      activity: controller.activity,
      modelID: controller.generatingModelID
    )
  }

  var body: some View {
    Group {
      switch slotState {
      case .hidden:
        EmptyView()
      case .placeholder:
        placeholderCard
      case .generating(let kind, let modelID):
        inFlightRow(kind: kind, modelID: modelID)
      case .summary(let narrative, let edited):
        summarySection(narrative: narrative, edited: edited)
      }
    }
    .animation(Tokens.animFast, value: slotState)
    .onChange(of: controller.record?.id) { _, _ in
      isEditingSummary = false
      isSummaryExpanded = false
      summaryDrawerHeight = SummaryDrawerLayout.expandedDefaultHeight
      summaryResizeStartHeight = nil
      summaryResizeStartY = nil
    }
    .alert(
      confirmTarget == .tags ? "Regenerate tags?" : "Replace your edited summary?",
      isPresented: Binding(
        get: { confirmTarget != nil },
        set: { if !$0 { confirmTarget = nil } }
      )
    ) {
      Button("Cancel", role: .cancel) { confirmTarget = nil }
      Button("Regenerate") {
        switch confirmTarget {
        case .summary: controller.generateSummary(force: true)
        case .tags: controller.generateTags(force: true)
        case nil: break
        }
        confirmTarget = nil
      }
    } message: {
      Text(
        confirmTarget == .tags
          ? "You've edited these tags. Generated tags are merged with yours — manual tags are kept."
          : "You've edited this summary. Regenerating replaces your version. Tags are kept and merged."
      )
    }
  }

  // MARK: Actions

  private func requestSummaryGeneration() {
    if enrichmentNeedsConfirm(record: controller.record, target: .summary) {
      confirmTarget = .summary
    } else {
      controller.generateSummary()
    }
  }

  private func requestTagGeneration() {
    if enrichmentNeedsConfirm(record: controller.record, target: .tags) {
      confirmTarget = .tags
    } else {
      controller.generateTags()
    }
  }

  private func beginSummaryEdit(narrative: String) {
    summaryDraft = narrative
    isEditingSummary = true
    if !isSummaryExpanded {
      isSummaryExpanded = true
      summaryDrawerHeight = SummaryDrawerLayout.clampedExpandedHeight(
        SummaryDrawerLayout.expandedDefaultHeight,
        availableHeight: availableHeight
      )
      onLayoutChange()
    }
  }

  private func saveSummaryEdit() {
    isEditingSummary = false
    controller.saveSummaryEdit(summaryDraft)
  }

  // MARK: State A — placeholder card

  private var placeholderCard: some View {
    VStack(spacing: 10) {
      Image(systemName: "text.badge.plus")
        .font(.title2)
        .foregroundStyle(.secondary)
      Text("No summary yet")
        .font(.headline)
      Text("Transcript-only record. Generate a summary or tags on demand.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      HStack(spacing: 8) {
        Button("Generate summary") { requestSummaryGeneration() }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
        Button("Tags only") { requestTagGeneration() }
          .buttonStyle(.bordered)
          .controlSize(.small)
      }
      .padding(.top, 2)
      errorCaption
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 20)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(
          style: StrokeStyle(lineWidth: 1, dash: [5, 4])
        )
        .foregroundStyle(.secondary.opacity(0.4))
    )
    .padding(.leading, Metrics.gutterWidth)
    .padding(.trailing, Metrics.richTextInsetX)
    .padding(.vertical, 10)
  }

  // MARK: In-flight row

  private func inFlightRow(kind: EnrichmentActivity, modelID: String) -> some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
      // No cost estimate: pricing isn't cheaply derivable here, and the T5
      // rule forbids inventing a number — model name only.
      Text("Generating \(kind == .tagging ? "tags" : "summary") — \(modelID)")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Spacer()
      Button("Cancel") { controller.cancelGeneration() }
        .controlSize(.small)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    .padding(.leading, Metrics.gutterWidth)
    .padding(.trailing, Metrics.richTextInsetX)
    .padding(.vertical, 10)
  }

  // MARK: State B — summary section

  private func summarySection(narrative: String, edited: Bool) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      summaryHeader(narrative: narrative, edited: edited)

      // Decision 5: a rename/accept on a record that already has a summary
      // leaves the narrative referencing the old label. One-click
      // "Regenerate summary" until used or dismissed; the record's
      // summaryOutdated flag (cleared by the CLI on regeneration or by the
      // dismiss below) drives visibility.
      if controller.record?.isSummaryOutdated == true {
        outdatedSummaryBanner
      }

      if isSummaryExpanded {
        ScrollView(.vertical) {
          expandedSummaryContent(narrative: narrative)
            .padding(.bottom, 8)
        }
        .frame(maxHeight: .infinity)
        .layoutPriority(1)
      } else {
        compactSummaryPreview(narrative: narrative)
          .frame(maxHeight: .infinity, alignment: .topLeading)
      }

      summaryResizeDivider
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: isSummaryExpanded ? expandedSummaryHeight : SummaryDrawerLayout.compactHeight)
    .padding(.leading, Metrics.gutterWidth)
    .padding(.trailing, Metrics.richTextInsetX)
    .padding(.vertical, 10)
  }

  private var expandedSummaryHeight: CGFloat {
    SummaryDrawerLayout.clampedExpandedHeight(
      summaryDrawerHeight,
      availableHeight: availableHeight
    )
  }

  /// One-click regenerate affordance for a record whose summary references
  /// pre-rename speaker labels (decision 5). Regenerate runs the same
  /// confirm-gated path as the header button; the × dismisses the reminder
  /// via the apply-enrichment plumbing (`summaryOutdated: false`).
  private var outdatedSummaryBanner: some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.yellow)
      Text("Speaker names changed — the summary still references the old names.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .help("Regenerate to update the summary with the renamed speakers")
      Spacer(minLength: 4)
      Button("Regenerate summary") {
        requestSummaryGeneration()
      }
      .controlSize(.small)
      .help("Regenerate the summary with the updated speaker names")
      Button {
        controller.dismissSummaryOutdated()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Dismiss this reminder")
      .accessibilityLabel("Dismiss summary reminder")
    }
    .padding(.horizontal, Metrics.tagPillH * 2)
    .padding(.vertical, Metrics.tagPillV * 2)
    .background(.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
  }

  private func summaryHeader(narrative: String, edited: Bool) -> some View {
    HStack(spacing: 8) {
      HStack(spacing: 8) {
        Text("Summary")
          .font(.headline)
        if edited {
          Text("Edited")
            .font(.caption2)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, Metrics.tagPillH)
            .padding(.vertical, Metrics.tagPillV)
            .background(Tokens.primaryActionTint, in: Capsule())
        }
        if controller.isSavingEdit {
          ProgressView()
            .controlSize(.mini)
        }
      }

      Spacer(minLength: 8)

      if !isEditingSummary {
        Button("Edit") { beginSummaryEdit(narrative: narrative) }
          .controlSize(.small)
        Button {
          requestSummaryGeneration()
        } label: {
          Label("Regenerate", systemImage: "arrow.clockwise")
        }
        .controlSize(.small)
      }

      Button {
        toggleSummaryExpansion()
      } label: {
        Label(
          isSummaryExpanded ? "Show less" : "Show more",
          systemImage: isSummaryExpanded ? "chevron.up" : "chevron.down"
        )
      }
      .controlSize(.small)
      .disabled(isEditingSummary)
      .help(isSummaryExpanded ? "Collapse summary" : "Expand summary")
      .accessibilityLabel(isSummaryExpanded ? "Collapse summary" : "Expand summary")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func compactSummaryPreview(narrative: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(SummaryDrawerLayout.preview(for: narrative))
        .font(.body)
        .lineLimit(3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { beginSummaryEdit(narrative: narrative) }
        .help("Click to edit. Expand summary to read the full text.")
        .accessibilityHint("Click to edit. Use Show more to read the full summary.")
      errorCaption
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func expandedSummaryContent(narrative: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if isEditingSummary {
        TextEditor(text: $summaryDraft)
          .font(.body)
          .scrollContentBackground(.hidden)
          .padding(6)
          .frame(minHeight: 100, maxHeight: 220)
          .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
          )
          .onExitCommand { isEditingSummary = false }
        HStack(spacing: 8) {
          Spacer()
          Button("Cancel") { isEditingSummary = false }
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
          Button("Save") { saveSummaryEdit() }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(summaryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      } else {
        // Click-in is the second entry into edit mode (dual entry per E2).
        Text(narrative)
          .font(.body)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
          .onTapGesture { beginSummaryEdit(narrative: narrative) }
          .help("Click to edit")
      }
      structuredSummary
      errorCaption
    }
  }

  @ViewBuilder
  private var summaryResizeDivider: some View {
    let divider = ZStack {
      Rectangle()
        .fill(Color(nsColor: .separatorColor))
        .frame(height: 1)
      Image(systemName: "ellipsis")
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 4)
        .background(.background)
    }
    .frame(height: 12)
    .frame(maxWidth: .infinity)
    .contentShape(Rectangle())
    .accessibilityElement()
    .accessibilityLabel("Summary size")
    .accessibilityValue(
      isSummaryExpanded
        ? "\(Int(expandedSummaryHeight.rounded())) points"
        : "Compact"
    )
    .accessibilityHint(
      isSummaryExpanded
        ? "Drag up or down to resize the summary."
        : "Expand the summary to resize it."
    )
    .accessibilityAdjustableAction { direction in
      guard isSummaryExpanded else { return }
      switch direction {
      case .increment: adjustSummaryHeight(by: 24)
      case .decrement: adjustSummaryHeight(by: -24)
      @unknown default: break
      }
    }

    if isSummaryExpanded {
      divider
        .gesture(
          // Gesture values resolve in the pane's named coordinate space
          // (stable while the drawer resizes) rather than the divider's
          // local space, whose origin moves with the divider and would feed
          // the height change back into the next event's measurement.
          DragGesture(minimumDistance: 2, coordinateSpace: .named(PaneCoordinateSpace.name))
            .onChanged { value in
              if summaryResizeStartHeight == nil {
                summaryResizeStartHeight = expandedSummaryHeight
                summaryResizeStartY = value.startLocation.y
                onResizeStateChange(true)
              }
              let start = summaryResizeStartHeight ?? expandedSummaryHeight
              let startY = summaryResizeStartY ?? value.startLocation.y
              // Recomputed from the gesture anchor on every event: a pure
              // function of the pointer position, so the applied height can
              // never feed back into the next measurement.
              let next = SummaryDrawerLayout.dragTargetHeight(
                startHeight: start,
                startY: startY,
                currentY: value.location.y,
                availableHeight: availableHeight
              )
              guard next != summaryDrawerHeight else { return }
              summaryDrawerHeight = next
              // No onLayoutChange per tick: the transcript scroll restoration
              // is coalesced to the end of the drag so it cannot chase a
              // viewport that is still moving.
            }
            .onEnded { _ in
              summaryResizeStartHeight = nil
              summaryResizeStartY = nil
              onLayoutChange()
              onResizeStateChange(false)
            }
        )
        .onDisappear {
          // A drag interrupted by this view leaving the hierarchy (drawer
          // collapse, slot teardown, window close) never fires onEnded, so the
          // next drag would reuse the stale anchor and the host would never
          // learn the resize ended. Reset both anchors and report inactive.
          summaryResizeStartHeight = nil
          summaryResizeStartY = nil
          onResizeStateChange(false)
        }
    } else {
      divider
    }
  }

  private func toggleSummaryExpansion() {
    isSummaryExpanded.toggle()
    if isSummaryExpanded {
      summaryDrawerHeight = SummaryDrawerLayout.clampedExpandedHeight(
        SummaryDrawerLayout.expandedDefaultHeight,
        availableHeight: availableHeight
      )
    }
    onLayoutChange()
  }

  private func adjustSummaryHeight(by delta: CGFloat) {
    guard isSummaryExpanded else { return }
    let current = expandedSummaryHeight
    let next = SummaryDrawerLayout.clampedExpandedHeight(
      current + delta,
      availableHeight: availableHeight
    )
    guard next != current else { return }
    summaryDrawerHeight = next
    onLayoutChange()
  }

  // MARK: Structured summary (topics / decisions / action items, read-only)

  private var keyTopics: [String] { controller.record?.summary?.keyTopics ?? [] }
  private var decisions: [String] { controller.record?.summary?.decisions ?? [] }
  private var actionItems: [String] { controller.record?.summary?.actionItems ?? [] }

  /// Compact rendering of the record's structured summary fields. Read-only —
  /// the narrative above keeps the only edit affordances. Renders nothing when
  /// all three arrays are empty, so the slot looks exactly as before.
  @ViewBuilder
  private var structuredSummary: some View {
    if !keyTopics.isEmpty {
      topicsBlock
    }
    if !decisions.isEmpty && !actionItems.isEmpty {
      // Two wrapped columns when the pane is wide, stacked when it is narrow.
      // Branches on the MEASURED container width, not ViewThatFits: that keys
      // off ideal (unwrapped single-line) text width, which never fits for
      // sentence-length items and still picks two cramped columns for short
      // ones in a narrow pane.
      Group {
        if structuredColumnsWidth >= Self.twoColumnMinWidth {
          HStack(alignment: .top, spacing: 18) {
            decisionsColumn
              .frame(maxWidth: .infinity, alignment: .leading)
            actionItemsColumn
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        } else {
          VStack(alignment: .leading, spacing: 12) {
            decisionsColumn
            actionItemsColumn
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .onGeometryChange(for: CGFloat.self) { proxy in
        proxy.size.width
      } action: { width in
        structuredColumnsWidth = width
      }
      .padding(.top, 4)
    } else if !decisions.isEmpty {
      decisionsColumn
        .padding(.top, 4)
    } else if !actionItems.isEmpty {
      actionItemsColumn
        .padding(.top, 4)
    }
  }

  private var topicsBlock: some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionLabel("Topics")
      FlowLayout(spacing: Metrics.tagSpacing, lineSpacing: Metrics.tagSpacing) {
        // Positional identity: these arrays come verbatim from the LLM and are
        // never deduplicated, so `id: \.self` could collide on a repeated item.
        ForEach(Array(keyTopics.enumerated()), id: \.offset) { _, topic in
          topicChip(topic)
        }
      }
    }
    .padding(.top, 4)
  }

  /// One capsule per key topic: the term on the face, the ` — ` detail (when
  /// present) as a hover tooltip.
  @ViewBuilder
  private func topicChip(_ topic: String) -> some View {
    let parts = topicChipParts(topic)
    // One line always: when FlowLayout clamps an over-wide chip to the row
    // width, the term truncates with an ellipsis instead of wrapping inside
    // the capsule.
    let chip = Text(strippingInlineMarkdown(parts.term))
      .font(.caption)
      .lineLimit(1)
      .padding(.horizontal, 9)
      .padding(.vertical, 3)
      .background(.thinMaterial, in: Capsule())
      .overlay(Capsule().strokeBorder(.secondary.opacity(0.3)))
    if let detail = parts.detail {
      chip.help(strippingInlineMarkdown(detail))
    } else {
      chip
    }
  }

  private var decisionsColumn: some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionLabel("Decisions")
      ForEach(Array(decisions.enumerated()), id: \.offset) { _, item in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text("•")
            .foregroundStyle(.tertiary)
          // fixedSize: after the stacked→two-column width flip, a plain Text
          // can keep the narrower layout's cached 2-line height and truncate
          // mid-word; forcing ideal vertical size always shows every line.
          Text(inlineMarkdownAttributed(item))
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private var actionItemsColumn: some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionLabel("Action Items")
      ForEach(Array(actionItems.enumerated()), id: \.offset) { _, item in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: "square")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(inlineMarkdownAttributed(displayActionItem(item)))
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private func sectionLabel(_ title: String) -> some View {
    Text(title)
      .kerning(0.8)
      .textCase(.uppercase)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(.secondary)
  }

  /// The pipeline writes action items as `[ ] …` checkboxes; the square icon
  /// already carries that affordance here, so strip the textual prefix.
  private func displayActionItem(_ item: String) -> String {
    item.hasPrefix("[ ] ") ? String(item.dropFirst(4)) : item
  }

  @ViewBuilder
  private var errorCaption: some View {
    if let message = controller.errorMessage {
      Text(message)
        .font(.caption)
        .foregroundStyle(.red)
        .lineLimit(2)
    }
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
