import AppKit

/// The owner's app-appearance override: System follows macOS, Light/Dark pin
/// `NSApp.appearance` for every window. Stored raw under "notaAppearance";
/// an unknown stored value reads as `.system`, so a payload written by a
/// newer build can never strand the picker or the launch-time apply.
enum AppearanceSetting: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  var id: String { rawValue }

  var label: String {
    switch self {
    case .system: return "System"
    case .light: return "Light"
    case .dark: return "Dark"
    }
  }

  static let defaultsKey = "notaAppearance"

  static var current: AppearanceSetting {
    AppearanceSetting(
      rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? ""
    ) ?? .system
  }

  /// Apply to the whole app. `nil` means follow the system setting. The
  /// dictation HUD and review card force their own dark colorScheme and are
  /// deliberately unaffected — they are designed as single-theme surfaces.
  func apply() {
    switch self {
    case .system: NSApp.appearance = nil
    case .light: NSApp.appearance = NSAppearance(named: .aqua)
    case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
    }
  }
}
