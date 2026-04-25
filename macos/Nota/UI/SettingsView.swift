import SwiftUI

struct SettingsView: View {
  @Binding var identifySpeakers: Bool

  var body: some View {
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
      }
    }
    .formStyle(.grouped)
    .frame(width: Metrics.settingsWidth, height: Metrics.settingsHeight)
  }
}

#if DEBUG
#Preview("on") {
  SettingsView(identifySpeakers: .constant(true))
}

#Preview("off") {
  SettingsView(identifySpeakers: .constant(false))
}
#endif
