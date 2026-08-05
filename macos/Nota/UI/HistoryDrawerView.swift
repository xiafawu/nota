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

// MARK: - Dictation search (decision 17)

/// Dictation-tab search: a case-insensitive substring over `entry.text`.
/// Transcripts keep `HistoryPresentation.matches`; the two predicates are
/// deliberately separate so each tab's matching stays local and testable.
enum DictationSearch {
  static func matches(_ entry: DictationHistoryEntry, query: String) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return true }
    return entry.text.localizedCaseInsensitiveContains(trimmed)
  }

  /// Match count for the badge on the INACTIVE segment (decision 17) — the
  /// crossing counts the other tab's matches while the query is live.
  static func matchCount(_ entries: [DictationHistoryEntry], query: String) -> Int {
    entries.filter { matches($0, query: query) }.count
  }
}

// MARK: - History drawer

/// S3 "Drawer" (XIA-393): a slide-over glass history panel anchored top-right
/// inside the window, now with a two-segment Transcripts / Dictation switch
/// (decision 14). Rendered as a plain SwiftUI overlay by the host
/// (ContentView) — never an NSPanel. The host owns dismissal on selection,
/// Escape, and click-outside; this view owns content only.
struct HistoryDrawerView: View {
  @ObservedObject var model: NotaModel
  /// Dictation history for the drawer's Dictation tab (decisions 14-21).
  @ObservedObject var dictationController: DictationController
  let onClose: () -> Void

  @State private var searchText = ""
  /// The one dictation row expanded in place (decision 16: one row open at a
  /// time; expansion is the receipt of the copy that happened on click).
  @State private var expandedDictationID: UUID?

  static let drawerWidth: CGFloat = 380

  private var queryIsLive: Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var filteredTranscripts: [HistoryEntry] {
    model.history.filter { HistoryPresentation.matches($0, query: searchText) }
  }

