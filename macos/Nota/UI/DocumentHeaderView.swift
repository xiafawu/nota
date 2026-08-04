import SwiftUI

/// Pinned header above the scrollable rich-text body: title, a muted
/// "date · duration" subtitle, speaker chips (when present), and tag pills.
/// Replaces the old wall of bold-label metadata lines (`**Captured:** …`) that
/// used to render inline in the text. Left padding matches the body's gutter so
/// the title aligns with the transcript text below.
///
/// `compact` collapses the header while the body is scrolled: the title drops
/// to a single headline line and the subtitle/chips/tags fold away, giving the
/// transcript back most of the window.
struct DocumentHeaderView: View {
  let meta: DocMeta
  @Binding var chips: [SpeakerChip]
  var compact: Bool = false
  let onRename: (_ label: String, _ newName: String) -> Void
  /// Accept/dismiss a chip's pending speaker suggestion (decision 4). No-ops
  /// when the caller doesn't surface suggestions (previews, imported docs).
  var onAcceptSuggestion: (_ label: String) -> Void = { _ in }
  var onDismissSuggestion: (_ label: String) -> Void = { _ in }
  /// Non-nil when the open document has a history record: tags render as
  /// editable chips driven by the record (×-on-hover removal plus an
  /// always-visible "+ add tag" chip). Nil keeps the static pills for
  /// imported markdown without a record.
  var tagEditing: EnrichmentTagEditing?

  var body: some View {
    VStack(alignment: .leading, spacing: Metrics.docHeaderSpacing) {
      Text(meta.title)
        .font(compact ? Tokens.docTitleCompactFont : Tokens.docTitleFont)
        .fontWeight(.bold)
        .lineLimit(compact ? 1 : 2)
        .truncationMode(.tail)
        .textSelection(.enabled)

      if !compact {
        if !meta.subtitle.isEmpty {
          Text(meta.subtitle)
            .font(Tokens.docSubtitleFont)
            .foregroundStyle(.secondary)
        }

        // Speaker chip strip — injected between subtitle and tags
        if !chips.isEmpty {
          SpeakerChipStrip(
            chips: $chips,
            onRename: onRename,
            onAcceptSuggestion: onAcceptSuggestion,
            onDismissSuggestion: onDismissSuggestion
          )
          .padding(.top, Metrics.tagTopPadding)
        }

        if let tagEditing {
          EditableTagRow(state: tagEditing)
            .padding(.top, Metrics.tagTopPadding)
        } else if !meta.tags.isEmpty {
          FlowLayout(spacing: Metrics.tagSpacing, lineSpacing: Metrics.tagSpacing) {
            ForEach(meta.tags, id: \.self) { tag in
              Text(tag)
                .font(Tokens.historyTagFont)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Metrics.tagPillH)
                .padding(.vertical, Metrics.tagPillV)
                .background(Tokens.tagPillFill, in: Capsule())
            }
          }
          .padding(.top, Metrics.tagTopPadding)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.leading, Metrics.gutterWidth)
    .padding(.trailing, Metrics.richTextInsetX)
    .padding(.top, compact ? Metrics.docHeaderCompactVerticalPadding : Metrics.docHeaderTopPadding)
    .padding(.bottom, compact ? Metrics.docHeaderCompactVerticalPadding : Metrics.docHeaderBottomPadding)
  }
}

// MARK: - Speaker chips

/// One chip per speaker: an identity-colored dot plus the final display name.
/// The diarization mapping ("Speaker 1 → Kenny Kim") is implementation detail —
/// it lives in the tooltip and the rename popover, never on the chip face.
private struct SpeakerChipStrip: View {
  @Binding var chips: [SpeakerChip]
  let onRename: (_ label: String, _ newName: String) -> Void
  var onAcceptSuggestion: (_ label: String) -> Void = { _ in }
  var onDismissSuggestion: (_ label: String) -> Void = { _ in }

  var body: some View {
    FlowLayout(spacing: Metrics.tagSpacing, lineSpacing: Metrics.tagSpacing) {
      ForEach(Array(chips.enumerated()), id: \.element.id) { index, _ in
        SpeakerChipButton(
          chip: $chips[index],
          color: SpeakerColors.color(at: index),
          onRename: onRename,
          onAcceptSuggestion: onAcceptSuggestion,
          onDismissSuggestion: onDismissSuggestion
        )
      }
    }
  }
}

private struct SpeakerChipButton: View {
  @Binding var chip: SpeakerChip
  let color: Color
  let onRename: (_ label: String, _ newName: String) -> Void
  var onAcceptSuggestion: (_ label: String) -> Void = { _ in }
  var onDismissSuggestion: (_ label: String) -> Void = { _ in }

  @State private var showRenamePopover = false
  @State private var draft = ""

  private var displayName: String {
    chip.name.isEmpty ? chip.label : chip.name
  }

