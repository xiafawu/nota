import SwiftUI

struct SettingsView: View {
  @Binding var identifySpeakers: Bool
  @StateObject private var speakers = SpeakersModel()

  var body: some View {
    TabView {
      generalTab
        .tabItem { Label("General", systemImage: "gearshape") }

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
      }
    }
    .formStyle(.grouped)
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
