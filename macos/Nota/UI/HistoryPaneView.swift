import AppKit
import SwiftUI

struct HistoryPaneView: View {
  let state: HistoryPaneState
  @Binding var selectedID: HistoryEntry.ID?
  let onNewTranscription: () -> Void
  let onOpen: (HistoryEntry.ID) -> Void
  let onReveal: (HistoryEntry.ID) -> Void
  let onDelete: (HistoryEntry.ID) -> Void

  var body: some View {
    VStack(spacing: 0) {
      Button {
        onNewTranscription()
      } label: {
        HStack(spacing: Metrics.newButtonStackSpacing) {
          Image(systemName: "square.and.pencil")
          Text("New Transcription")
            .fontWeight(.medium)
          Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.newButtonH)
        .padding(.vertical, Metrics.newButtonV)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .liquidGlass(.regular.tint(Tokens.primaryActionTint), in: RoundedRectangle(cornerRadius: Metrics.primaryActionCornerRadius))
      .padding(.horizontal, Metrics.newButtonOuterH)
      .padding(.top, Metrics.newButtonOuterTop)
      .padding(.bottom, Metrics.newButtonOuterBottom)
      .disabled(state.isRunning)

      if state.rows.isEmpty {
        Spacer()
        VStack(spacing: Metrics.emptyHistoryStackSpacing) {
          Image(systemName: "tray")
            .font(Tokens.emptyHistoryIconFont)
            .foregroundStyle(.secondary)
          Text("No transcripts yet")
            .font(Tokens.emptyHistoryLabelFont)
            .foregroundStyle(.secondary)
          Text("Drop audio into the main window")
            .font(Tokens.emptyHistoryHelperFont)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Metrics.historyEmptyHorizontalPadding)
        Spacer()
      } else {
        List(selection: $selectedID) {
          Section {
            ForEach(state.rows) { row in
              historyRow(row)
                .tag(Optional(row.id))
                .contextMenu {
                  Button {
                    onOpen(row.id)
                  } label: {
                    Label("Open", systemImage: "doc.text")
                  }
                  Button {
                    onReveal(row.id)
                  } label: {
                    Label("Reveal in Finder", systemImage: "finder")
                  }
                  Divider()
                  Button(role: .destructive) {
                    onDelete(row.id)
                  } label: {
                    Label("Delete", systemImage: "trash")
                  }
                }
            }
          } header: {
            Text("History")
              .font(Tokens.historySectionFont)
              .foregroundStyle(.secondary)
          }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
      }
    }
  }

  private func historyRow(_ row: HistoryRowState) -> some View {
    VStack(alignment: .leading, spacing: Metrics.tightStackSpacing) {
      Text(row.title)
        .font(Tokens.historyTitleFont)
        .fontWeight(.medium)
        .lineLimit(1)
        .truncationMode(.middle)
      Text(row.relativeDate)
        .font(Tokens.historyDateFont)
        .foregroundStyle(.secondary)
      if !row.tags.isEmpty {
        HStack(spacing: Metrics.tagSpacing) {
          ForEach(row.tags.prefix(Metrics.maxVisibleTags), id: \.self) { tag in
            tagPill(tag)
          }
          if row.tags.count > Metrics.maxVisibleTags {
            tagPill("+\(row.tags.count - Metrics.maxVisibleTags)", fixed: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Metrics.tagTopPadding)
        .clipped()
      }
    }
    .padding(.vertical, Metrics.historyRowVerticalPadding)
  }

  // Tag pills truncate to fit the sidebar width; the small "+N" pill stays
  // fixed so it is never the one that shrinks.
  private func tagPill(_ tag: String, fixed: Bool = false) -> some View {
    Text(tag)
      .font(Tokens.historyTagFont)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .truncationMode(.tail)
      .fixedSize(horizontal: fixed, vertical: false)
      .padding(.horizontal, Metrics.tagPillH)
      .padding(.vertical, Metrics.tagPillV)
      .background(Tokens.tagPillFill, in: Capsule())
  }
}

#if DEBUG
#Preview("empty") {
  HistoryPaneView(
    state: PreviewMocks.historyEmpty,
    selectedID: .constant(nil),
    onNewTranscription: {},
    onOpen: { _ in },
    onReveal: { _ in },
    onDelete: { _ in }
  )
  .frame(width: 260, height: 480)
}

#Preview("populated") {
  HistoryPaneView(
    state: PreviewMocks.historyRowsFew,
    selectedID: .constant(nil),
    onNewTranscription: {},
    onOpen: { _ in },
    onReveal: { _ in },
    onDelete: { _ in }
  )
  .frame(width: 260, height: 480)
}

#Preview("running") {
  HistoryPaneView(
    state: PreviewMocks.historyRowsRunning,
    selectedID: .constant(nil),
    onNewTranscription: {},
    onOpen: { _ in },
    onReveal: { _ in },
    onDelete: { _ in }
  )
  .frame(width: 260, height: 480)
}
#endif