  var body: some View {
    Group {
      if let suggestion = chip.suggestion {
        suggestionChip(suggestion)
      } else {
        renameChip
      }
    }
    .animation(Tokens.animSnap, value: chip.suggestion)
  }

  /// A pending suggestion takes over the chip face: `<label> → <name>?
  /// <score>` with accept/dismiss. Not a Button — the actions are the two
  /// buttons inside, so the whole face must not swallow their clicks.
  private func suggestionChip(_ suggestion: SpeakerSuggestion) -> some View {
    HStack(spacing: 4) {
      Circle()
        .fill(color)
        .frame(width: Metrics.speakerDotSize, height: Metrics.speakerDotSize)
      Text("\(chip.label) → \(suggestion.suggestedName)? \(suggestion.scoreText)")
        .font(Tokens.historyTagFont)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Button {
        onAcceptSuggestion(chip.label)
      } label: {
        Image(systemName: "checkmark")
          .font(.system(size: 8, weight: .bold))
      }
      .buttonStyle(.plain)
      .foregroundStyle(.green)
      .help("Accept \"\(suggestion.suggestedName)\" and enroll this voiceprint")
      .accessibilityLabel("Accept suggestion")
      Button {
        onDismissSuggestion(chip.label)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("Dismiss this suggestion")
      .accessibilityLabel("Dismiss suggestion")
    }
    .padding(.horizontal, Metrics.tagPillH)
    .padding(.vertical, Metrics.tagPillV)
    .background(
      Capsule()
        .strokeBorder(
          style: StrokeStyle(lineWidth: 1, dash: [2, 2])
        )
        .foregroundStyle(color.opacity(0.7))
    )
    .help(suggestionHelp(suggestion))
  }

  /// The usual rename face. Chips with no name yet render a subtle
  /// unnamed state — dashed outline + tertiary text — so "still needs a
  /// name" reads at a glance without shouting (decision 5).
  private var renameChip: some View {
    Button {
      draft = chip.name
      showRenamePopover = true
    } label: {
      HStack(spacing: 4) {
        Circle()
          .fill(color)
          .frame(width: Metrics.speakerDotSize, height: Metrics.speakerDotSize)
        Text(displayName)
          .font(Tokens.historyTagFont)
          .foregroundStyle(chip.name.isEmpty ? .tertiary : .secondary)
          .lineLimit(1)
        statusAccessory
      }
      .padding(.horizontal, Metrics.tagPillH)
      .padding(.vertical, Metrics.tagPillV)
    }
    .buttonStyle(.plain)
    .background(unnamed ? AnyShapeStyle(Color.clear) : AnyShapeStyle(Tokens.tagPillFill), in: Capsule())
    .overlay {
      if unnamed {
        Capsule()
          .strokeBorder(
            style: StrokeStyle(lineWidth: 1, dash: [3, 2])
          )
          .foregroundStyle(.secondary.opacity(0.5))
      }
    }
    .help(helpText)
    .popover(isPresented: $showRenamePopover, arrowEdge: .bottom) {
      renamePopover
    }
  }

  /// True when the chip has no display name and no suggestion pending.
  private var unnamed: Bool {
    chip.name.isEmpty && chip.suggestion == nil
  }

  private func suggestionHelp(_ suggestion: SpeakerSuggestion) -> String {
    "\(chip.label) → \(suggestion.suggestedName)? \(suggestion.scoreText) — accept or dismiss"
  }

  /// Enroll status rides as a small accessory; the dot is reserved for the
  /// speaker's identity color.
  @ViewBuilder
  private var statusAccessory: some View {
    switch chip.indicator {
    case .enrolling:
      ProgressView().controlSize(.mini).scaleEffect(0.7)
    case .skipped:
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 8))
        .foregroundStyle(.yellow)
    case .failed:
      Image(systemName: "exclamationmark.circle.fill")
        .font(.system(size: 8))
        .foregroundStyle(.red)
    case .none, .pending, .enrolled:
      EmptyView()
    }
  }

  private var helpText: String {
    var parts: [String] = []
    if chip.name.isEmpty {
      parts.append("\(chip.label) — click to name this speaker")
    } else if chip.name != chip.label {
      parts.append("\(chip.label) → \(chip.name)")
    } else {
      parts.append(chip.name)
    }
    if let tooltip = chip.indicator.tooltip {
      parts.append(tooltip)
    }
    return parts.joined(separator: " · ")
  }

