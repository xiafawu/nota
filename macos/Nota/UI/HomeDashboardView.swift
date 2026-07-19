import SwiftUI

// MARK: - History presentation helpers

/// Recency bands and date labels for the Recent list: relative dates flatten
/// ordering past a few days ("1mo ago" × 22), so rows outside today get short
/// absolute dates and the list gains band headers.
enum HistoryPresentation {
  enum Band: Int, CaseIterable {
    case today, thisWeek, thisMonth, earlier

    var title: String {
      switch self {
      case .today: return "Today"
      case .thisWeek: return "This Week"
      case .thisMonth: return "This Month"
      case .earlier: return "Earlier"
      }
    }
  }

  static func band(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> Band {
    if calendar.isDate(date, inSameDayAs: now) { return .today }
    if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now), date > weekAgo {
      return .thisWeek
    }
    if let monthAgo = calendar.date(byAdding: .month, value: -1, to: now), date > monthAgo {
      return .thisMonth
    }
    return .earlier
  }

  /// Short absolute date ("Jun 12", with the year when it differs from now).
  static func shortDate(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    let formatter = DateFormatter()
    let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
    formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMM d" : "MMM d yyyy")
    return formatter.string(from: date)
  }

  /// Source-filename fallback for the generic "Transcript" title: strips the
  /// `.summary` suffix and the trailing `-YYYYMMDD-HHMMSS` stamp, mirroring
  /// how outputs are named (`<base>-<timestamp>.summary.md`).
  static func fallbackTitle(for url: URL) -> String? {
    var base = url.deletingPathExtension().lastPathComponent
    if base.hasSuffix(".summary") {
      base = String(base.dropLast(".summary".count))
    }
    for _ in 0..<2 {
      guard
        let dash = base.range(of: "-", options: .backwards),
        !base[dash.upperBound...].isEmpty,
        base[dash.upperBound...].allSatisfy(\.isNumber)
      else {
        break
      }
      base = String(base[..<dash.lowerBound])
    }
    return base.isEmpty ? nil : base
  }
}

// MARK: - Home dashboard

/// Single-pane home shown when no document is open: preflight health, cost
/// card, and recent transcription history.
struct HomeDashboardView: View {
  @ObservedObject var model: NotaModel
  @ObservedObject var usageProvider: UsageStatsProvider
  @AppStorage("usageWindow") private var usageWindow: String = "30d"

  @State private var historyExpanded = false
  @State private var costCardExpanded = false

