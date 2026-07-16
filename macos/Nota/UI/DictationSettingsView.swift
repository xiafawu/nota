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
      privacySection
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
    } header: {
      Text("Activation")
    } footer: {
      Text(settings.activation == .hold
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

      if settings.trigger.kind == .keyCode {
        HStack {
          TextField("Key Code", value: triggerKeyCodeBinding, format: .number)
            .frame(width: 80)
          Text("Numeric key code (e.g. 49 for Space)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("Trigger Key")
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

      if settings.engine == .assemblyAIRealtime {
        Text("AssemblyAI Realtime requires a valid AssemblyAI API key in Settings → API Keys.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } header: {
      Text("Recognition Engine")
    }
  }

  // MARK: - Polish

  private var polishSection: some View {
    Section {
      Toggle(isOn: $settings.polishEnabled) {
        VStack(alignment: .leading, spacing: Metrics.tightStackSpacing) {
          Text("LLM Polish")
          Text("Apply an LLM to polish the formatted text before injection.")
            .font(Tokens.settingsCaptionFont)
            .foregroundStyle(.secondary)
        }
      }

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
    }
  }

  // MARK: - Privacy

  private var privacySection: some View {
    Section {
      VStack(alignment: .leading, spacing: Metrics.tightStackSpacing) {
        Text("Polish may send the final text to the selected LLM provider for improvement.")
          .font(Tokens.settingsCaptionFont)
          .foregroundStyle(.secondary)
        Text("Local formatting rules always run first and are the offline fallback if polish fails.")
          .font(Tokens.settingsCaptionFont)
          .foregroundStyle(.secondary)
        Text("No audio or raw recognition data is sent to the polish provider — only the formatted text.")
          .font(Tokens.settingsCaptionFont)
          .foregroundStyle(.secondary)
      }
    } header: {
      Text("Privacy")
    }
  }

  // MARK: - HUD

  private var hudSection: some View {
    Section {
      Toggle(isOn: $settings.showHUD) {
        VStack(alignment: .leading, spacing: Metrics.tightStackSpacing) {
          Text("Show Dictation HUD")
          Text("Display a floating pill during dictation showing microphone level and status.")
            .font(Tokens.settingsCaptionFont)
            .foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("Heads-Up Display")
    }
  }
}
