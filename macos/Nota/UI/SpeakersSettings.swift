import SwiftUI

struct SpeakerEntry: Identifiable, Hashable {
  var name: String
  var profile: SpeakerProfile
  var id: String { name }
}

@MainActor
final class SpeakersModel: ObservableObject {
  @Published private(set) var entries: [SpeakerEntry] = []
  @Published var selectedID: String?
  @Published var draftName: String = ""
  @Published var statusMessage: String = ""
  @Published var lastError: String?
  @Published private(set) var isBusy: Bool = false

  private let projectDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NOTA_PROJECT_DIR"] ?? "/Users/xiafawu/Developer/Nota")

  init() {
    refresh()
  }

  var selected: SpeakerEntry? {
    guard let selectedID else { return nil }
    return entries.first { $0.id == selectedID }
  }

  var canCommitRename: Bool {
    guard let selected else { return false }
    let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == selected.name { return false }
    return !entries.contains { $0.name == trimmed }
  }

  var mergeCandidates: [SpeakerEntry] {
    guard let selected else { return [] }
    return entries.filter { $0.id != selected.id }
  }

  func refresh() {
    let store = SpeakerProfileStore.load()
    let next = store.speakers
      .map { SpeakerEntry(name: $0.key, profile: $0.value) }
      .sorted { $0.name.lowercased() < $1.name.lowercased() }
    entries = next

    if let selectedID, !next.contains(where: { $0.id == selectedID }) {
      self.selectedID = next.first?.id
    } else if selectedID == nil {
      selectedID = next.first?.id
    }
    syncDraftWithSelection()
  }

  func selectionChanged() {
    syncDraftWithSelection()
    lastError = nil
  }

  func commitRename() {
    guard let selected else { return }
    let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      lastError = "Name cannot be empty."
      return
    }
    if trimmed == selected.name { return }

    do {
      var store = SpeakerProfileStore.load()
      guard let profile = store.speakers[selected.name] else {
        throw SpeakerStoreError.notFound(selected.name)
      }
      if store.speakers[trimmed] != nil {
        throw SpeakerStoreError.nameCollision(trimmed)
      }
      store.speakers.removeValue(forKey: selected.name)
      store.speakers[trimmed] = profile
      try SpeakerProfileStore.write(store)
      statusMessage = "Renamed \"\(selected.name)\" to \"\(trimmed)\"."
      lastError = nil
      selectedID = trimmed
      refresh()
    } catch {
      lastError = error.localizedDescription
    }
  }

  func deleteSelected() {
    guard let selected else { return }
    do {
      var store = SpeakerProfileStore.load()
      guard store.speakers.removeValue(forKey: selected.name) != nil else {
        throw SpeakerStoreError.notFound(selected.name)
      }
      try SpeakerProfileStore.write(store)
      statusMessage = "Deleted \"\(selected.name)\"."
      lastError = nil
      selectedID = nil
      refresh()
    } catch {
      lastError = error.localizedDescription
    }
  }

  func merge(into destination: String) {
    guard let selected else { return }
    guard !destination.isEmpty, destination != selected.name else {
      lastError = SpeakerStoreError.sameName.localizedDescription
      return
    }

    isBusy = true
    lastError = nil
    statusMessage = "Merging \(selected.name) into \(destination)..."
    let src = selected.name
    let projectDir = projectDirectory

    Task.detached(priority: .userInitiated) {
      let result = shellMergeSpeakers(src: src, dst: destination, projectDirectory: projectDir)
      await MainActor.run {
        self.isBusy = false
        switch result {
        case .success:
          self.statusMessage = "Merged \"\(src)\" into \"\(destination)\"."
          self.selectedID = destination
          self.refresh()
        case .failure(let error):
          self.lastError = error.localizedDescription
          self.statusMessage = ""
        }
      }
    }
  }

  private func syncDraftWithSelection() {
    draftName = selected?.name ?? ""
  }
}

// MARK: - View

struct SpeakersSettingsView: View {
  @ObservedObject var model: SpeakersModel
  @State private var showDeleteConfirmation: Bool = false
  @State private var mergeTarget: String = ""

  private static let displayDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()

