import SwiftUI

struct SettingsView: View {
  @ObservedObject var model: NotaModel

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $model.identifySpeakers) {
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
