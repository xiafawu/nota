import SwiftUI

/// Settings tabs and their layout. Width is fixed; height fits each tab's
/// content so sparse tabs don't float in blank space and dense tabs don't
/// scroll inside a too-short window.
private enum SettingsTab: Hashable {
  case general, dictation, models, apiKeys, speakers

  static let windowWidth: CGFloat = 720

  var idealHeight: CGFloat {
    switch self {
    case .general: 220
    case .dictation: 580
    case .models: 400
    case .apiKeys: 400
    case .speakers: 520
    }
  }
}

struct SettingsView: View {
  @Binding var identifySpeakers: Bool
  @Binding var skipSummary: Bool
  @StateObject private var speakers = SpeakersModel()
  @State private var selectedTab: SettingsTab = .general

  /// The dictation controller, used to reload settings after changes.
  let dictationController: DictationController?

  init(
    identifySpeakers: Binding<Bool>,
    skipSummary: Binding<Bool>,
    dictationController: DictationController? = nil
  ) {
    self._identifySpeakers = identifySpeakers
    self._skipSummary = skipSummary
    self.dictationController = dictationController
  }

  var body: some View {
    TabView(selection: $selectedTab) {
      generalTab
        .tabItem { Label("General", systemImage: "gearshape") }
        .tag(SettingsTab.general)

      DictationSettingsView(controller: dictationController)
        .tabItem { Label("Dictation", systemImage: "mic") }
        .tag(SettingsTab.dictation)

      ModelsSettingsView()
        .tabItem { Label("Models", systemImage: "cpu") }
        .tag(SettingsTab.models)

      ApiKeysSettingsView()
        .tabItem { Label("API Keys", systemImage: "key") }
        .tag(SettingsTab.apiKeys)

      SpeakersSettingsView(model: speakers)
        .tabItem { Label("Speakers", systemImage: "person.wave.2") }
        .tag(SettingsTab.speakers)
    }
    .frame(width: SettingsTab.windowWidth, height: selectedTab.idealHeight)
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

/// Transcription + summary model pickers, grouped by provider. Transcription
/// entries are the static registry list; summary entries come from the
/// self-updating catalog store (cache → baked snapshot). Reads/writes
/// ~/.nota/settings.json (the same schema the CLI uses).
struct ModelsSettingsView: View {
  @StateObject private var catalog = ModelCatalogModel()
  @State private var transcriptionModel = NotaSettingsStore.effectiveModel(for: .transcription)
  @State private var summaryModel = NotaSettingsStore.effectiveModel(for: .summary)
  /// The stored summary pin when it is absent from the effective catalog
  /// (a retired model the user still has pinned). Recomputed off disk on the
  /// events that can change it, not on every render.
  @State private var zombieID: String?
  @State private var zombieDismissed = false
  @State private var errorMessage: String?

  var body: some View {
    Form {
      modelSection(
        title: "Transcription",
        models: ModelRegistry.models(for: .transcription),
        selection: $transcriptionModel,
        task: .transcription
      )
      modelSection(
        title: "Summary",
        models: catalog.summaryEntries,
        selection: $summaryModel,
        task: .summary
      )

      if let zombie = zombieID, !zombieDismissed {
        zombieBanner(zombie)
      }

      catalogSection

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
      refreshZombieState()
      catalog.refreshIfStale()
    }
    .onChange(of: catalog.catalog.fetchedAt) {
      // A refresh wrote a new cache: re-sync the selection and re-evaluate the
      // zombie state against the fresh catalog.
      summaryModel = NotaSettingsStore.effectiveModel(for: .summary)
      zombieDismissed = false
      refreshZombieState()
    }
  }

  /// Recompute the zombie pin from disk + the current catalog (see zombieID).
  private func refreshZombieState() {
    let stored = NotaSettingsStore.rawStoredModel(for: .summary)
    zombieID = ModelCatalogLoader.isZombie(storedID: stored, in: catalog.catalog) ? stored : nil
  }

  private func modelSection(
    title: String,
    models: [ModelEntry],
    selection: Binding<String>,
    task: ModelTask
  ) -> some View {
    Section(title) {
      Picker(title, selection: selection) {
        ForEach(providerGroups(from: models), id: \.provider) { group in
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

  @ViewBuilder
  private func zombieBanner(_ id: String) -> some View {
    Section {
      HStack(alignment: .top, spacing: Metrics.statusHStackSpacing) {
        Label {
          Text("\(id) is no longer available; runs will use the default.")
            .font(Tokens.settingsCaptionFont)
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .foregroundStyle(.orange)
        Spacer(minLength: Metrics.statusHStackSpacing)
        Button {
          zombieDismissed = true
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("Dismiss")
      }
    }
  }

  private var catalogSection: some View {
    Section {
      HStack(spacing: Metrics.statusHStackSpacing) {
        Text(catalog.footerText)
          .font(Tokens.settingsCaptionFont)
          .foregroundStyle(.secondary)
        Spacer()
        if catalog.isRefreshing {
          ProgressView().controlSize(.small)
        }
        Button("Check for New Models") {
          catalog.refresh(userInitiated: true)
        }
        .controlSize(.small)
        .disabled(catalog.isRefreshing)
      }
      if let message = catalog.refreshMessage, !catalog.isRefreshing {
        Text(message)
          .font(Tokens.settingsCaptionFont)
          .foregroundStyle(.secondary)
      }
    }
  }

  private struct ProviderGroup { let provider: ModelProvider; let models: [ModelEntry] }

  private func providerGroups(from models: [ModelEntry]) -> [ProviderGroup] {
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
      // Picking a valid summary model clears any prior zombie pin.
      if task == .summary { refreshZombieState() }
    } catch {
      errorMessage = "Could not save settings: \(error.localizedDescription)"
    }
  }
}

// MARK: - API Keys

/// Provider-key status rows: masked value + source, with the secure field
/// revealed only on Add/Replace. Setting or removing a key writes
/// ~/.nota/config (dotenv, 0600). Full secrets are never shown.
struct ApiKeysSettingsView: View {
  @State private var statuses: [ApiKeyStatus] = ApiKeyStore.keys.map(ApiKeyStore.status(for:))
  @State private var editingEnv: String?
  @State private var draft = ""
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
        VStack(alignment: .leading, spacing: Metrics.tightStackSpacing) {
          Text(Self.providerName(for: status.env))
            .font(.callout)
            .fontWeight(.medium)
          Text(status.env)
            .font(Tokens.settingsCaptionFont)
            .foregroundStyle(.tertiary)
        }
        Spacer()
        statusBadge(status)
        rowActions(status)
      }
      if editingEnv == status.env {
        HStack {
          SecureField("Paste key", text: $draft)
          Button("Save") { save(status.env) }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
          Button("Cancel") { stopEditing() }
        }
      }
    }
    .padding(.vertical, 2)
  }

  @ViewBuilder
  private func rowActions(_ status: ApiKeyStatus) -> some View {
    if editingEnv != status.env {
      switch status.source {
      case .env:
        EmptyView()
      case .file:
        Button("Replace…") { beginEditing(status.env) }
          .controlSize(.small)
        Button("Remove") { remove(status.env) }
          .controlSize(.small)
      case .absent:
        Button("Add…") { beginEditing(status.env) }
          .controlSize(.small)
      }
    }
  }

  @ViewBuilder
  private func statusBadge(_ status: ApiKeyStatus) -> some View {
    switch status.source {
    case .env:
      Text("\(status.masked ?? "") · env")
        .font(Tokens.settingsCaptionFont)
        .foregroundStyle(.secondary)
        .help("Set by an environment variable; change or remove it in your shell.")
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

  private static func providerName(for env: String) -> String {
    let providers: [ModelProvider] = [.openai, .assemblyai, .gemini, .deepseek]
    return providers.first { $0.apiKeyEnv == env }?.displayName ?? env
  }

  private func beginEditing(_ env: String) {
    editingEnv = env
    draft = ""
  }

  private func stopEditing() {
    editingEnv = nil
    draft = ""
  }

  private func save(_ env: String) {
    do {
      try ApiKeyStore.setKey(env, value: draft)
      stopEditing()
      errorMessage = nil
      reload()
    } catch {
      errorMessage = "Could not save the \(Self.providerName(for: env)) key: \(error.localizedDescription)"
    }
  }

  private func remove(_ env: String) {
    do {
      try ApiKeyStore.setKey(env, value: "")
      errorMessage = nil
      reload()
    } catch {
      errorMessage = "Could not remove the \(Self.providerName(for: env)) key: \(error.localizedDescription)"
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
