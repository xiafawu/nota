import Foundation

// MARK: - DictationSettingsStore

/// Swift-only persistence for `DictationSettings` via `UserDefaults`.
///
/// The CLI settings JSON (`~/.nota/settings.json`) is never touched.
private let defaultsKey = "com.xiafawu.nota.dictationSettings"

enum DictationSettingsStore {
  /// The backing defaults. Under XCTest this is a private, wiped-at-start
  /// suite instead of `.standard`: the store tests round-trip and `reset()`
  /// through this enum, and an unhosted test bundle's `UserDefaults.standard`
  /// reaches the real `com.xiafawu.nota` domain — so every test-gated deploy
  /// used to delete the owner's saved dictation settings, which read as
  /// "Nota forgets my settings on every redeploy". Same trap family as the
  /// single-instance guard's XCTest bypass.
  static let defaults: UserDefaults = {
    let env = ProcessInfo.processInfo.environment
    guard env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil,
          let suite = UserDefaults(suiteName: testSuiteName)
    else {
      return .standard
    }
    suite.removePersistentDomain(forName: testSuiteName)
    return suite
  }()

  private static let testSuiteName = "com.xiafawu.nota.test-suite"

  /// Persisted settings, or the defaults if none exist.
  static func load() -> DictationSettings {
    guard let data = defaults.data(forKey: defaultsKey),
          let settings = try? JSONDecoder().decode(DictationSettings.self, from: data)
    else {
      return DictationSettings()
    }
    return settings
  }

  /// Save settings to UserDefaults.
  static func save(_ settings: DictationSettings) {
    guard let data = try? JSONEncoder().encode(settings) else { return }
    defaults.set(data, forKey: defaultsKey)
  }

  /// Reset to factory defaults.
  static func reset() {
    defaults.removeObject(forKey: defaultsKey)
  }
}
