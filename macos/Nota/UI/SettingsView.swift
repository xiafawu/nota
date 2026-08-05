import SwiftUI

/// Settings tabs and their layout. Width is fixed; height fits each tab's
/// content so sparse tabs don't float in blank space and dense tabs don't
/// scroll inside a too-short window.
private enum SettingsTab: Hashable {
  case general, dictation, dictionary, models, apiKeys, speakers

  static let windowWidth: CGFloat = 720

  var idealHeight: CGFloat {
    switch self {
    case .general: 300
    case .dictation: 600
    case .dictionary: 560
    case .models: 400
    case .apiKeys: 400
    case .speakers: 520
    }
  }
}

struct SettingsView: View {
  @Binding var identifySpeakers: Bool
  @Binding var skipSummary: Bool
  /// Summary-rail dismissal policy (decision 13); the General-tab picker
  /// lands in the summary-rail lane.
  @Binding var summaryDismissalBehavior: SummaryRailDismissalBehavior
  @State private var memoDiarization = NotaSettingsStore.memoDiarizationEnabled
  @AppStorage(AppearanceSetting.defaultsKey) private var appearanceRaw =
    AppearanceSetting.system.rawValue
  @StateObject private var speakers = SpeakersModel()
  @State private var selectedTab: SettingsTab = .general

  /// The git commit this build was stamped with by scripts/deploy-macos-app.sh
  /// (CFBundleVersion). Lets a tester tell a freshly deployed binary from a
  /// stale Spotlight copy at a glance.
  private var buildStamp: String {
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"
  }

  /// The dictation controller, used to reload settings after changes.
  let dictationController: DictationController?

  init(
    identifySpeakers: Binding<Bool>,
    skipSummary: Binding<Bool>,
    summaryDismissalBehavior: Binding<SummaryRailDismissalBehavior>,
    dictationController: DictationController? = nil
  ) {
    self._identifySpeakers = identifySpeakers
    self._skipSummary = skipSummary
    self._summaryDismissalBehavior = summaryDismissalBehavior
    self.dictationController = dictationController
  }

  var body: some View {
    TabView(selection: $selectedTab) {
      generalTab
        .tabItem { Label("General", systemImage: "gearshape") }
        .tag(SettingsTab.general)

      DictationSettingsView(
        controller: dictationController,
        openDictionary: { selectedTab = .dictionary }
      )
      .tabItem { Label("Dictation", systemImage: "mic") }
      .tag(SettingsTab.dictation)

      DictionarySettingsView()
        .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
        .tag(SettingsTab.dictionary)

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
            Text("Auto-recognize voices you've enrolled on every recording. Turn off to skip recognition.")
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
        Toggle(isOn: $memoDiarization) {
          VStack(alignment: .leading, spacing: Metrics.tightStackSpacing) {
            Text("Diarize memo recordings")
            Text("Identify speakers in quick memos (off by default — faster and cheaper).")
              .font(Tokens.settingsCaptionFont)
              .foregroundStyle(.secondary)
          }
        }
        .onChange(of: memoDiarization) { _, newValue in
          NotaSettingsStore.memoDiarizationEnabled = newValue
        }
        // Decision 13: one switch governs every dismissal of the summary rail
        // with unsaved edits — click-outside, Escape, Close, record switch,
        // and phase leave. "Save it" (default) commits the draft and closes;
        // "Ask me" confirms first (save / discard / keep editing).
        Picker(selection: $summaryDismissalBehavior) {
          ForEach(SummaryRailDismissalBehavior.allCases, id: \.self) { behavior in
            Text(behavior.label).tag(behavior)
          }
        } label: {
          VStack(alignment: .leading, spacing: Metrics.tightStackSpacing) {
            Text("Closing the summary with unsaved edits")
            Text("Save it commits the draft and closes; Ask me confirms first.")
              .font(Tokens.settingsCaptionFont)
              .foregroundStyle(.secondary)
          }
        }
        .pickerStyle(.segmented)
        Picker(selection: $appearanceRaw) {
          ForEach(AppearanceSetting.allCases) { setting in
            Text(setting.label).tag(setting.rawValue)
          }
        } label: {
          VStack(alignment: .leading, spacing: Metrics.tightStackSpacing) {
            Text("Appearance")
            Text("System follows macOS; Light and Dark pin every Nota window.")
              .font(Tokens.settingsCaptionFont)
              .foregroundStyle(.secondary)
          }
        }
        .pickerStyle(.segmented)
        .onChange(of: appearanceRaw) { _, newValue in
          (AppearanceSetting(rawValue: newValue) ?? .system).apply()
        }
      } footer: {
        Text("Build \(buildStamp)")
          .font(Tokens.settingsCaptionFont)
          .foregroundStyle(.secondary)
      }
      Section {} footer: {
        Text("Deployed from /Applications/Nota.app — ignore Spotlight duplicates of deleted build products.")
          .font(Tokens.settingsCaptionFont)
          .foregroundStyle(.secondary)
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
        groups: ModelRegistry.pickerGroups(for: ModelRegistry.models(for: .transcription)),
        selection: $transcriptionModel,
        task: .transcription
      )
      // The one picker that may offer a subprocess engine: the app's summary
      // path is `nota-app-run.sh`, i.e. the TS pipeline, which is exactly where
      // ADR 0003 says a CLI engine belongs. Dictation polish — the surface that
      // exclusion is really about — reads `httpModels(for:)` and can never see
      // these, because they are not `ModelEntry` values at all.
      modelSection(
        title: "Summary",
        groups: ModelRegistry.pickerGroups(
          for: catalog.summaryEntries,
          appendingCLIEngines: true
        ),
        selection: $summaryModel,
        task: .summary,
        footer: ModelRegistry.cliEngineFooter
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
      // zombie state against the fresh catalog. Dismissal survives no-op
      // refreshes (fetchedAt bumps even on 304); it resets only when the
      // zombie itself changed.
      summaryModel = NotaSettingsStore.effectiveModel(for: .summary)
      let previousZombie = zombieID
      refreshZombieState()
      if zombieID != previousZombie { zombieDismissed = false }
    }
  }

