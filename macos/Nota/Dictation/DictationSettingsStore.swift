import Foundation

// MARK: - DictationSettingsStore

/// Swift-only persistence for `DictationSettings` via `UserDefaults`.
///
/// The CLI settings JSON (`~/.nota/settings.json`) is never touched.
private let defaultsKey = "com.xiafawu.nota.dictationSettings"

enum DictationSettingsStore {
  /// Persisted settings, or the defaults if none exist.
  static func load() -> DictationSettings {
    guard let data = UserDefaults.standard.data(forKey: defaultsKey),
          let settings = try? JSONDecoder().decode(DictationSettings.self, from: data)
    else {
      return DictationSettings()
    }
    return settings
  }

  /// Save settings to UserDefaults.
  static func save(_ settings: DictationSettings) {
    guard let data = try? JSONEncoder().encode(settings) else { return }
    UserDefaults.standard.set(data, forKey: defaultsKey)
  }

  /// Reset to factory defaults.
  static func reset() {
    UserDefaults.standard.removeObject(forKey: defaultsKey)
  }
}
