import SwiftUI

// MARK: - Summary rail (XIA-415)

/// The summary rail: a fixed-width (380pt, decision 1) SwiftUI overlay
/// anchored in the window's bottom-right corner that holds everything the
/// transcript's enrichment slot used to — narrative, topics, decisions,
/// action items, the `summaryOutdated` banner, the in-flight row (model name
/// + Cancel), and failures with Retry — plus Edit / Regenerate / Close
/// (decision 5). One size, no compact/expanded states, no divider drag
/// (decision 3).
///
/// The rail owns its dismissal surface (full-window backdrop + hidden Escape
/// button, the same treatment the history drawer's host layer uses) so every
/// close runs the decision-13 draft policy from the one place that knows the
/// draft: not editing → close; Save it → commit + close; Ask me → confirm
/// (save / discard / keep editing). The policy itself lives on `NotaModel`
/// because record switches and phase leaves close the rail from the model
/// side (decisions 6/7) and must resolve the draft before the record is
/// replaced.
struct SummaryRailView: View {
  @ObservedObject var model: NotaModel
  @ObservedObject private var enrichment = EnrichmentController.shared
  /// Confirm-gated regeneration over an edited summary (decision 5).
  @State private var confirmTarget: EnrichmentField?
  /// Measured width of the decisions/action-items block, driving the
  /// two-columns-vs-stacked choice (see `structuredSummary`). Kept exactly as
  /// the slot had it — at 380pt the rail permanently takes the stacked arm
  /// (decision 4).
  @State private var structuredColumnsWidth: CGFloat = 0
  /// How tall the narrative reads when it is not being edited, so the editor
  /// can open at that height rather than jumping to a fixed minimum.
  @State private var narrativeHeight: CGFloat = 0

  /// Minimum measured width at which decisions + action items render side by
  /// side; below it they stack. Each column keeps a readable wrapped measure
  /// (~28 characters of `.subheadline`) at this threshold. Do NOT lower this
  /// or swap in `ViewThatFits` — that was tried and rejected (decision 4).
  private static let twoColumnMinWidth: CGFloat = 480

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      // Full-window backdrop: click-outside dismisses through the draft
      // policy. The panel floats above it; the window content is inert while
      // the rail is up, exactly like the history drawer's layer.
      Color.black.opacity(0.0001)
        .contentShape(Rectangle())
        .onTapGesture { requestDismissal() }
        .ignoresSafeArea()

      panel
        .padding(CraftTokens.spacing16)
        .zIndex(1)

