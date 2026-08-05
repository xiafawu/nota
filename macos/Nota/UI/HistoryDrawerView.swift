import SwiftUI

// MARK: - Shared history query helpers

extension HistoryPresentation {
  /// Group already-sorted (newest-first) entries into contiguous recency
  /// bands. Shared by the home recents and the history drawer.
  static func group(
    _ entries: [HistoryEntry],
    now: Date = Date()
  ) -> [(band: Band, entries: [HistoryEntry])] {
    var groups: [(band: Band, entries: [HistoryEntry])] = []
    for entry in entries {
      let band = HistoryPresentation.band(for: entry.modifiedAt, now: now)
      if groups.last?.band == band {
        groups[groups.count - 1].entries.append(entry)
      } else {
        groups.append((band: band, entries: [entry]))
      }
    }
    return groups
  }

  /// Live search predicate over title, tags, and the filename fallback —
  /// case-insensitive. Shared by the home recents search and the drawer.
  static func matches(_ entry: HistoryEntry, query: String) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return true }
    return entry.title.localizedCaseInsensitiveContains(trimmed)
      || entry.tags.contains { $0.localizedCaseInsensitiveContains(trimmed) }
      || (fallbackTitle(for: entry.url)?.localizedCaseInsensitiveContains(trimmed) ?? false)
  }
}

// MARK: - History drawer

/// S3 "Drawer" (XIA-393): a slide-over glass history panel anchored top-right
/// inside the window. Search on top, a Pinned section above the day bands,
/// rows with kind chips + time. Rendered as a plain SwiftUI overlay by the
/// host (ContentView) — never an NSPanel. The host owns dismissal on
/// selection, Escape, and click-outside; this view owns content only.
struct HistoryDrawerView: View {
  @ObservedObject var model: NotaModel
  /// Dictation history for the drawer's Dictation tab (decisions 14-21);
  /// wired through ContentView by the app (lane 0).
  @ObservedObject var dictationController: DictationController
  let onClose: () -> Void

  @State private var searchText = ""

  private static let drawerWidth: CGFloat = 380

  private var filteredEntries: [HistoryEntry] {
    model.history.filter { HistoryPresentation.matches($0, query: searchText) }
  }

  private var pinnedEntries: [HistoryEntry] {
    filteredEntries.filter { model.recordDetail(for: $0)?.pinned == true }
  }

  private var unpinnedEntries: [HistoryEntry] {
    filteredEntries.filter { model.recordDetail(for: $0)?.pinned != true }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      searchField

      if model.history.isEmpty {
        // E3: an explicitly opened drawer is never a blank panel.
        Text("No transcripts yet")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(CraftTokens.spacing16)
          .padding(.top, CraftTokens.spacing8)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 2) {
            if !pinnedEntries.isEmpty {
              sectionHeader("Pinned")
              ForEach(pinnedEntries) { entry in
                row(entry)
              }
            }

            let now = Date()
            let groups = HistoryPresentation.group(unpinnedEntries, now: now)
            ForEach(groups, id: \.band) { group in
              sectionHeader(group.band.title)
              ForEach(group.entries) { entry in
                row(entry)
              }
            }

            if filteredEntries.isEmpty {
              Text("No matches")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(CraftTokens.spacing16)
            }
          }
          .padding(.vertical, CraftTokens.spacing8)
        }
      }
    }
    .frame(width: Self.drawerWidth)
    .frame(maxHeight: .infinity, alignment: .top)
    .craftGlassPanel(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
  }

  // MARK: - Header

  private var header: some View {
    HStack {
      Text("History")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.primary)

      Spacer()

      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Close (Esc)")
    }
    .padding(.horizontal, CraftTokens.spacing16)
    .padding(.top, CraftTokens.spacing16)
    .padding(.bottom, CraftTokens.spacing12)
  }

  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
      TextField("Search history", text: $searchText)
        .textFieldStyle(.plain)
        .font(.system(size: 13))
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .padding(.horizontal, CraftTokens.spacing16)
    .padding(.bottom, CraftTokens.spacing12)
  }

  private func sectionHeader(_ title: String) -> some View {
    Text(title)
      .font(CraftTokens.metadataFont)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, CraftTokens.spacing16)
      .padding(.top, CraftTokens.spacing8)
      .padding(.bottom, 2)
  }

  // MARK: - Row

  private func row(_ entry: HistoryEntry) -> some View {
    HistoryDrawerRow(
      entry: entry,
      detail: model.recordDetail(for: entry),
      isPinned: model.recordDetail(for: entry)?.pinned == true,
      onOpen: {
        model.openHistory(entry)
        onClose()
      },
      onTogglePin: { model.setPinned(!(model.recordDetail(for: entry)?.pinned == true), for: entry) },
      onDelete: {
        model.deleteHistory(entry)
        if model.history.isEmpty { onClose() }
      }
    )
    .disabled(model.isRunning)
  }
}

// MARK: - Drawer row

private struct HistoryDrawerRow: View {
  let entry: HistoryEntry
  let detail: HistoryRecordInfo.HistoryDetail?
  let isPinned: Bool
  let onOpen: () -> Void
  let onTogglePin: () -> Void
  let onDelete: () -> Void

  @State private var isHovered = false

  private var displayTitle: String {
    guard entry.title == "Transcript" else { return entry.title }
    return HistoryPresentation.fallbackTitle(for: entry.url) ?? entry.title
  }

  private var timeText: String {
    if HistoryPresentation.band(for: entry.modifiedAt) == .today {
      return entry.relativeDate
    }
    return HistoryPresentation.shortDate(for: entry.modifiedAt)
  }

  private var kindChip: (text: String, tint: CraftChipTint)? {
    switch entry.kind {
    case .meeting: return ("Meeting", .red)
    case .file: return ("File", .gold)
    case .memo: return ("Memo", .green)
    }
  }

  var body: some View {
    HStack(spacing: CraftTokens.spacing8) {
      Button(action: onOpen) {
        HStack(spacing: CraftTokens.spacing8) {
          VStack(alignment: .leading, spacing: 2) {
            Text(displayTitle)
              .font(.callout)
              .fontWeight(.medium)
              .foregroundStyle(.primary)
              .lineLimit(1)
              .truncationMode(.tail)

            Text(timeText)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }

          Spacer(minLength: 8)

          if let chip = kindChip {
            SoftTintChip(text: chip.text, tint: chip.tint)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      // Hover actions live OUTSIDE the open button so they never double-fire.
      HStack(spacing: 2) {
        Button(action: onTogglePin) {
          Image(systemName: isPinned ? "pin.fill" : "pin")
            .font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
        .help(isPinned ? "Unpin" : "Pin")

        Button(action: onDelete) {
          Image(systemName: "trash")
            .font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Delete")
      }
      .opacity(isHovered || isPinned ? 1 : 0)
      .animation(Tokens.animSnap, value: isHovered)
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Metrics.rowCornerRadius, style: .continuous)
        .fill(Color.primary.opacity(isHovered ? 0.06 : 0))
    )
    .onHover { isHovered = $0 }
    .contentShape(Rectangle())
  }
}