  /// Recompute the zombie pin from disk + the current catalog (see zombieID).
  private func refreshZombieState() {
    let stored = NotaSettingsStore.rawStoredModel(for: .summary)
    zombieID = ModelCatalogLoader.isZombie(storedID: stored, in: catalog.catalog) ? stored : nil
  }

  @ViewBuilder
  private func modelSection(
    title: String,
    groups: [ModelPickerGroup],
    selection: Binding<String>,
    task: ModelTask,
    footer: String? = nil
  ) -> some View {
    Section {
      Picker(title, selection: selection) {
        ForEach(groups) { group in
          Section(group.title) {
            ForEach(group.items) { item in
              Text(item.label).tag(item.id)
            }
          }
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .onChange(of: selection.wrappedValue) { _, newValue in
        persist(newValue, for: task)
      }
    } header: {
      Text(title)
    } footer: {
      if let footer {
        Text(footer)
          .font(Tokens.settingsCaptionFont)
          .foregroundStyle(.secondary)
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

  private func persist(_ modelID: String, for task: ModelTask) {
    // The picker's onChange also fires for PROGRAMMATIC re-syncs (onAppear and
    // the post-refresh fetchedAt handler assign the effective model). Writing
    // on those would silently overwrite a stored pin — e.g. a retired model's
    // pin replaced by the chain default after a background refresh — or
    // materialize a pin the user never set. A programmatic assignment is, by
    // construction, the current effective model; only a genuine user pick
    // differs from it, so a no-op write is skipped rather than persisted.
    guard modelID != NotaSettingsStore.effectiveModel(for: task) else { return }
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
    // Every provider, asked of the enum rather than of a hand-kept list: a new
    // provider's key row would otherwise show its raw env var as its name.
    ModelProvider.allCases.first { $0.apiKeyEnv == env }?.displayName ?? env
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
  SettingsView(
    identifySpeakers: .constant(true),
    skipSummary: .constant(false),
    summaryDismissalBehavior: .constant(.save)
  )
}

#Preview("off") {
  SettingsView(
    identifySpeakers: .constant(false),
    skipSummary: .constant(false),
    summaryDismissalBehavior: .constant(.save)
  )
}
#endif