  private var filteredDictations: [DictationHistoryEntry] {
    dictationController.dictationHistory.filter { DictationSearch.matches($0, query: searchText) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      searchField
      tabControl
      metaLine
      content
      if model.historyDrawerTab == .dictation {
        privacyFooter
      }
    }
    .frame(width: Self.drawerWidth)
    .frame(maxHeight: .infinity, alignment: .top)
    .craftGlassPanel(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
    .onChange(of: model.historyDrawerTab) { _, _ in
      expandedDictationID = nil
    }
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

  /// Two-segment Transcripts / Dictation switch (decision 14): bare labels,
  /// no counts on the control. The inactive segment carries the live query's
  /// match count as a small badge (decision 17); the badge disappears when
  /// the query clears.
  private var tabControl: some View {
    HStack(spacing: CraftTokens.spacing8) {
      Picker("", selection: $model.historyDrawerTab) {
        ForEach(HistoryDrawerTab.allCases) { tab in
          Text(tab.title).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      // The badge sits over ONE half of the control at a time, so it is drawn
      // in a half-width container inside an overlay that spans the whole
      // control rather than by flipping the overlay's alignment. Alignment is
      // not an animatable value: flipping it teleported the badge across the
      // picker on every tab switch. A frame's position is animatable, so the
      // badge now slides to the other segment with the selection.
      .overlay {
        GeometryReader { proxy in
          if let count = inactiveTabMatchCount {
            Text("\(count)")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(.white)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(Capsule().fill(Color.accentColor))
              .frame(width: proxy.size.width / 2, alignment: .trailing)
              .padding(.trailing, 10)
              .offset(
                x: model.historyDrawerTab == .transcripts ? proxy.size.width / 2 : 0,
                y: -9
              )
              .transition(.opacity.combined(with: .scale(scale: 0.6)))
          }
        }
        .allowsHitTesting(false)
      }
      .animation(Tokens.animFast, value: model.historyDrawerTab)
      .animation(Tokens.animFast, value: inactiveTabMatchCount)
    }
    .padding(.horizontal, CraftTokens.spacing16)
    .padding(.bottom, CraftTokens.spacing8)
  }

  /// The inactive segment's badge count while a query is live (decision 17):
  /// the badge disappears only when the query clears — a zero is honest.
  private var inactiveTabMatchCount: Int? {
    guard queryIsLive else { return nil }
    switch model.historyDrawerTab {
    case .transcripts: return filteredDictations.count
    case .dictation: return filteredTranscripts.count
    }
  }

  /// Meta line under the switch (decision 15): transcript count on the left,
  /// dictation count with the retention qualifier on the right. Both counts
  /// are always visible; the dictation count is a ceiling, not a total.
  private var metaLine: some View {
    HStack {
      Text("\(model.history.count) transcripts")
      Spacer()
      Text("\(dictationController.dictationHistory.count) dictations · last \(dictationController.dictationHistoryRetentionLimit)")
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
    .padding(.horizontal, CraftTokens.spacing16)
    .padding(.bottom, CraftTokens.spacing8)
  }

  /// Decision 20: the Dictation tab's privacy footer.
  private var privacyFooter: some View {
    Text("Stored on this Mac · audio never saved")
      .font(.caption2)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, CraftTokens.spacing16)
      .padding(.vertical, CraftTokens.spacing8)
  }

  // MARK: - Tab content

  /// The two lists slide in the direction of travel and cross-fade, the way a
  /// segmented control's content moves elsewhere on the platform. Without a
  /// transition the whole list is replaced between frames, which is what read
  /// as the switch being abrupt — the `Picker` itself was always animating its
  /// own selection.
  ///
  /// `.id(tab)` is what makes it a transition at all: a `switch` inside a
  /// `ViewBuilder` produces one view whose contents change, so SwiftUI sees an
  /// update rather than an insertion and removal, and a `.transition` on it
  /// would never fire.
  @ViewBuilder
  private var content: some View {
    Group {
      switch model.historyDrawerTab {
      case .transcripts: transcriptList
      case .dictation: dictationList
      }
    }
    .id(model.historyDrawerTab)
    .transition(
      .asymmetric(
        insertion: .move(edge: model.historyDrawerTab == .dictation ? .trailing : .leading)
          .combined(with: .opacity),
        removal: .opacity
      )
    )
    .animation(Tokens.animFast, value: model.historyDrawerTab)
  }

  private var pinnedEntries: [HistoryEntry] {
    filteredTranscripts.filter { model.recordDetail(for: $0)?.pinned == true }
  }

  private var unpinnedEntries: [HistoryEntry] {
    filteredTranscripts.filter { model.recordDetail(for: $0)?.pinned != true }
  }

  @ViewBuilder
  private var transcriptList: some View {
    if filteredTranscripts.isEmpty {
      if model.history.isEmpty && !queryIsLive {
        emptyState(.noTranscripts)
      } else if queryIsLive, !filteredDictations.isEmpty {
        emptyState(.queryNoMatchOnActive(otherTab: .dictation, otherCount: filteredDictations.count))
      } else if queryIsLive {
        emptyState(.queryNoMatchAnywhere)
      } else {
        // History non-empty but filter empty with no query: unreachable.
        emptyState(.noTranscripts)
      }
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          // Decision 18: the Pinned section is a Transcripts-tab concept;
          // the Dictation tab never renders it.
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
        }
        .padding(.vertical, CraftTokens.spacing8)
      }
    }
  }

  @ViewBuilder
  private var dictationList: some View {
    if filteredDictations.isEmpty {
      if dictationController.dictationHistory.isEmpty && !queryIsLive {
        emptyState(.noDictations)
      } else if queryIsLive, !filteredTranscripts.isEmpty {
        emptyState(.queryNoMatchOnActive(otherTab: .transcripts, otherCount: filteredTranscripts.count))
      } else if queryIsLive {
        emptyState(.queryNoMatchAnywhere)
      } else {
        emptyState(.noDictations)
      }
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(filteredDictations) { entry in
            dictationRow(entry)
          }
        }
        .padding(.vertical, CraftTokens.spacing8)
      }
    }
  }

  // MARK: - Empty states (decision 19)

  private enum DrawerEmptyState {
    /// (a) Never dictated: how to start + the retry promise.
    case noDictations
    /// (b) No transcripts: a route in; the footer names the other tab's count.
    case noTranscripts
    /// (c) Query matched nothing on this tab, but something on the other:
    /// names the query and offers the crossing (the badge computes the count).
    case queryNoMatchOnActive(otherTab: HistoryDrawerTab, otherCount: Int)
    /// (d) Query matched nothing anywhere: names the query and how much was
    /// searched, plus Clear search.
    case queryNoMatchAnywhere
  }

