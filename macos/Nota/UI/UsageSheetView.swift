import SwiftUI

// MARK: - Usage sheet view model

/// Totals + footnotes for the Usage sheet, mirroring `nota usage` semantics
/// exactly (the macOS app fetches the same rows the CLI aggregates):
/// - headline = Σ costUSD, `~` prefix when any row is estimated, `+` suffix
///   when rows with a cost note exist (the total is a floor, not the bill);
/// - "N runs not in total (…)" for cost-note rows (OpenRouter / CLI engines);
/// - "N runs have unknown cost" for rows Nota stores no price for.
struct UsageSheetViewModel: Equatable {
  let headlineCost: String
  /// "N runs not in total (OpenRouter refer to dashboard)" — rows whose price
  /// lives on the provider's dashboard.
  let notInTotalNote: String?
  /// "N runs have unknown cost" — gaps in Nota's own pricing data.
  let unknownCostNote: String?
  let rows: [ModelUsageRow]

  init(rows: [ModelUsageRow]) {
    let anyEstimated = rows.contains(where: \.hasEstimated)
    let totalCost = rows.reduce(0) { $0 + $1.costUSD }
    let notedRows = rows.filter { $0.costNote != nil }
    let notedCount = notedRows.reduce(0) { $0 + $1.runs }
    let unknownCount = rows
      .filter { $0.hasUnknown && $0.costNote == nil }
      .reduce(0) { $0 + $1.runs }
    let notes = Array(Set(notedRows.compactMap(\.costNote))).sorted()

    headlineCost =
      "\(anyEstimated ? "~" : "")$\(String(format: "%.2f", totalCost))"
      + (notedCount > 0 ? "+" : "")
    notInTotalNote = notedCount > 0
      ? "\(notedCount) run\(notedCount == 1 ? "" : "s") not in total (\(notes.joined(separator: ", ")))"
      : nil
    unknownCostNote = unknownCount > 0
      ? "\(unknownCount) run\(unknownCount == 1 ? "" : "s") have unknown cost"
      : nil
    self.rows = rows.sorted { $0.costUSD > $1.costUSD }
  }
}

// MARK: - Usage sheet

/// The stats-strip click-through (XIA-394): spend by window (7d/30d), per-
/// model rows, cost notes instead of figures for OpenRouter/CLI rows, and the
/// "not in total" footnotes. B4 glass presentation; no money renders on home
/// itself — it is one click away.
struct UsageSheetView: View {
  @ObservedObject var usageProvider: UsageStatsProvider
  @AppStorage("usageWindow") private var usageWindow: String = "30d"
  @Environment(\.dismiss) private var dismiss

  private let supportedWindows = ["7d", "30d"]

  var body: some View {
    VStack(alignment: .leading, spacing: CraftTokens.spacing16) {
      header

      if usageProvider.isLoading && usageProvider.summary == nil {
        HStack(spacing: 6) {
          ProgressView()
            .controlSize(.small)
          Text("Loading usage…")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 40)
      } else if let error = usageProvider.error, usageProvider.summary == nil {
        VStack(spacing: 4) {
          Text("Could not load usage stats")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Text(error.localizedDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 40)
      } else {
        let rows = usageProvider.summary?.rows ?? []
        if rows.isEmpty {
          Text("No usage \(usageWindow == "7d" ? "in the last 7 days" : "in the last 30 days") — costs appear after your first transcription")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 40)
        } else {
          loadedContent(viewModel: UsageSheetViewModel(rows: rows))
        }
      }
    }
    .padding(CraftTokens.spacing24)
    .frame(width: 440, height: 480)
    .presentationBackground(.regularMaterial)
    .onAppear {
      // A stored legacy window ("all"/"month") falls back to the picker's
      // range instead of rendering an unselected picker.
      if !supportedWindows.contains(usageWindow) {
        usageWindow = "30d"
      }
      Task { await usageProvider.refresh(window: usageWindow) }
    }
    .onChange(of: usageWindow) { _, newValue in
      Task { await usageProvider.refresh(window: newValue) }
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .center) {
      Text("Usage")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(.primary)

      Spacer()

      Picker("Window", selection: $usageWindow) {
        Text("7d").tag("7d")
        Text("30d").tag("30d")
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 120)

      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Close")
    }
  }

  // MARK: - Loaded content

  private func loadedContent(viewModel: UsageSheetViewModel) -> some View {
    VStack(alignment: .leading, spacing: CraftTokens.spacing12) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(viewModel.headlineCost)
          .font(.system(size: 28, weight: .bold).monospacedDigit())
          .foregroundStyle(.primary)
        Text("total")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(viewModel.rows, id: \.modelId) { row in
            modelRow(row)
          }
        }
      }

      // Footnotes mirror the CLI's stderr notes.
      if let note = viewModel.notInTotalNote {
        Text(note)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if let note = viewModel.unknownCostNote {
        Text(note)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func modelRow(_ row: ModelUsageRow) -> some View {
    HStack(spacing: CraftTokens.spacing8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(row.modelId)
          .font(.system(size: 13, weight: .medium))
          .lineLimit(1)
          .truncationMode(.tail)
        Text("\(row.provider) · \(row.runs) run\(row.runs == 1 ? "" : "s")")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      // `costDisplay`, not a raw format call: a model Nota stores no pricing
      // for renders its note instead of a dollar figure (T5 convention).
      Text(row.costDisplay)
        .font(.callout)
        .fontWeight(.medium)
    }
    .padding(.vertical, 4)
  }
}

#if DEBUG
#Preview("loaded") {
  UsageSheetView(
    usageProvider: UsageStatsProvider(
      projectDirectory: URL(fileURLWithPath: "/Users/xiafawu/Developer/Nota")
    )
  )
}
#endif
