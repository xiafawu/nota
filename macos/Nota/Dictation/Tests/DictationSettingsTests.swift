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

    DictationSettingsStore.save(settings)
    XCTAssertEqual(DictationSettingsStore.load(), settings)
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
