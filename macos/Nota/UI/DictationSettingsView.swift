import SwiftUI

// MARK: - DictationSettingsView

struct DictationSettingsView: View {
  var controller: DictationController?
  /// Switches the Settings window to the Dictionary tab. Nil in previews.
  var openDictionary: (() -> Void)?

  @State private var settings: DictationSettings = DictationSettingsStore.load()

  var body: some View {
    Form {
      activationSection
      triggerSection
      engineSection
      polishSection
      deliverySection
      dictionarySection
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
        footerText("Sent to the provider: the formatted text, your custom dictionary terms, and the name and window title of the app you were dictating into. Never audio or raw recognition data.")
        footerText("Local formatting always runs first and is the offline fallback if polish fails.")
      }
    }
  }

  // MARK: - Delivery

  /// One picker, three modes: they are mutually exclusive by construction, so
  /// there is no combination of switches that asks for text to be typed while
  /// speaking *and* held back for review.
  private var deliverySection: some View {
    Section {
      Picker("Delivery", selection: $settings.deliveryMode) {
        ForEach(DeliveryMode.allCases, id: \.self) { mode in
          Text(mode.label).tag(mode)
        }
      }
      .pickerStyle(.radioGroup)
      .labelsHidden()
    } header: {
      Text("Delivery")
    } footer: {
      VStack(alignment: .leading, spacing: Metrics.tightStackSpacing) {
        footerText(settings.deliveryMode.detail)
        switch settings.deliveryMode {
        case .immediate:
          EmptyView()
        case .streaming:
          footerText("Text is only ever added, never rewritten — a sentence the polish model improves late still arrives in the order you said it. If polish fails for a sentence, its local formatting is inserted instead.")
          footerText("Insertion stays in the app that had focus when you started speaking, even if you switch apps mid-sentence.")
          if settings.engine != .apple {
            footerText("Requires the Apple On-Device engine; other engines insert on release as usual.")
          }
        case .review:
          footerText("The panel takes keyboard focus, so Nota comes to the front while you edit. Applying inserts into the app you were dictating into, not whatever is frontmost.")
          footerText("Corrections you make are learned: the term you typed is remembered, and the wrong spelling you replaced becomes one of its spoken forms.")
        }
      }
    }
  }

  // MARK: - Custom dictionary

  /// The dictionary itself lives in its own tab (it grows without bound and
  /// needs the room); this is the pointer to it, kept here because the terms
  /// are a dictation feature and this is where people look for them.
  private var dictionarySection: some View {
    Section {
      Button("Manage Dictionary…") { openDictionary?() }
    } header: {
      Text("Custom Dictionary")
    } footer: {
      VStack(alignment: .leading, spacing: Metrics.tightStackSpacing) {
        footerText("Custom terms live in the Dictionary tab. They bias recognition, are substituted into the text, and are given to the polish model as the correct spelling.")
        footerText("Shared with the `nota dictionary` command — both read ~/.nota/dictionary.json.")
      }
    }
  }

  // MARK: - HUD

  private var hudSection: some View {
    Section {
      Toggle("Show Dictation HUD", isOn: $settings.showHUD)

      if settings.showHUD {
        Picker("Style", selection: $settings.hudStyle) {
          ForEach(HUDStyle.allCases, id: \.self) { style in
            Text(style.label).tag(style)
          }
        }
        .pickerStyle(.radioGroup)
      }
    } header: {
      Text("Heads-Up Display")
    } footer: {
      VStack(alignment: .leading, spacing: Metrics.tightStackSpacing) {
        footerText("Shows a floating panel with microphone level and status while dictating.")
        if settings.showHUD {
          footerText(settings.hudStyle.detail)
          if settings.hudStyle.isAboutLiveText,
            let caveat = HUDStyle.liveTextCaveat(
              mode: settings.deliveryMode, engine: settings.engine
            )
          {
            footerText(caveat)
          }
        }
      }
    }
  }

  // MARK: - Helpers

  private func footerText(_ text: String) -> some View {
    Text(text)
      .font(Tokens.settingsCaptionFont)
      .foregroundStyle(.secondary)
  }
}