      // Escape dismisses via a hidden cancel action — but while editing it
      // COMMITS under the default setting (decision 13, taken knowingly:
      // "Escape commits while editing, inverting its usual meaning").
      Button("") { requestDismissal() }
        .keyboardShortcut(.cancelAction)
        .hidden()
    }
    .alert(
      "Replace your edited summary?",
      isPresented: Binding(
        get: { confirmTarget == .summary },
        set: { if !$0 { confirmTarget = nil } }
      )
    ) {
      Button("Cancel", role: .cancel) { confirmTarget = nil }
      Button("Regenerate") {
        enrichment.generateSummary(force: true)
        confirmTarget = nil
      }
    } message: {
      Text("You've edited this summary. Regenerating replaces your version. Tags are kept and merged.")
    }
    .alert(
      "Unsaved summary edits",
      isPresented: $showDismissConfirm
    ) {
      Button("Save") { model.resolveSummaryRailDismissal(.save) }
      Button("Discard", role: .destructive) { model.resolveSummaryRailDismissal(.discard) }
      Button("Keep Editing", role: .cancel) { model.resolveSummaryRailDismissal(.keepEditing) }
    } message: {
      Text("Close the summary with unsaved edits?")
    }
    .onChange(of: model.isSummaryRailDismissalPending) { _, pending in
      showDismissConfirm = pending
    }
  }

  // MARK: Dismissal (decision 13)

  /// Ask-me confirm presentation mirror (see the alert wiring above: the
  /// alert's binding must not double-resolve through the model flag).
  @State private var showDismissConfirm = false

  private func requestDismissal() {
    model.requestSummaryRailDismissal()
  }

  // MARK: Panel

  private var panel: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      content
    }
    .frame(width: SummaryDrawerLayout.railWidth)
    .frame(maxHeight: .infinity, alignment: .top)
    .craftGlassPanel(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
  }

  private var isGenerating: Bool {
    enrichment.activity != .idle
  }

  private var hasNarrative: Bool {
    enrichment.record?.hasSummaryNarrative ?? false
  }

  private var isEditing: Bool {
    model.isSummaryEditing
  }

  private var record: EnrichmentRecord? {
    enrichment.record
  }

  // MARK: Header (title, Edit, Regenerate, Close — decision 5)

  private var header: some View {
    HStack(spacing: 8) {
      HStack(spacing: 8) {
        Text("Summary")
          .font(.headline)
        if record?.isSummaryEdited == true {
          Text("Edited")
            .font(.caption2)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, Metrics.tagPillH)
            .padding(.vertical, Metrics.tagPillV)
            .background(Tokens.primaryActionTint, in: Capsule())
        }
        if enrichment.isSavingEdit {
          ProgressView()
            .controlSize(.mini)
        }
      }

      Spacer(minLength: 8)

      if isEditing {
        Button("Cancel") { cancelEdit() }
          .controlSize(.small)
        Button("Save") { saveEdit() }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(model.summaryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      } else {
        Button("Edit") { beginEdit() }
          .controlSize(.small)
          .disabled(!hasNarrative || isGenerating)
        Button {
          requestRegenerate()
        } label: {
          Label("Regenerate", systemImage: "arrow.clockwise")
        }
        .controlSize(.small)
        .disabled(!hasNarrative || isGenerating)
      }

      Button(action: requestDismissal) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Close (Esc)")
      .accessibilityLabel("Close summary")
    }
    .padding(.horizontal, CraftTokens.spacing16)
    .padding(.top, CraftTokens.spacing16)
    .padding(.bottom, CraftTokens.spacing12)
  }

  // MARK: Content (in-flight → summary → failure)

  @ViewBuilder
  private var content: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        if isGenerating {
          inFlightRow
        } else if hasNarrative {
          // Decision 5: a rename/accept on a record that already has a
          // summary leaves the narrative referencing the old label. One-click
          // "Regenerate summary" until used or dismissed.
          if record?.isSummaryOutdated == true {
            outdatedSummaryBanner
          }

          if isEditing {
            editor
          } else {
            Text(record?.summary?.narrative ?? "")
              .font(.body)
              .frame(maxWidth: .infinity, alignment: .leading)
              // Remember how tall the narrative reads, so clicking into it
              // opens an editor of the same height instead of jumping to a
              // fixed minimum. A three-line summary should not become a
              // 100pt box under the cursor.
              .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
              } action: { height in
                narrativeHeight = height
              }
              .contentShape(Rectangle())
              .onTapGesture { beginEdit() }
              .help("Click to edit")
          }
          structuredSummary
          errorCaption
        } else {
          // No narrative and not generating: only reachable after a failed
          // generation — the button opens the rail only when it starts one
          // (decision 10), so this state is a failure, not a placeholder.
          failureBlock
        }
      }
      .padding(.horizontal, CraftTokens.spacing16)
      .padding(.bottom, CraftTokens.spacing16)
    }
  }

  private var inFlightRow: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
      // No cost estimate: pricing isn't cheaply derivable here, and the T5
      // rule forbids inventing a number — model name only.
      Text(
        "Generating \(enrichment.activity == .tagging ? "tags" : "summary") — \(enrichment.generatingModelID)"
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)
      Spacer()
      Button("Cancel") {
        enrichment.cancelGeneration()
        // Cancelling with no summary leaves nothing to show — close the rail
        // (there is no path to an empty rail, decision 10).
        if !hasNarrative {
          model.closeSummaryRail()
        }
      }
      .controlSize(.small)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
  }

  static let editorMinHeight: CGFloat = 64
  static let editorMaxHeight: CGFloat = 220

  /// What Escape does, in the words of the setting that decides it — the
  /// caption may not promise a commit the `Ask me` policy will not make.
  private var escapeCaption: String {
    switch model.summaryDismissalBehavior {
    case .save: return "Esc closes and saves your changes"
    case .ask: return "Esc closes — you'll be asked about unsaved changes"
    }
  }

  private var editor: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextEditor(text: $model.summaryDraft)
        .font(.body)
        .scrollContentBackground(.hidden)
        .padding(6)
        // Open at the height the narrative was just reading at (plus the
        // editor's own padding), not at a fixed minimum — swapping a Text for
        // a TextEditor must not move the text under the cursor that clicked
        // it. Floored so a one-line summary is still a usable box, capped so
        // a long one scrolls rather than pushing the rail's chrome off.
        .frame(
          minHeight: min(max(narrativeHeight + 12, Self.editorMinHeight), Self.editorMaxHeight),
          maxHeight: Self.editorMaxHeight
        )
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
        )
        // Escape is the dismissal gesture while editing (decision 13) — it
        // commits under the default setting rather than cancelling the edit.
        //
        // It has to be delivered HERE and not only by the panel's hidden
        // `.cancelAction` button: `TextEditor` is an `NSTextView`, which
        // answers `cancelOperation:` itself and never forwards it to a
        // SwiftUI ancestor. The same trap is documented on the dictation
        // review card, where ⌘↩/Escape need a local key monitor for exactly
        // this reason. With the caret in this editor — the only state where
        // decision 13 means anything — the hidden button is unreachable, so
        // Escape would be a silent no-op underneath a caption promising it
        // works. The hidden button still covers the not-editing case.
        .onExitCommand { requestDismissal() }
      Text(escapeCaption)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
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
        requestRegenerate()
      }
      .controlSize(.small)
      .help("Regenerate the summary with the updated speaker names")
      Button {
        enrichment.dismissSummaryOutdated()
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

  /// A failed generation with nothing to show: the message plus Retry
  /// (decision 5 — failures with Retry live in the rail).
  private var failureBlock: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let message = enrichment.errorMessage {
        Label(message, systemImage: "exclamationmark.triangle")
          .font(.subheadline)
          .foregroundStyle(.red)
          .lineLimit(3)
      }
      Button("Retry") {
        requestRegenerate()
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 8)
  }

  @ViewBuilder
  private var errorCaption: some View {
    if let message = enrichment.errorMessage, enrichment.errorActivity != .tagging {
      Text(message)
        .font(.caption)
        .foregroundStyle(.red)
        .lineLimit(2)
    }
  }

  // MARK: Actions

  private func requestRegenerate() {
    if enrichmentNeedsConfirm(record: record, target: .summary) {
      confirmTarget = .summary
    } else {
      enrichment.generateSummary()
    }
  }

  private func beginEdit() {
    model.summaryDraft = record?.summary?.narrative ?? ""
    model.isSummaryEditing = true
  }

  private func cancelEdit() {
    model.isSummaryEditing = false
    model.summaryDraft = ""
  }

  private func saveEdit() {
    let trimmed = model.summaryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    model.isSummaryEditing = false
    enrichment.saveSummaryEdit(trimmed)
    model.summaryDraft = ""
  }

  // MARK: Structured summary (topics / decisions / action items, read-only)

  private var keyTopics: [String] { record?.summary?.keyTopics ?? [] }
  private var decisions: [String] { record?.summary?.decisions ?? [] }
  private var actionItems: [String] { record?.summary?.actionItems ?? [] }

  /// Compact rendering of the record's structured summary fields. Read-only —
  /// the narrative above keeps the only edit affordances. Renders nothing when
  /// all three arrays are empty.
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
      // ones in a narrow pane. Left exactly as the slot had it (decision 4):
      // at 380pt the rail permanently takes the stacked arm.
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
}
