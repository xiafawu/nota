import SwiftUI

// MARK: - DictationSettingsView

struct DictationSettingsView: View {
  var controller: DictationController?

  @State private var settings: DictationSettings = DictationSettingsStore.load()

  var body: some View {
    Form {
      activationSection
      triggerSection
      engineSection
      polishSection
      hudSection
    }
    .formStyle(.grouped)
    .onChange(of: settings) { _, _ in
      DictationSettingsStore.save(settings)
      controller?.reloadSettings()
    }
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