  private static let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  var body: some View {
    HStack(spacing: 0) {
      sidebar
        .frame(width: 240)
      Divider()
      detail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .onAppear { model.refresh() }
  }

  private var sidebar: some View {
    VStack(spacing: 0) {
      if model.entries.isEmpty {
        Spacer()
        VStack(spacing: 8) {
          Image(systemName: "person.wave.2")
            .font(.system(size: 28))
            .foregroundStyle(.secondary)
          Text("No enrolled speakers")
            .font(.callout)
            .foregroundStyle(.secondary)
          Text("Speakers are remembered when you transcribe with speaker identification turned on.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .help("Voices can also be enrolled from the command line with nota --identify")
        }
        Spacer()
      } else {
        List(selection: Binding(
          get: { model.selectedID },
          set: { newValue in
            model.selectedID = newValue
            model.selectionChanged()
          }
        )) {
          ForEach(model.entries) { entry in
            speakerRow(entry)
              .tag(Optional(entry.id))
          }
        }
        .listStyle(.inset)
      }

      Divider()
      HStack {
        Button {
          model.refresh()
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help("Reload the speaker list")
        Spacer()
      }
      .padding(6)
    }
  }

  private func speakerRow(_ entry: SpeakerEntry) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(entry.name)
        .font(.callout)
        .fontWeight(.medium)
        .lineLimit(1)
        .truncationMode(.middle)
      HStack(spacing: 6) {
        // Show count + first voiceprint's enrolledAt / source for the row
        let count = entry.profile.voiceprints.count
        Text("\(count) voiceprint\(count == 1 ? "" : "s")")
        if let first = entry.profile.voiceprints.first {
          Text("•")
          Text(formatEnrolledAt(first.enrolledAt))
          if !first.source.isEmpty {
            Text("•")
            Text(URL(fileURLWithPath: first.source).lastPathComponent)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 2)
  }

  @ViewBuilder
  private var detail: some View {
    if let selected = model.selected {
      detailForm(for: selected)
    } else {
      VStack(spacing: 12) {
        Image(systemName: "person.crop.circle.badge.questionmark")
          .font(.system(size: 36))
          .foregroundStyle(.secondary)
        Text("Select a speaker")
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func detailForm(for entry: SpeakerEntry) -> some View {
    Form {
      Section("Identity") {
        TextField("Name", text: Binding(
          get: { model.draftName },
          set: { model.draftName = $0 }
        ))
        .onSubmit {
          if model.canCommitRename { model.commitRename() }
        }
        HStack {
          Spacer()
          Button("Rename") {
            model.commitRename()
          }
          .disabled(!model.canCommitRename)
        }
      }

      Section("Profile") {
        // TODO: Add a per-voiceprint list UI (out of scope for V1)
        LabeledContent("Voiceprints") {
          Text("\(entry.profile.voiceprints.count)")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        if let first = entry.profile.voiceprints.first {
          LabeledContent("First Enrolled") {
            Text(formatEnrolledAt(first.enrolledAt))
          }
          DisclosureGroup("Details") {
            LabeledContent("Source") {
              Text(first.source.isEmpty ? "Unknown" : first.source)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            }
            LabeledContent("Embedding") {
              Text("\(first.embedding.count) dimensions")
                .font(.callout)
                .foregroundStyle(.secondary)
            }
          }
        }
      }

      Section("Description") {
        if let desc = entry.profile.description {
          Text(desc.text)
            .font(.callout)
            .foregroundStyle(.secondary)
          if let date = Self.isoFormatter.date(from: desc.updatedAt) {
            Text("Updated \(Self.displayDateFormatter.string(from: date))")
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
        } else {
          Text("No description yet. Generate one from transcript excerpts.")
            .font(.callout)
            .foregroundStyle(.tertiary)
        }
      }

      Section {
        HStack {
          Picker("Merge into", selection: $mergeTarget) {
            Text("Select speaker").tag("")
            ForEach(model.mergeCandidates) { candidate in
              Text(candidate.name).tag(candidate.name)
            }
          }
          .pickerStyle(.menu)

          Button("Merge") {
            model.merge(into: mergeTarget)
            mergeTarget = ""
          }
          .disabled(mergeTarget.isEmpty || model.isBusy)
        }
      } header: {
        Text("Merge")
      } footer: {
        Text("Combines this speaker's voiceprints into the selected speaker, then removes this speaker.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section {
        HStack {
          Spacer()
          Button(role: .destructive) {
            showDeleteConfirmation = true
          } label: {
            Label("Delete Speaker", systemImage: "trash")
          }
        }
      }

      if model.isBusy || !model.statusMessage.isEmpty || model.lastError != nil {
        Section {
          if let lastError = model.lastError {
            Label(lastError, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.red)
              .font(.caption)
          } else if model.isBusy {
            HStack(spacing: 8) {
              ProgressView().controlSize(.small)
              Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          } else if !model.statusMessage.isEmpty {
            Text(model.statusMessage)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .formStyle(.grouped)
    .alert("Delete \(entry.name)?", isPresented: $showDeleteConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) {
        model.deleteSelected()
      }
    } message: {
      Text("This permanently removes \(entry.name)'s voiceprints. It cannot be undone.")
    }
  }

  private func formatEnrolledAt(_ raw: String) -> String {
    if let date = Self.isoFormatter.date(from: raw) {
      return Self.displayDateFormatter.string(from: date)
    }
    let fallback = ISO8601DateFormatter()
    if let date = fallback.date(from: raw) {
      return Self.displayDateFormatter.string(from: date)
    }
    return raw
  }
}
