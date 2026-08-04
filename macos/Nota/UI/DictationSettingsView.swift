import SwiftUI

// MARK: - DictationSettingsView

struct DictationSettingsView: View {
  var controller: DictationController?
  /// Switches the Settings window to the Dictionary tab. Nil in previews.
  var openDictionary: (() -> Void)?

  @State private var settings: DictationSettings = DictationSettingsStore.load()
  /// The glass slider mid-drag; nil when it is not being dragged. See
  /// `hudSection`.
  @State private var glassOpacityDraft: Double?

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
        // Only models that are an HTTP endpoint: polish is a network call per
        // sentence. The filter is on the execution kind, not on the id
        // (ADR 0002) — a future subprocess engine must be excluded by what it
        // *is*, so no catalog refresh can slip one into this picker.
        let summaryModels = ModelRegistry.httpModels(for: .summary)

        Picker("Model", selection: $settings.polishModelID) {
          Text("Default (\(ModelRegistry.defaultModel(for: .summary)))")
            .tag(nil as String?)
          ForEach(summaryModels, id: \.id) { entry in
            Text(entry.label).tag(entry.id as String?)
          }
        }

        Toggle("Use focused app context", isOn: $settings.screenContextEnabled)
          .help("Use a bounded sample from the focused app only for LLM Polish.")

        if settings.screenContextEnabled {
          Toggle(
            "Allow Screen Recording OCR fallback",
            isOn: $settings.screenCaptureFallbackEnabled
          )
          .help("Capture the target app's window once at dictation completion when Accessibility text is insufficient.")
        }
      }
    } header: {
      Text("Polish")
    } footer: {
      VStack(alignment: .leading, spacing: Metrics.tightStackSpacing) {
        footerText("Applies a language model to improve the formatted text before it is inserted.")
        footerText("By default, the provider receives only the formatted text and your custom dictionary terms — never audio or raw recognition data.")
        if settings.screenContextEnabled {
          footerText("Focused app context is read only during a user-initiated dictation and sent only to LLM Polish: the app name, window title, and a bounded text sample from the focused control. It is not used to change raw audio transcription, and it is not saved in history or logs.")
          if settings.screenCaptureFallbackEnabled {
            footerText("If Accessibility text is unavailable or too short, Nota may ask for Screen Recording permission at dictation completion. It captures only the target app window once, OCRs it in memory, sends bounded redacted text, then discards the image and text. If permission or capture is unavailable, dictation continues normally.")
          } else {
            footerText("Accessibility text is preferred. No screenshot or Screen Recording permission is used while this fallback is off.")
          }
        } else {
          footerText("Focused app context is off. Nota does not send app, window, or screen text to the polish provider.")
        }
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
          footerText("The panel takes keyboard focus without bringing Nota to the front, so the app you were dictating into stays where it is. Applying inserts there, not into whatever is frontmost.")
          footerText("Pressing the trigger again while the panel is open adds to it instead of replacing it — keep talking as many times as you like, then apply the whole thing at once. Anything you have already edited by hand is left exactly as you typed it.")
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

      // Not gated on `showHUD` (nor is the slider below): the review card is
      // glass too, and it is the one surface a review session has whether or
      // not the HUD is on. A picker commits once per click, so unlike the
      // slider it binds straight at `settings`.
      Picker("Glass material", selection: $settings.hudGlassMaterial) {
        ForEach(GlassMaterial.allCases, id: \.self) { material in
          Text(material.label).tag(material)
        }
      }
      .pickerStyle(.radioGroup)

      //
      // The drag is held in `glassOpacityDraft` and committed when the owner
      // lets go, rather than binding straight at `settings`. Every other control
      // here changes once per click, and this view saves and calls
      // `reloadSettings()` on every change — which restarts the hotkey event tap.
      // Doing that at slider-drag frame rate would cost the owner keystrokes for
      // a preview they cannot see anyway: neither floating surface is on screen
      // while Settings is.
      Slider(
        value: glassOpacityBinding,
        in: GlassTint.range,
        label: { Text("Glass opacity") },
        minimumValueLabel: { Text("Clear").font(Tokens.settingsCaptionFont) },
        maximumValueLabel: { Text("Solid").font(Tokens.settingsCaptionFont) },
        onEditingChanged: { editing in
          guard !editing, let value = glassOpacityDraft else { return }
          glassOpacityDraft = nil
          settings.hudGlassOpacity = value
        }
      )
    } header: {
      Text("Heads-Up Display")
    } footer: {
      VStack(alignment: .leading, spacing: Metrics.tightStackSpacing) {
        footerText("Shows a floating panel with microphone level and status while dictating.")
        footerText("Frosted diffuses what is behind the pill and the review card; Clear lets it show through sharp. Opacity sets how strongly either is tinted — lower lets more through, higher keeps their white text readable over a bright window.")
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

  /// Reads the drag while there is one and the saved value otherwise, so the
  /// knob follows the pointer without a save behind every frame of it.
  private var glassOpacityBinding: Binding<Double> {
    Binding(
      get: { glassOpacityDraft ?? settings.hudGlassOpacity },
      set: { glassOpacityDraft = $0 }
    )
  }

  private func footerText(_ text: String) -> some View {
    Text(text)
      .font(Tokens.settingsCaptionFont)
      .foregroundStyle(.secondary)
  }
}
