import AppKit
import SwiftUI

struct HistoryPaneView: View {
  let state: HistoryPaneState
  @Binding var selectedID: HistoryEntry.ID?
  let onNewTranscription: () -> Void
  let onOpen: (HistoryEntry.ID) -> Void
  let onReveal: (HistoryEntry.ID) -> Void
  let onDelete: (HistoryEntry.ID) -> Void

  @State private var expandedRows: Set<HistoryEntry.ID> = []

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
        tagSection(row)
      }
    }
    .padding(.vertical, Metrics.historyRowVerticalPadding)
  }

  // Collapsed: first N tags + a right-aligned "+k" button. Expanded: every tag
  // wrapped across lines + a "Less" button. The toggle pills are buttons so a
  // tap expands/collapses without selecting (opening) the row.
  @ViewBuilder
  private func tagSection(_ row: HistoryRowState) -> some View {
    let overflow = row.tags.count - Metrics.maxVisibleTags
    Group {
      if expandedRows.contains(row.id) {
        VStack(alignment: .leading, spacing: Metrics.tagSpacing) {
          FlowLayout(spacing: Metrics.tagSpacing, lineSpacing: Metrics.tagSpacing) {
            ForEach(row.tags, id: \.self) { pillLabel($0) }
          }
          HStack(spacing: 0) {
            Spacer(minLength: 0)
            togglePill("Less", systemImage: "chevron.up") { collapse(row.id) }
          }
        }
      } else {
        HStack(spacing: Metrics.tagSpacing) {
          ForEach(row.tags.prefix(Metrics.maxVisibleTags), id: \.self) { pillLabel($0) }
          if overflow > 0 {
            Spacer(minLength: Metrics.tagSpacing)
            togglePill("+\(overflow)", systemImage: "chevron.down") { expand(row.id) }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, Metrics.tagTopPadding)
  }

  // A plain tag label. No fixed width, so it truncates to fit a collapsed row
  // and reports its full intrinsic size when wrapped by FlowLayout.
  private func pillLabel(_ text: String) -> some View {
    Text(text)
      .font(Tokens.historyTagFont)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .truncationMode(.tail)
      .padding(.horizontal, Metrics.tagPillH)
      .padding(.vertical, Metrics.tagPillV)
      .background(Tokens.tagPillFill, in: Capsule())
  }

  // Expand/collapse toggle: a chevron marks it as a control (vs. a plain tag).
  // Uses .secondary — not .tint — because the sidebar selection highlight is
  // the accent color, and accent text on the accent highlight is illegible.
  private func togglePill(_ text: String, systemImage: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: Metrics.tagToggleIconSpacing) {
        Text(text)
        Image(systemName: systemImage)
          .imageScale(.small)
      }
      .font(Tokens.historyTagFont)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: true, vertical: false)
      .padding(.horizontal, Metrics.tagPillH)
      .padding(.vertical, Metrics.tagPillV)
      .background(Tokens.tagPillFill, in: Capsule())
    }
    .buttonStyle(.plain)
  }

  private func expand(_ id: HistoryEntry.ID) {
    withAnimation(Tokens.animSnap) { _ = expandedRows.insert(id) }
  }

  private func collapse(_ id: HistoryEntry.ID) {
    withAnimation(Tokens.animSnap) { expandedRows.remove(id) }
  }
}

/// Wrapping layout for the expanded tag list: left-to-right, wrapping to a new
/// line when the next pill would exceed the available width.
struct FlowLayout: Layout {
  var spacing: CGFloat = 4
  var lineSpacing: CGFloat = 4

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    var x: CGFloat = 0
    var y: CGFloat = 0
    var lineHeight: CGFloat = 0
    var widestRow: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0, x + size.width > maxWidth {
        widestRow = max(widestRow, x - spacing)
        x = 0
        y += lineHeight + lineSpacing
        lineHeight = 0
      }
      x += size.width + spacing
      lineHeight = max(lineHeight, size.height)
    }
    widestRow = max(widestRow, x - spacing)
    let width = maxWidth.isFinite ? min(widestRow, maxWidth) : widestRow
    return CGSize(width: max(width, 0), height: y + lineHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var lineHeight: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0, x + size.width > bounds.width {
        x = 0
        y += lineHeight + lineSpacing
        lineHeight = 0
      }
      subview.place(
        at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
        anchor: .topLeading,
        proposal: ProposedViewSize(size)
      )
      x += size.width + spacing
      lineHeight = max(lineHeight, size.height)
    }
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
