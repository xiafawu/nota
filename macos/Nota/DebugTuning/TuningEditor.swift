#if DEBUG
import SwiftUI

struct TuningEditor: View {
  @ObservedObject private var store = TuningStore.shared
  @ObservedObject private var snapshots = TuningSnapshotStore.shared
  @State private var outcome: WritebackOutcome?
  @State private var newSnapshotName: String = ""

  var body: some View {
    HSplitView {
      controlsPane
        .frame(minWidth: 360, idealWidth: 400, maxWidth: 480)
      previewPane
        .frame(minWidth: 420, idealWidth: 520)
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          applyWriteback()
        } label: {
          Label("Apply", systemImage: "square.and.arrow.down")
        }
        .help("Write current values back into Tokens.swift and Metrics.swift")
      }
      ToolbarItem(placement: .secondaryAction) {
        Button {
          store.resetToDefaults()
        } label: {
          Label("Reset", systemImage: "arrow.uturn.backward")
        }
        .help("Reset all values to compile-time defaults")
      }
    }
    .navigationTitle("UI Tuning")
    .alert(
      outcome?.title ?? "",
      isPresented: Binding(
        get: { outcome != nil },
        set: { if !$0 { outcome = nil } }
      ),
      presenting: outcome
    ) { _ in
      Button("OK", role: .cancel) {}
    } message: { result in
      Text(result.message)
    }
  }

  private func applyWriteback() {
    let service = WritebackService(projectDirectory: WritebackService.defaultProjectDirectory())
    do {
      let updated = try service.apply(store: store)
      if updated.isEmpty {
        outcome = WritebackOutcome(title: "No Changes", message: "Tokens already match the current source.")
      } else {
        let names = updated.map(\.lastPathComponent).joined(separator: "\n")
        outcome = WritebackOutcome(title: "Applied", message: "Updated:\n\(names)\n\nRebuild to see the new defaults take effect.")
      }
    } catch {
      outcome = WritebackOutcome(title: "Apply Failed", message: error.localizedDescription)
    }
  }

  private func saveSnapshot() {
    let trimmed = newSnapshotName.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    do {
      try snapshots.save(name: trimmed, from: store)
      newSnapshotName = ""
    } catch {
      outcome = WritebackOutcome(title: "Save Failed", message: error.localizedDescription)
    }
  }

  private func loadSnapshot(_ name: String) {
    do {
      let data = try snapshots.load(name: name)
      data.apply(to: store)
    } catch {
      outcome = WritebackOutcome(title: "Load Failed", message: error.localizedDescription)
    }
  }

  private func deleteSnapshot(_ name: String) {
    do {
      try snapshots.delete(name: name)
    } catch {
      outcome = WritebackOutcome(title: "Delete Failed", message: error.localizedDescription)
    }
  }

  private var controlsPane: some View {
    Form {
      Section("Snapshots") {
        HStack {
          TextField("Snapshot name", text: $newSnapshotName)
            .textFieldStyle(.roundedBorder)
          Button("Save") {
            saveSnapshot()
          }
          .disabled(newSnapshotName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if snapshots.snapshots.isEmpty {
          Text("No saved snapshots")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          ForEach(snapshots.snapshots, id: \.self) { name in
            HStack(spacing: 8) {
              Text(name)
                .frame(maxWidth: .infinity, alignment: .leading)
              Button("Load") {
                loadSnapshot(name)
              }
              .controlSize(.small)
              Button(role: .destructive) {
                deleteSnapshot(name)
              } label: {
                Image(systemName: "trash")
              }
              .controlSize(.small)
              .buttonStyle(.borderless)
            }
          }
        }
      }
      Section("Toolbar Pill") {
        cgSlider("H Padding", value: $store.statusPillH, range: 0...40)
        cgSlider("V Padding", value: $store.statusPillV, range: 0...20)
        cgSlider("Stack Spacing", value: $store.statusHStackSpacing, range: 0...20)
        dSlider("Tint Opacity", value: $store.toolbarStatusTintOpacity, range: 0...1)
      }
      Section("New Transcription Button") {
        cgSlider("H Padding", value: $store.newButtonH, range: 0...40)
        cgSlider("V Padding", value: $store.newButtonV, range: 0...40)
        cgSlider("Stack Spacing", value: $store.newButtonStackSpacing, range: 0...20)
        cgSlider("Corner Radius", value: $store.primaryActionCornerRadius, range: 0...30)
        dSlider("Tint Opacity", value: $store.primaryActionTintOpacity, range: 0...1)
      }
      Section("Drop Overlay") {
        cgSlider("Corner Radius", value: $store.dropCornerRadius, range: 0...40)
        cgSlider("Target Stroke", value: $store.dropTargetStrokeWidth, range: 0...10)
        cgSlider("Stroke Idle", value: $store.dropStrokeIdle, range: 0...6)
        cgSlider("Stroke Active", value: $store.dropStrokeActive, range: 0...10)
      }
      Section("Empty Main") {
        cgSlider("Spacing", value: $store.emptyMainSpacing, range: 0...60)
        cgSlider("Outer Padding", value: $store.emptyMainOuterPadding, range: 0...100)
        cgSlider("Text Spacing", value: $store.emptyTextSpacing, range: 0...30)
        cgSlider("Subtext H", value: $store.emptySubtextHorizontalPadding, range: 0...60)
      }
    }
    .formStyle(.grouped)
  }

  private func cgSlider(_ label: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
    HStack(spacing: 8) {
      Text(label)
        .frame(width: 120, alignment: .leading)
      Slider(value: value, in: range)
      Text("\(Int(value.wrappedValue))")
        .monospacedDigit()
        .frame(width: 36, alignment: .trailing)
    }
  }

  private func dSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
    HStack(spacing: 8) {
      Text(label)
        .frame(width: 120, alignment: .leading)
      Slider(value: value, in: range)
      Text(String(format: "%.2f", value.wrappedValue))
        .monospacedDigit()
        .frame(width: 44, alignment: .trailing)
    }
  }

  private var previewPane: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        previewSection("Toolbar Pill") {
          HStack(spacing: store.statusHStackSpacing) {
            ProgressView()
              .controlSize(.small)
            Text("Transcribing audio…")
              .font(Tokens.statusFont)
              .lineLimit(1)
          }
          .padding(.horizontal, store.statusPillH)
          .padding(.vertical, store.statusPillV)
          .background(.regularMaterial, in: .capsule)
          .overlay(
            Capsule().strokeBorder(Color.secondary.opacity(store.toolbarStatusTintOpacity), lineWidth: 1)
          )
        }
        previewSection("New Transcription Button") {
          HStack(spacing: store.newButtonStackSpacing) {
            Image(systemName: "square.and.pencil")
            Text("New Transcription")
              .fontWeight(.medium)
            Spacer()
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, store.newButtonH)
          .padding(.vertical, store.newButtonV)
          .background(
            Color.accentColor.opacity(store.primaryActionTintOpacity),
            in: RoundedRectangle(cornerRadius: store.primaryActionCornerRadius)
          )
        }
        previewSection("Drop Overlay") {
          ZStack {
            RoundedRectangle(cornerRadius: store.dropCornerRadius)
              .fill(.thinMaterial)
              .frame(height: 180)
            RoundedRectangle(cornerRadius: store.dropCornerRadius)
              .strokeBorder(Color.accentColor, lineWidth: store.dropTargetStrokeWidth)
              .frame(height: 180)
            Text("Drop Zone")
              .foregroundStyle(.secondary)
          }
        }
        previewSection("Empty Main") {
          VStack(spacing: store.emptyMainSpacing) {
            Image(systemName: "tray.and.arrow.down")
              .font(.system(size: 48, weight: .semibold))
              .foregroundStyle(.primary.opacity(Tokens.emptyIconColorOpacity))
            VStack(spacing: store.emptyTextSpacing) {
              Text("Drop Audio")
                .font(Tokens.emptyMainTitleFont)
                .fontWeight(.bold)
              Text("MP3, M4A, WAV, CAF, QTA, MOV, MP4")
                .font(Tokens.emptyMainPathFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, store.emptySubtextHorizontalPadding)
            }
          }
          .frame(maxWidth: .infinity)
          .padding(store.emptyMainOuterPadding)
          .background(.thinMaterial)
        }
      }
      .padding()
    }
  }

  private func previewSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.headline)
        .foregroundStyle(.secondary)
      content()
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
  }
}

private struct WritebackOutcome: Identifiable {
  let id = UUID()
  let title: String
  let message: String
}

#Preview {
  TuningEditor()
    .frame(width: 880, height: 640)
}
#endif