  private let maxCollapsedHistory = 6

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        healthSection
        costSection
        recentSection
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .onAppear {
      // On-demand generation appends usage to the record while the dashboard
      // is hidden; drop the cache so the new spend shows in the cost card.
      if model.consumeUsageStatsStale() {
        usageProvider.invalidateCache()
      }
      Task { await usageProvider.refresh(window: usageWindow) }
    }
    .onChange(of: usageWindow) { _, newValue in
      Task { await usageProvider.refresh(window: newValue) }
    }
  }

  // MARK: - Health

  @ViewBuilder
  private var healthSection: some View {
    PreflightHomeView(
      result: model.preflight,
      isChecking: model.isCheckingPreflight,
      onRefresh: { model.runPreflight(refresh: true) },
      embedded: true
    )
  }

  // MARK: - Cost card

  @ViewBuilder
  private var costSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center) {
        Label("Cost", systemImage: "dollarsign.circle")
          .font(.headline)
          .foregroundColor(.primary)

        Spacer()

        Picker("Window", selection: $usageWindow) {
          Text("30d").tag("30d")
          Text("All").tag("all")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 120)
      }

      // Loading and error states keep the same card shell (and a fixed height)
      // as the loaded card, so the section never jumps on refresh.
      if usageProvider.isLoading {
        costCardShell {
          ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .center)
        }
      } else if let error = usageProvider.error {
        costCardShell {
          VStack(spacing: 4) {
            Text("Could not load usage stats")
              .font(.subheadline)
              .foregroundColor(.secondary)
            Text(error.localizedDescription)
              .font(.caption)
              .foregroundColor(.secondary)
              .lineLimit(2)
          }
          .frame(maxWidth: .infinity, alignment: .center)
        }
      } else {
        CostCardView(
          rows: usageProvider.summary?.rows ?? [],
          window: usageWindow,
          expanded: $costCardExpanded
        )
      }
    }
  }

  /// Fixed-height skeleton shell matching the loaded cost card's surface.
  private func costCardShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
      .frame(maxWidth: .infinity, minHeight: Metrics.costSkeletonHeight)
      .padding(Metrics.cardPadding)
      .liquidGlass(.regular, in: RoundedRectangle(cornerRadius: Metrics.cardCornerRadius))
  }

  // MARK: - Recent history

  @ViewBuilder
  private var recentSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Recent", systemImage: "clock")
        .font(.headline)
        .foregroundColor(.primary)

      if model.history.isEmpty {
        Text("No transcripts yet")
          .font(.subheadline)
          .foregroundColor(.secondary)
          .padding(.vertical, 8)
      } else {
        let displayItems = historyExpanded
          ? Array(model.history.prefix(50))
          : Array(model.history.prefix(maxCollapsedHistory))
        let now = Date()
        let groups = groupedByBand(displayItems, now: now)

        ForEach(groups, id: \.band) { group in
          Text(group.band.title)
            .font(Tokens.historySectionFont)
            .foregroundColor(.secondary)
            .padding(.top, group.band == groups.first?.band ? 0 : 8)

          ForEach(group.entries) { entry in
            Button {
              model.openHistory(entry)
            } label: {
              HistoryDashboardRow(
                entry: entry,
                now: now,
                showsTranscriptPill: showsTranscriptPill(recordStatus: model.recordStatus(for: entry))
              )
            }
            .buttonStyle(HistoryRowButtonStyle())
            .disabled(model.isRunning)
            .contextMenu {
              Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
              }
              Divider()
              Button("Delete") {
                model.deleteHistory(entry)
              }
            }
          }
        }

        if model.history.count > maxCollapsedHistory && !historyExpanded {
          Button {
            withAnimation(.easeInOut(duration: 0.2)) { historyExpanded = true }
          } label: {
            HStack(spacing: 4) {
              Text("Show all (\(model.history.count))")
                .font(.subheadline)
              Image(systemName: "chevron.down")
                .font(.caption)
            }
          }
          .buttonStyle(.plain)
          .foregroundColor(.accentColor)
        }

        if historyExpanded && model.history.count > maxCollapsedHistory {
          Button {
            withAnimation(.easeInOut(duration: 0.2)) { historyExpanded = false }
          } label: {
            HStack(spacing: 4) {
              Text("Show less")
                .font(.subheadline)
              Image(systemName: "chevron.up")
                .font(.caption)
            }
          }
          .buttonStyle(.plain)
          .foregroundColor(.accentColor)
        }
      }
    }
  }

  /// Group already-sorted (newest-first) entries into contiguous recency bands.
  private func groupedByBand(
    _ entries: [HistoryEntry],
    now: Date
  ) -> [(band: HistoryPresentation.Band, entries: [HistoryEntry])] {
    var groups: [(band: HistoryPresentation.Band, entries: [HistoryEntry])] = []
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
}

// MARK: - Cost card

private struct CostCardView: View {
  let rows: [ModelUsageRow]
  let window: String
  @Binding var expanded: Bool

