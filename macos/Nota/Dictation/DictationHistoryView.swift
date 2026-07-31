import SwiftUI

struct DictationHistoryView: View {
  @ObservedObject var controller: DictationController
  @State private var selectedID: UUID?
  @State private var showingClearConfirmation = false

  private var selectedEntry: DictationHistoryEntry? {
    guard let selectedID else { return nil }
    return controller.dictationHistory.first(where: { $0.id == selectedID })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()

      if controller.dictationHistory.isEmpty {
        emptyState
      } else {
        List(selection: $selectedID) {
          ForEach(controller.dictationHistory) { entry in
            historyRow(entry)
              .tag(Optional(entry.id))
              .contextMenu {
                Button {
                  controller.copyDictationHistory(entry.id)
                } label: {
                  Label("Copy Text", systemImage: "doc.on.clipboard")
                }
                Button {
                  controller.retryDictationHistory(entry.id)
                } label: {
                  Label("Insert Again", systemImage: "arrow.clockwise")
                }
                Divider()
                Button(role: .destructive) {
                  controller.deleteDictationHistory(entry.id)
                  if selectedID == entry.id { selectedID = nil }
                } label: {
                  Label("Remove", systemImage: "trash")
                }
              }
          }
        }
        .listStyle(.inset)
      }

      Divider()
      footer
    }
    .frame(minWidth: 560, minHeight: 420)
    .alert("Clear Dictation History?", isPresented: $showingClearConfirmation) {
      Button("Clear History", role: .destructive) {
        controller.clearDictationHistory()
        selectedID = nil
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This removes all saved dictation text from this Mac. Audio is not stored.")
    }
    .onChange(of: controller.dictationHistory) { _, entries in
      if let selectedID, !entries.contains(where: { $0.id == selectedID }) {
        self.selectedID = nil
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Label("Dictation History", systemImage: "clock.arrow.circlepath")
          .font(.title2.weight(.semibold))
        Spacer()
        Button("Clear History", role: .destructive) {
          showingClearConfirmation = true
        }
        .disabled(controller.dictationHistory.isEmpty)
      }

      Text("Stored only on this Mac. Nota keeps the \(controller.dictationHistoryRetentionLimit) most recent dictations and never saves raw audio.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(20)
  }

  private var emptyState: some View {
    VStack(spacing: 10) {
      Spacer()
      Image(systemName: "clock.arrow.circlepath")
        .font(.system(size: 34))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text("No dictations yet")
        .font(.headline)
      Text("Completed dictation stays here if insertion needs to be retried.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Spacer()
    }
    .frame(maxWidth: .infinity)
    .padding(24)
  }

  private func historyRow(_ entry: DictationHistoryEntry) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(entry.text)
          .lineLimit(2)
          .truncationMode(.tail)
        Spacer(minLength: 8)
        Text(entry.status.label)
          .font(.caption.weight(.medium))
          .foregroundStyle(entry.status == .failed ? .orange : .secondary)
      }

      HStack(spacing: 8) {
        Text(entry.completedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
        Text("•")
        Text(entry.targetLabel)
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      if let detail = entry.statusDetail, !detail.isEmpty {
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(.vertical, 7)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(entry.text). \(entry.status.label). \(entry.targetLabel).")
  }

  private var footer: some View {
    HStack(spacing: 10) {
      if let notice = controller.historyNotice {
        Text(notice)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      Button {
        guard let selectedEntry else { return }
        controller.copyDictationHistory(selectedEntry.id)
      } label: {
        Label("Copy Text", systemImage: "doc.on.clipboard")
      }
      .disabled(selectedEntry == nil)

      Button {
        guard let selectedEntry else { return }
        controller.retryDictationHistory(selectedEntry.id)
      } label: {
        Label("Insert Again", systemImage: "arrow.clockwise")
      }
      .disabled(selectedEntry == nil)
    }
    .padding(14)
  }
}

#if DEBUG
#Preview {
  DictationHistoryView(controller: DictationController())
}
#endif
