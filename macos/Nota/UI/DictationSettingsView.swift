import SwiftUI

// MARK: - DictationSettingsView

struct DictationSettingsView: View {
  var controller: DictationController?

  @State private var settings: DictationSettings = DictationSettingsStore.load()
  @StateObject private var dictionary = DictionaryModel()

  var body: some View {
    Form {
      activationSection
      triggerSection
      engineSection
      polishSection
      dictionarySection
      hudSection
    }
    .formStyle(.grouped)
    .onChange(of: settings) { _, _ in
      DictationSettingsStore.save(settings)
      controller?.reloadSettings()
    }
    // The CLI (`nota dictionary …`) and auto-learn write the same file, so the
    // list is re-read whenever this pane comes back into view.
    .onAppear { dictionary.refresh() }
  }

  // MARK: - Activation mode

  private var activationSection: some View {
    Section {
      Picker("Activation", selection: $settings.activation) {
        Text("Hold to dictate").tag(ActivationMode.hold)
        Text("Press to toggle").tag(ActivationMode.toggle)
      }
      .pickerStyle(.radioGroup)
      .labelsHidden()
    } header: {
      Text("Activation")
    } footer: {
      footerText(settings.activation == .hold
        ? "Hold the trigger key while speaking; release to finalize."
        : "Press the trigger key to start; press again to stop."
      )
    }
  }

  // MARK: - Trigger key

  private var triggerSection: some View {
    Section {
      Picker("Trigger Key", selection: $settings.trigger.kind) {
        Text("Fn / Globe").tag(TriggerKey.Kind.fnGlobe)
        Text("Custom Key Code").tag(TriggerKey.Kind.keyCode)
      }
      .labelsHidden()

      if settings.trigger.kind == .keyCode {
        TextField("Key Code", value: triggerKeyCodeBinding, format: .number)
      }
    } header: {
      Text("Trigger Key")
    } footer: {
      if settings.trigger.kind == .keyCode {
        footerText("Numeric key code of the trigger key — for example, 49 for Space.")
      }
    }
  }

  private var triggerKeyCodeBinding: Binding<UInt16> {
    Binding {
      settings.trigger.keyCode ?? 0
    } set: { newValue in
      settings.trigger.keyCode = newValue
    }
  }

  // MARK: - Engine

  private var engineSection: some View {
    Section {
      Picker("Engine", selection: $settings.engine) {
        ForEach(EngineChoice.allCases, id: \.self) { choice in
          Text(choice.label).tag(choice)
        }
      }
      .labelsHidden()
    } header: {
      Text("Recognition Engine")
    } footer: {
      if settings.engine == .assemblyAIRealtime {
        footerText("AssemblyAI Realtime requires an AssemblyAI API key, set in the API Keys tab.")
      }
    }
  }

  // MARK: - Polish

  private var polishSection: some View {
    Section {
      Toggle("LLM Polish", isOn: $settings.polishEnabled)

      if settings.polishEnabled {
        let summaryModels = ModelRegistry.models(for: .summary)

        Picker("Model", selection: $settings.polishModelID) {
          Text("Default (\(ModelRegistry.defaultModel(for: .summary)))")
            .tag(nil as String?)
          ForEach(summaryModels, id: \.id) { entry in
            Text(entry.label).tag(entry.id as String?)
          }
        }
      }
    } header: {
      Text("Polish")
    } footer: {
      VStack(alignment: .leading, spacing: Metrics.tightStackSpacing) {
        footerText("Applies a language model to improve the formatted text before it is inserted.")
        footerText("Only the formatted text is sent to the provider — never audio or raw recognition data.")
        footerText("Local formatting always runs first and is the offline fallback if polish fails.")
      }
    }
  }

  // MARK: - Custom dictionary