  private var viewModel: CostCardViewModel {
    CostCardViewModel(rows: rows, window: window)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Headline
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(viewModel.headlineCost)
          .font(.system(size: 28, weight: .bold))
          .foregroundColor(.primary)

        if viewModel.hasEstimated {
          Text("estimated")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }

      // Unknown footnote
      if let note = viewModel.unknownNote {
        Text("\(note)")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      // Top models (divider only when rows follow — an empty card otherwise
      // draws an orphan hairline under the headline)
      if !viewModel.topModels.isEmpty {
        Divider()
          .padding(.vertical, 4)

        ForEach(viewModel.topModels, id: \.modelId) { row in
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(row.modelId)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(1)
              Text("\(row.runs) run\(row.runs == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            Text(CostCardViewModel.formatUSD(row.costUSD))
              .font(.callout)
              .fontWeight(.medium)
          }
        }
      }

      // Full table (expanded)
      if expanded && viewModel.totalModelCount > 5 {
        Divider()
          .padding(.vertical, 4)

        expandedTable
      }

      // See all / Less toggle
      if viewModel.totalModelCount > 5 {
        Button {
          withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        } label: {
          HStack(spacing: 4) {
            Text(expanded ? "Less" : "See all (\(viewModel.totalModelCount))")
              .font(.subheadline)
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
              .font(.caption)
          }
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
      }

      // Empty state
      if rows.isEmpty && window == "30d" {
        Text("No usage in the last 30 days — costs appear after your first transcription")
          .font(.caption)
          .foregroundColor(.secondary)
          .padding(.vertical, 4)
      } else if rows.isEmpty {
        Text("No usage yet — costs appear after your first transcription")
          .font(.caption)
          .foregroundColor(.secondary)
          .padding(.vertical, 4)
      }
    }
    .padding(Metrics.cardPadding)
    .liquidGlass(.regular, in: RoundedRectangle(cornerRadius: Metrics.cardCornerRadius))
  }

  @ViewBuilder
  private var expandedTable: some View {
    // Grid instead of fixed column widths: the model column flexes with the
    // card while the numeric columns hug their content.
    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
      GridRow {
        Text("Model")
          .frame(maxWidth: .infinity, alignment: .leading)
        Text("Provider")
          .gridColumnAlignment(.leading)
        Text("Runs")
          .gridColumnAlignment(.trailing)
        Text("Calls")
          .gridColumnAlignment(.trailing)
        Text("Tokens In")
          .gridColumnAlignment(.trailing)
        Text("Tokens Out")
          .gridColumnAlignment(.trailing)
        Text("Cost")
          .gridColumnAlignment(.trailing)
      }
      .font(.caption)
      .foregroundColor(.secondary)

      Divider()

      let sorted = rows.sorted { $0.costUSD > $1.costUSD }
      ForEach(sorted, id: \.modelId) { row in
        GridRow {
          Text(row.modelId)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(row.provider)
          Text("\(row.runs)")
          Text("\(row.calls)")
          Text("\(row.tokensIn)")
          Text("\(row.tokensOut)")
          Text(row.hasUnknown && row.costUSD == 0 ? "—" : CostCardViewModel.formatUSD(row.costUSD))
        }
        .font(.caption)
      }
    }
  }
}

// MARK: - History row

private struct HistoryDashboardRow: View {
  let entry: HistoryEntry
  var now: Date = Date()

  /// Subtle badge for transcript-only records; clears when the record
  /// completes (driven by the history record's status, not the file).
  var showsTranscriptPill: Bool = false

  /// Untitled runs fall back to the source filename instead of the generic
  /// "Transcript" heading (the date line below carries the rest).
  private var displayTitle: String {
    guard entry.title == "Transcript" else { return entry.title }
    return HistoryPresentation.fallbackTitle(for: entry.url) ?? entry.title
  }

  private var dateText: String {
    if HistoryPresentation.band(for: entry.modifiedAt, now: now) == .today {
      return entry.relativeDate
    }
    return HistoryPresentation.shortDate(for: entry.modifiedAt, now: now)
  }

  var body: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(displayTitle)
          .font(.callout)
          .fontWeight(.medium)
          .lineLimit(1)
          .truncationMode(.tail)

        Text(dateText)
          .font(.caption2)
          .foregroundColor(.secondary)
      }

      Spacer()

      if showsTranscriptPill {
        Text("transcript")
          .font(.caption2)
          .foregroundColor(.secondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .overlay(
            Capsule().strokeBorder(.secondary.opacity(0.35), lineWidth: 1)
          )
      }

      if !entry.tags.isEmpty {
        HStack(spacing: 4) {
          ForEach(entry.tags.prefix(3), id: \.self) { tag in
            Text(tag)
              .font(.caption2)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(.secondary.opacity(0.12), in: Capsule())
          }
          if entry.tags.count > 3 {
            Text("+\(entry.tags.count - 3)")
              .font(.caption2)
              .foregroundColor(.secondary)
          }
        }
      }
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(RoundedRectangle(cornerRadius: Metrics.rowCornerRadius))
    .liquidGlass(.regular, in: RoundedRectangle(cornerRadius: Metrics.rowCornerRadius))
  }
}

/// Row buttons: hover wash + pressed dim over the row's glass surface.
private struct HistoryRowButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    HistoryRowButtonBody(configuration: configuration)
  }

  private struct HistoryRowButtonBody: View {
    let configuration: Configuration
    @State private var isHovered = false

    var body: some View {
      configuration.label
        .overlay(
          RoundedRectangle(cornerRadius: Metrics.rowCornerRadius)
            .fill(Color.primary.opacity(washOpacity))
            .allowsHitTesting(false)
        )
        .onHover { isHovered = $0 }
        .animation(Tokens.animSnap, value: isHovered)
        .animation(Tokens.animSnap, value: configuration.isPressed)
    }

    private var washOpacity: Double {
      if configuration.isPressed { return Tokens.rowPressedWashOpacity }
      if isHovered { return Tokens.rowHoverWashOpacity }
      return 0
    }
  }
}
