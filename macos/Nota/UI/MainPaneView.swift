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
        RichDocumentPane(
          document: document,
          speakerChips: $speakerChips,
          onRename: onRename,
          enrichment: EnrichmentController.shared
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
          tagEditing: tagEditing
        )
        Divider()
      }
      EnrichmentSlotView(controller: enrichment)
      RichTextViewer(
        attributedString: MainPaneView.applySpeakerColors(to: document.body, chips: speakerChips),
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

  @State private var isEditingSummary = false
  @State private var summaryDraft = ""
  @State private var confirmTarget: EnrichmentField?

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
        Spacer()
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
      }

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
    .padding(.leading, Metrics.gutterWidth)
    .padding(.trailing, Metrics.richTextInsetX)
    .padding(.vertical, 10)
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
      // Two columns side by side when they fit, stacked when the pane is narrow.
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 18) {
          decisionsColumn
            .frame(maxWidth: .infinity, alignment: .leading)
          actionItemsColumn
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        VStack(alignment: .leading, spacing: 12) {
          decisionsColumn
          actionItemsColumn
        }
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
        ForEach(keyTopics, id: \.self) { topic in
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
    let chip = Text(parts.term)
      .font(.caption)
      .padding(.horizontal, 9)
      .padding(.vertical, 3)
      .background(.thinMaterial, in: Capsule())
      .overlay(Capsule().strokeBorder(.secondary.opacity(0.3)))
    if let detail = parts.detail {
      chip.help(detail)
    } else {
      chip
    }
  }

  private var decisionsColumn: some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionLabel("Decisions")
      ForEach(decisions, id: \.self) { item in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text("•")
            .foregroundStyle(.tertiary)
          Text(item)
            .font(.subheadline)
        }
      }
    }
  }

  private var actionItemsColumn: some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionLabel("Action Items")
      ForEach(actionItems, id: \.self) { item in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: "square")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(displayActionItem(item))
            .font(.subheadline)
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
