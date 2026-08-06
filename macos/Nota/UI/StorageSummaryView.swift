import SwiftUI

/// The store's size, in the Usage sheet (XIA-436).
///
/// It belongs next to the money for the same reason the money is one click off
/// home: these are the two costs of using Nota, and neither should ambush the
/// owner. The figure IS the retention policy — Nota never reclaims a byte on
/// its own, so the deal is only fair if the number is always visible and
/// always actionable, which is what the closing line says out loud.
///
/// Every figure here is decoded from `nota history storage --json`. Nothing on
/// this view recomputes a total, so the sheet and the terminal cannot disagree.
struct StorageSummaryView: View {
  let summary: StoredStorageSummary

  private var oldestText: String? {
    guard
      let raw = summary.oldestCreatedAt,
      let date = ISO8601DateFormatter.notaRecord.date(from: raw)
        ?? ISO8601DateFormatter().date(from: raw)
    else {
      return nil
    }
    return date.formatted(.dateTime.month(.abbreviated).year())
  }

  var body: some View {
    VStack(alignment: .leading, spacing: CraftTokens.spacing8) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text("Storage")
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        Text(StorageFormat.bytes(summary.totalBytes))
          .font(.system(size: 13, weight: .medium).monospacedDigit())
      }

      HStack(spacing: CraftTokens.spacing12) {
        figure("\(summary.count)", "recording\(summary.count == 1 ? "" : "s")")
        figure(StorageFormat.bytes(summary.thisMonthBytes), "this month")
        if let oldestText {
          figure(oldestText, "oldest")
        }
      }

      Text(RecordingDeletionCopy.neverDeletesOnItsOwn)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func figure(_ value: String, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(value)
        .font(.system(size: 12, weight: .medium).monospacedDigit())
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }
}

#if DEBUG
#Preview("storage") {
  StorageSummaryView(
    summary: StoredStorageSummary(
      records: [],
      count: 14,
      totalBytes: 3_221_225_472,
      audioBytes: 3_100_000_000,
      oldestCreatedAt: "2025-01-05T10:00:00.000Z",
      thisMonthBytes: 402_653_184
    )
  )
  .padding()
  .frame(width: 400)
}
#endif
