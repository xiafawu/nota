import SwiftUI

/// Pinned header above the scrollable rich-text body: title, a muted
/// "date · duration" subtitle, speaker chips (when present), and tag pills.
/// Replaces the old wall of bold-label metadata lines (`**Captured:** …`) that
/// used to render inline in the text. Left padding matches the body's gutter so
/// the title aligns with the transcript text below.
struct DocumentHeaderView: View {
  let meta: DocMeta
  @Binding var chips: [SpeakerChip]
  let onRename: (_ label: String, _ newName: String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Metrics.docHeaderSpacing) {
      Text(meta.title)
        .font(Tokens.docTitleFont)
        .fontWeight(.bold)
        .lineLimit(2)
        .textSelection(.enabled)

      if !meta.subtitle.isEmpty {
        Text(meta.subtitle)
          .font(Tokens.docSubtitleFont)
          .foregroundStyle(.secondary)
      }

      // Speaker chip strip — injected between subtitle and tags
      if !chips.isEmpty {
        SpeakerChipsView(chips: $chips, onRename: onRename)
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
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.leading, Metrics.gutterWidth)
    .padding(.trailing, Metrics.richTextInsetX)
    .padding(.top, Metrics.docHeaderTopPadding)
    .padding(.bottom, Metrics.docHeaderBottomPadding)
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
#endif
