import SwiftUI

struct SettingsView: View {
  @Binding var identifySpeakers: Bool
  @Binding var skipSummary: Bool
  @StateObject private var speakers = SpeakersModel()

  var body: some View {
    TabView {
      generalTab
        .tabItem { Label("General", systemImage: "gearshape") }

      ModelsSettingsView()
        .tabItem { Label("Models", systemImage: "cpu") }

      ApiKeysSettingsView()
        .tabItem { Label("API Keys", systemImage: "key") }

      SpeakersSettingsView(model: speakers)
        .tabItem { Label("Speakers", systemImage: "person.wave.2") }
    }
    .frame(width: 720, height: 480)
  }

  private var generalTab: some View {
    Form {
      Section {
        Toggle(isOn: $identifySpeakers) {
          VStack(alignment: .leading, spacing: Metrics.tightStackSpacing) {
            Text("Remember speakers")
            Text("Identify recurring voices across recordings.")
              .font(Tokens.settingsCaptionFont)
              .foregroundStyle(.secondary)
          }
        }
        Toggle(isOn: $skipSummary) {
          VStack(alignment: .leading, spacing: Metrics.tightStackSpacing) {
            Text("Transcribe only")
            Text("Skip the LLM summary. Produces a transcript-only output.")
              .font(Tokens.settingsCaptionFont)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - Models

/// Transcription + summary model pickers, grouped by provider. Reads/writes
/// ~/.nota/settings.json (the same schema the CLI uses).
struct ModelsSettingsView: View {
  @State private var transcriptionModel = NotaSettingsStore.effectiveModel(for: .transcription)
  @State private var summaryModel = NotaSettingsStore.effectiveModel(for: .summary)
  @State private var errorMessage: String?

  var body: some View {
    Form {
      modelSection(
        title: "Transcription",
        task: .transcription,
        selection: $transcriptionModel
      )
      modelSection(
        title: "Summary",
        task: .summary,
        selection: $summaryModel
      )

      if let errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
            .font(Tokens.settingsCaptionFont)
        }
      }
    }
    .formStyle(.grouped)
    .onAppear {
      transcriptionModel = NotaSettingsStore.effectiveModel(for: .transcription)
      summaryModel = NotaSettingsStore.effectiveModel(for: .summary)
    }
  }

  private func modelSection(
    title: String,
    task: ModelTask,
    selection: Binding<String>
  ) -> some View {
    Section(title) {
      Picker(title, selection: selection) {
        ForEach(providerGroups(for: task), id: \.provider) { group in
          Section(group.provider.displayName) {
            ForEach(group.models) { model in
              Text(model.label).tag(model.id)
            }
          }
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .onChange(of: selection.wrappedValue) { _, newValue in
        persist(newValue, for: task)
      }
    }
  }

  private struct ProviderGroup { let provider: ModelProvider; let models: [ModelEntry] }

  private func providerGroups(for task: ModelTask) -> [ProviderGroup] {
    let models = ModelRegistry.models(for: task)
    var order: [ModelProvider] = []
    for m in models where !order.contains(m.provider) { order.append(m.provider) }
    return order.map { provider in
      ProviderGroup(provider: provider, models: models.filter { $0.provider == provider })
    }
  }

  private func persist(_ modelID: String, for task: ModelTask) {
    do {
      try NotaSettingsStore.setModel(modelID, for: task)
      errorMessage = nil
    } catch {
      errorMessage = "Could not save settings: \(error.localizedDescription)"
    }
  }
}

// MARK: - API Keys

/// Masked status + paste-to-set for the provider API keys. Setting a key writes
/// ~/.nota/config (dotenv, 0600). Full secrets are never shown.
struct ApiKeysSettingsView: View {
  @State private var statuses: [ApiKeyStatus] = ApiKeyStore.keys.map(ApiKeyStore.status(for:))
  @State private var drafts: [String: String] = [:]
  @State private var errorMessage: String?

  var body: some View {
    Form {
      Section {
        ForEach(statuses, id: \.env) { status in
          keyRow(status)
        }
      } footer: {
        Text("Keys are stored in ~/.nota/config (chmod 600). Environment variables override the file.")
          .font(Tokens.settingsCaptionFont)
          .foregroundStyle(.secondary)
      }

      if let errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
            .font(Tokens.settingsCaptionFont)
        }
      }
    }
    .formStyle(.grouped)
    .onAppear(perform: reload)
  }

  private func keyRow(_ status: ApiKeyStatus) -> some View {
    VStack(alignment: .leading, spacing: Metrics.tightStackSpacing) {
      HStack {
        Text(status.env)
          .font(.callout)
          .fontWeight(.medium)
        Spacer()
        statusBadge(status)
      }
      HStack {
        SecureField(
          "Paste to set",
          text: Binding(
            get: { drafts[status.env] ?? "" },
            set: { drafts[status.env] = $0 }
          )
        )
        .textFieldStyle(.roundedBorder)
        Button("Save") { save(status.env) }
          .disabled((drafts[status.env] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(.vertical, 2)
  }

  @ViewBuilder
  private func statusBadge(_ status: ApiKeyStatus) -> some View {
    switch status.source {
    case .env:
      Text("\(status.masked ?? "") · env")
        .font(Tokens.settingsCaptionFont)
        .foregroundStyle(.secondary)
    case .file:
      Text("\(status.masked ?? "") · config")
        .font(Tokens.settingsCaptionFont)
        .foregroundStyle(.secondary)
    case .absent:
      Text("not set")
        .font(Tokens.settingsCaptionFont)
        .foregroundStyle(.tertiary)
    }
  }

  private func save(_ env: String) {
    let value = drafts[env] ?? ""
    do {
      try ApiKeyStore.setKey(env, value: value)
      drafts[env] = ""
      errorMessage = nil
      reload()
    } catch {
      errorMessage = "Could not save \(env): \(error.localizedDescription)"
    }
  }

  private func reload() {
    statuses = ApiKeyStore.keys.map(ApiKeyStore.status(for:))
  }
}

#if DEBUG
#Preview("on") {
  SettingsView(identifySpeakers: .constant(true), skipSummary: .constant(false))
}

#Preview("off") {
  SettingsView(identifySpeakers: .constant(false), skipSummary: .constant(false))
}
#endif