  private var renamePopover: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(chip.label)
        .font(.caption)
        .foregroundStyle(.secondary)
      TextField("Speaker name", text: $draft)
        .frame(width: Metrics.speakerPopoverFieldWidth)
        .onSubmit { commit() }
      if let tooltip = chip.indicator.tooltip {
        Text(tooltip)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .frame(maxWidth: Metrics.speakerPopoverFieldWidth, alignment: .leading)
      }
    }
    .padding(12)
  }

  private func commit() {
    showRenamePopover = false
    onRename(chip.label, draft.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

// MARK: - Editable tags (record-driven)

/// Inputs for the editable tag row: current record tags plus add/remove
/// callbacks that persist through the CLI's apply-enrichment verb.
struct EnrichmentTagEditing {
  var tags: [String]
  var onAdd: (String) -> Void
  var onRemove: (String) -> Void
}

private struct EditableTagRow: View {
  let state: EnrichmentTagEditing

  var body: some View {
    FlowLayout(spacing: Metrics.tagSpacing, lineSpacing: Metrics.tagSpacing) {
      ForEach(state.tags, id: \.self) { tag in
        RemovableTagChip(tag: tag, onRemove: { state.onRemove(tag) })
      }
      AddTagChip(onAdd: state.onAdd)
    }
  }
}

/// A tag pill whose × affordance appears only on hover (E2: chips clean at rest).
private struct RemovableTagChip: View {
  let tag: String
  let onRemove: () -> Void

  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 3) {
      Text(tag)
        .font(Tokens.historyTagFont)
        .foregroundStyle(.secondary)
      if isHovering {
        Button(action: onRemove) {
          Image(systemName: "xmark")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Remove tag")
      }
    }
    .padding(.horizontal, Metrics.tagPillH)
    .padding(.vertical, Metrics.tagPillV)
    .background(Tokens.tagPillFill, in: Capsule())
    .onHover { isHovering = $0 }
    .animation(Tokens.animSnap, value: isHovering)
  }
}

/// Always-visible dashed "+ add tag" chip; clicking reveals an inline field
/// (Enter commits, Esc or focus loss cancels).
private struct AddTagChip: View {
  let onAdd: (String) -> Void

  @State private var isEditing = false
  @State private var draft = ""
  @FocusState private var fieldFocused: Bool

  var body: some View {
    Group {
      if isEditing {
        TextField("tag", text: $draft)
          .font(Tokens.historyTagFont)
          .textFieldStyle(.plain)
          .frame(minWidth: 56, maxWidth: 110)
          .focused($fieldFocused)
          .onSubmit { commit() }
          .onExitCommand { cancel() }
          .onChange(of: fieldFocused) { _, focused in
            if !focused { cancel() }
          }
          .padding(.horizontal, Metrics.tagPillH)
          .padding(.vertical, Metrics.tagPillV)
          .background(
            Capsule().strokeBorder(.secondary.opacity(0.4), lineWidth: 1)
          )
          .onAppear { fieldFocused = true }
      } else {
        Button {
          draft = ""
          isEditing = true
        } label: {
          HStack(spacing: 2) {
            Image(systemName: "plus")
              .font(.system(size: 7, weight: .bold))
            Text("add tag")
              .font(Tokens.historyTagFont)
          }
          .foregroundStyle(.secondary)
          .padding(.horizontal, Metrics.tagPillH)
          .padding(.vertical, Metrics.tagPillV)
        }
        .buttonStyle(.plain)
        .background(
          Capsule()
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            .foregroundStyle(.secondary.opacity(0.5))
        )
        .help("Add a tag")
      }
    }
    .animation(Tokens.animSnap, value: isEditing)
  }

  private func commit() {
    let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    isEditing = false
    fieldFocused = false
    draft = ""
    if !value.isEmpty {
      onAdd(value)
    }
  }

  private func cancel() {
    isEditing = false
    fieldFocused = false
    draft = ""
  }
}

#if DEBUG
#Preview("header – no chips") {
  DocumentHeaderView(
    meta: DocMeta(
      title: "Reflecting on Self and Confidence",
      subtitle: "May 20 · 51 min",
      tags: ["self-awareness", "confidence", "personal-growth", "empathy"]
    ),
    chips: .constant([]),
    onRename: { _, _ in }
  )
  .frame(width: 600)
}

#Preview("header – with chips") {
  @Previewable @State var chips: [SpeakerChip] = [
    SpeakerChip(label: "Speaker 1", name: "", indicator: .none),
    SpeakerChip(label: "Speaker 2", name: "Alice", indicator: .enrolled),
  ]
  DocumentHeaderView(
    meta: DocMeta(
      title: "Team Sync",
      subtitle: "May 20 · 30 min",
      tags: ["product", "sync"]
    ),
    chips: $chips,
    onRename: { _, _ in }
  )
  .frame(width: 600)
}

#Preview("header – compact") {
  DocumentHeaderView(
    meta: DocMeta(
      title: "Reflecting on Self and Confidence",
      subtitle: "May 20 · 51 min",
      tags: ["self-awareness", "confidence"]
    ),
    chips: .constant([]),
    compact: true,
    onRename: { _, _ in }
  )
  .frame(width: 600)
}
#endif
