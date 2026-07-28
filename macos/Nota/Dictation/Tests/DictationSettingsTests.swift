import XCTest

@testable import Nota

/// Spec §5 P4 oracle: settings round-trip through the Swift-only store, and
/// polish failure surfaces as a typed error the controller can fall back on.
final class DictationSettingsStoreTests: XCTestCase {
  override func tearDown() {
    DictationSettingsStore.reset()
    super.tearDown()
  }

  func testLoadReturnsDefaultsWhenUnset() {
    DictationSettingsStore.reset()
    XCTAssertEqual(DictationSettingsStore.load(), DictationSettings())
  }

  func testRoundTripPersistsAllFields() {
    var settings = DictationSettings()
    settings.engine = .apple
    settings.trigger = TriggerKey(kind: .keyCode, keyCode: 0x31)
    settings.activation = .toggle
    settings.polishEnabled = true
    settings.polishModelID = "deepseek-v4-flash"
    settings.showHUD = false

    DictationSettingsStore.save(settings)
    XCTAssertEqual(DictationSettingsStore.load(), settings)
  }

  func testNamespacedPolishModelRoundTrips() {
    // A namespaced id is an ordinary model id (ADR 0002) — nothing on the
    // settings path may split it, normalize it, or store a provider beside it.
    var settings = DictationSettingsStore.load()
    settings.polishEnabled = true
    settings.polishModelID = "openrouter/anthropic/claude-sonnet-5"

    DictationSettingsStore.save(settings)
    let loaded = DictationSettingsStore.load()
    XCTAssertEqual(loaded.polishModelID, "openrouter/anthropic/claude-sonnet-5")

    // And it still resolves through the registry to a usable entry, with the
    // provider's own slug on the wire.
    let entry = ModelRegistry.model(id: loaded.polishModelID ?? "")
    XCTAssertEqual(entry?.provider, .openrouter)
    XCTAssertEqual(entry?.execution, .http)
    XCTAssertEqual(entry?.wireID, "anthropic/claude-sonnet-5")
  }

  func testShowHUDRoundTrip() {
    // Default is true
    XCTAssertEqual(DictationSettings().showHUD, true)
    XCTAssertEqual(DictationSettingsStore.load().showHUD, true)

    // False -> save -> load
    var settings = DictationSettingsStore.load()
    settings.showHUD = false
    DictationSettingsStore.save(settings)
    XCTAssertEqual(DictationSettingsStore.load().showHUD, false)

    // True -> save -> load
    settings.showHUD = true
    DictationSettingsStore.save(settings)
    XCTAssertEqual(DictationSettingsStore.load().showHUD, true)
  }

  func testResetRevertsToDefaults() {
    var settings = DictationSettings()
    settings.activation = .toggle
    DictationSettingsStore.save(settings)

    DictationSettingsStore.reset()
    XCTAssertEqual(DictationSettingsStore.load(), DictationSettings())
  }

  func testCorruptPayloadFallsBackToDefaults() {
    UserDefaults.standard.set(
      Data("not json".utf8),
      forKey: "com.xiafawu.nota.dictationSettings"
    )
    XCTAssertEqual(DictationSettingsStore.load(), DictationSettings())
  }
}

final class PolishClientErrorTests: XCTestCase {
  func testUnknownModelThrowsInvalidModel() async {
    do {
      _ = try await PolishClient.polish("hello", modelID: "not-a-real-model")
      XCTFail("expected PolishError.invalidModel")
    } catch let error as PolishError {
      guard case .invalidModel = error else {
        return XCTFail("expected .invalidModel, got \(error)")
      }
    } catch {
      XCTFail("expected PolishError, got \(error)")
    }
  }

  func testTranscriptionModelRejectedForPolish() async {
    // `universal` exists in the registry but is a transcription model; polish
    // must reject it up front (never reach the network).
    do {
      _ = try await PolishClient.polish("hello", modelID: "universal")
      XCTFail("expected PolishError.invalidModel")
    } catch let error as PolishError {
      guard case .invalidModel = error else {
        return XCTFail("expected .invalidModel, got \(error)")
      }
    } catch {
      XCTFail("expected PolishError, got \(error)")
    }
  }
}