  private var dictionarySection: some View {
    Section {
      HStack(spacing: Metrics.statusHStackSpacing) {
        TextField("Term", text: $dictionary.draftTerm)
          .onSubmit { dictionary.addDraft() }
        TextField("Sounds like (optional)", text: $dictionary.draftSpokenForm)
          .onSubmit { dictionary.addDraft() }
        Button("Add") { dictionary.addDraft() }
          .disabled(!dictionary.canAddDraft)
      }

      if let error = dictionary.lastError {
        Text(error)
          .font(Tokens.settingsCaptionFont)
          .foregroundStyle(.red)
      }

      if dictionary.terms.isEmpty {
        Text("No custom terms yet.")
          .font(Tokens.settingsCaptionFont)
          .foregroundStyle(.secondary)
      } else {
        ForEach(dictionary.terms, id: \.term) { term in
          dictionaryRow(term)
        }
      }
    } header: {
      Text("Custom Dictionary")
    } footer: {
      VStack(alignment: .leading, spacing: Metrics.tightStackSpacing) {
        footerText("Terms bias recognition, are substituted into the text, and are given to the polish model as the correct spelling.")
        footerText("Starred terms are kept first when the list is capped at \(ContextHints.maxHints) recognition hints.")
        footerText("Shared with the `nota dictionary` command — both read ~/.nota/dictionary.json.")
      }
    }
  }

  private func dictionaryRow(_ term: DictionaryTerm) -> some View {
    HStack(spacing: Metrics.statusHStackSpacing) {
      Button {
        dictionary.toggleStar(term)
      } label: {
        Image(systemName: term.starred ? "star.fill" : "star")
      }
      .buttonStyle(.borderless)
      .help(term.starred ? "Unstar" : "Star — starred terms survive the hint cap")

      VStack(alignment: .leading, spacing: 0) {
        Text(term.term)
        if !term.spokenForms.isEmpty {
          Text("sounds like: " + term.spokenForms.joined(separator: ", "))
            .font(Tokens.settingsCaptionFont)
            .foregroundStyle(.secondary)
        }
      }

      Spacer(minLength: Metrics.statusHStackSpacing)

      if term.source != .manual {
        Text(term.source.rawValue)
          .font(Tokens.settingsCaptionFont)
          .foregroundStyle(.secondary)
      }

      Button {
        dictionary.remove(term)
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .help("Remove \(term.term)")
    }
  }

  // MARK: - HUD

  private var hudSection: some View {
    Section {
      Toggle("Show Dictation HUD", isOn: $settings.showHUD)
    } header: {
      Text("Heads-Up Display")
    } footer: {
      footerText("Shows a floating pill with microphone level and status while dictating.")
    }
  }

  // MARK: - Helpers

  private func footerText(_ text: String) -> some View {
    Text(text)
      .font(Tokens.settingsCaptionFont)
      .foregroundStyle(.secondary)
  }
}

// MARK: - DictionaryModel

/// View state over `DictionaryStore`. Every mutation writes through to
/// `~/.nota/dictionary.json` and re-reads, so the list on screen is always the
/// file on disk rather than a drifting in-memory copy.
@MainActor
final class DictionaryModel: ObservableObject {
  @Published private(set) var terms: [DictionaryTerm] = []
  @Published var draftTerm: String = ""
  @Published var draftSpokenForm: String = ""
  @Published var lastError: String?

  init() {
    refresh()
  }

  var canAddDraft: Bool {
    !draftTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func refresh() {
    terms = DictionaryStore.load().sorted {
      $0.term.lowercased() < $1.term.lowercased()
    }
  }

  func addDraft() {
    let term = draftTerm.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else { return }
    let spoken = draftSpokenForm.trimmingCharacters(in: .whitespacesAndNewlines)
    perform {
      try DictionaryStore.add(term, spokenForms: spoken.isEmpty ? [] : [spoken])
      self.draftTerm = ""
      self.draftSpokenForm = ""
    }
  }

  func remove(_ term: DictionaryTerm) {
    perform { _ = try DictionaryStore.remove(term.term) }
  }

  func toggleStar(_ term: DictionaryTerm) {
    perform { _ = try DictionaryStore.setStarred(!term.starred, for: term.term) }
  }

  private func perform(_ mutation: () throws -> Void) {
    do {
      try mutation()
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
    refresh()
  }
}