  @ViewBuilder
  private func emptyState(_ kind: DrawerEmptyState) -> some View {
    VStack(alignment: .leading, spacing: CraftTokens.spacing8) {
      switch kind {
      case .noDictations:
        Text("No dictations yet")
          .font(.system(size: 13, weight: .medium))
        Text(dictationStartHint)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
        Text("Completed dictation stays here if insertion needs to be retried.")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      case .noTranscripts:
        Text("No transcripts yet")
          .font(.system(size: 13, weight: .medium))
        Text("Drop an audio file into the window, or share audio to Nota.")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
        Text("\(dictationController.dictationHistory.count) dictations in the Dictation tab")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      case .queryNoMatchOnActive(let otherTab, let otherCount):
        Text("No matches for \"\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))\"")
          .font(.system(size: 13, weight: .medium))
          .lineLimit(2)
        Button {
          model.historyDrawerTab = otherTab
        } label: {
          Text("\(otherCount) matches in \(otherTab.title) →")
            .font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
      case .queryNoMatchAnywhere:
        Text("No matches for \"\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))\"")
          .font(.system(size: 13, weight: .medium))
          .lineLimit(2)
        Text("Not in \(model.history.count) transcripts or \(dictationController.dictationHistory.count) dictations.")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
        Button("Clear search") { searchText = "" }
          .font(.system(size: 12))
          .buttonStyle(.plain)
          .foregroundStyle(Color.accentColor)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(CraftTokens.spacing16)
    .padding(.top, CraftTokens.spacing8)
  }

  /// How to start a dictation, mirroring the popover's instruction (decision
  /// 19a) — trigger- and activation-aware, not a hardcoded shortcut.
  private var dictationStartHint: String {
    let triggerLabel: String
    switch dictationController.settings.trigger.kind {
    case .fnGlobe: triggerLabel = "Fn/Globe"
    case .keyCode: triggerLabel = "your dictation key"
    }
    switch dictationController.settings.activation {
    case .hold: return "Hold \(triggerLabel) and speak to dictate."
    case .toggle: return "Press \(triggerLabel) to dictate."
    }
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

  // MARK: - Transcript row

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

  // MARK: - Dictation row (decisions 16/18/21)

  /// One click expands the row in place to its full text AND copies it — the
  /// expansion is the receipt. One row open at a time. Insert again / Delete
  /// are labelled buttons inside the expanded row; there is no pin icon and
  /// no bulk clear on this tab.
  private func dictationRow(_ entry: DictationHistoryEntry) -> some View {
    let isExpanded = expandedDictationID == entry.id
    return VStack(alignment: .leading, spacing: 6) {
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.text)
          .font(.callout)
          .foregroundStyle(.primary)
          .lineLimit(isExpanded ? nil : 2)
          .truncationMode(.tail)

        if !isExpanded {
          HStack(spacing: 6) {
            Text(entry.completedAt, format: .dateTime.hour().minute())
            Text("·")
            Text(entry.targetLabel)
              .lineLimit(1)
              .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(entry.status.label)
              .font(.caption.weight(.medium))
              .foregroundStyle(entry.status == .failed ? .orange : .secondary)
          }
          .font(.caption2)
          .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .onTapGesture {
        if isExpanded {
          expandedDictationID = nil
        } else {
          expandedDictationID = entry.id
          dictationController.copyDictationHistory(entry.id)
        }
      }
      .accessibilityLabel("\(entry.text). \(entry.status.label). \(entry.targetLabel).")

      if isExpanded {
        Divider()
        HStack(spacing: 8) {
          Text(entry.status.label)
            .font(.caption.weight(.medium))
            .foregroundStyle(entry.status == .failed ? .orange : .secondary)
          Spacer()
          Button("Insert again") {
            dictationController.retryDictationHistory(entry.id)
          }
          .controlSize(.small)
          Button("Delete", role: .destructive) {
            dictationController.deleteDictationHistory(entry.id)
            if expandedDictationID == entry.id { expandedDictationID = nil }
          }
          .controlSize(.small)
        }
      }
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Metrics.rowCornerRadius, style: .continuous)
        .fill(Color.primary.opacity(isExpanded ? 0.06 : 0))
    )
    .contentShape(Rectangle())
    .animation(Tokens.animFast, value: isExpanded)
  }
}

// MARK: - Drawer row (transcripts)

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
