import SwiftUI

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

      if usageProvider.isLoading {
        ProgressView()
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.vertical, 24)
      } else if let error = usageProvider.error {
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
        .padding(.vertical, 24)
      } else {
        CostCardView(
          rows: usageProvider.summary?.rows ?? [],
          window: usageWindow,
          expanded: $costCardExpanded
        )
      }
    }
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

        ForEach(displayItems) { entry in
          HistoryDashboardRow(entry: entry)
            .contentShape(Rectangle())
            .onTapGesture {
              guard !model.isRunning else { return }
              model.openHistory(entry)
            }
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

      Divider()
        .padding(.vertical, 4)

      // Top models
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
    .padding(16)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
  }

  @ViewBuilder
  private var expandedTable: some View {
    VStack(spacing: 0) {
      // Header
      HStack {
        Text("Model").frame(width: 120, alignment: .leading)
        Text("Provider").frame(width: 80, alignment: .leading)
        Text("Runs").frame(width: 40, alignment: .trailing)
        Text("Calls").frame(width: 40, alignment: .trailing)
        Text("Tokens In").frame(width: 70, alignment: .trailing)
        Text("Tokens Out").frame(width: 70, alignment: .trailing)
        Text("Cost").frame(width: 70, alignment: .trailing)
      }
      .font(.caption2)
      .foregroundColor(.secondary)
      .padding(.bottom, 4)

      Divider()

      let sorted = rows.sorted { $0.costUSD > $1.costUSD }
      ForEach(sorted, id: \.modelId) { row in
        HStack {
          Text(row.modelId).frame(width: 120, alignment: .leading)
          Text(row.provider).frame(width: 80, alignment: .leading)
          Text("\(row.runs)").frame(width: 40, alignment: .trailing)
          Text("\(row.calls)").frame(width: 40, alignment: .trailing)
          Text("\(row.tokensIn)").frame(width: 70, alignment: .trailing)
          Text("\(row.tokensOut)").frame(width: 70, alignment: .trailing)
          Text(row.hasUnknown && row.costUSD == 0 ? "—" : CostCardViewModel.formatUSD(row.costUSD))
            .frame(width: 70, alignment: .trailing)
        }
        .font(.caption)
        .padding(.vertical, 2)
      }
    }
  }
}

// MARK: - History row

private struct HistoryDashboardRow: View {
  let entry: HistoryEntry

  var body: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.title)
          .font(.callout)
          .fontWeight(.medium)
          .lineLimit(1)
          .truncationMode(.middle)

        Text(entry.relativeDate)
          .font(.caption2)
          .foregroundColor(.secondary)
      }

      Spacer()

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
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
  }
}
