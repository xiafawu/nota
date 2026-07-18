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
          SpeakerChipStrip(chips: $chips, onRename: onRename)
            .padding(.top, Metrics.tagTopPadding)
        }

        if !meta.tags.isEmpty {
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

  var body: some View {
    FlowLayout(spacing: Metrics.tagSpacing, lineSpacing: Metrics.tagSpacing) {
      ForEach(Array(chips.enumerated()), id: \.element.id) { index, _ in
        SpeakerChipButton(
          chip: $chips[index],
          color: SpeakerColors.color(at: index),
          onRename: onRename
        )
      }
    }
  }
}

private struct SpeakerChipButton: View {
  @Binding var chip: SpeakerChip
  let color: Color
  let onRename: (_ label: String, _ newName: String) -> Void

  @State private var showRenamePopover = false
  @State private var draft = ""

  private var displayName: String {
    chip.name.isEmpty ? chip.label : chip.name
  }

  var body: some View {
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
    .background(Tokens.tagPillFill, in: Capsule())
    .help(helpText)
    .popover(isPresented: $showRenamePopover, arrowEdge: .bottom) {
      renamePopover
    }
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
