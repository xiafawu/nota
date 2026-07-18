import XCTest

@testable import Nota

/// Tests for the dB meter transfer curve (20·log10, −50 dB floor, normalized)
/// with its fast-attack / slow-release envelope.
final class MicCaptureLevelTests: XCTestCase {
  // MARK: - Transfer curve

  func testSilenceStaysAtZero() {
    XCTAssertEqual(MicCapture.meterLevel(rms: 0, previous: 0), 0)
  }

  func testBelowFloorClampsToZero() {
    // −80 dB is well under the −50 dB floor.
    XCTAssertEqual(MicCapture.meterLevel(rms: 0.0001, previous: 0), 0)
  }

  func testFullScaleSteadyStateIsOne() {
    // RMS 1.0 = 0 dB → normalized 1; at steady state the envelope holds it.
    XCTAssertEqual(MicCapture.meterLevel(rms: 1, previous: 1), 1)
  }

  func testConversationalSpeechLandsMidMeter() {
    // RMS 0.1 = −20 dB → (−20 + 50) / 50 = 0.6 normalized. Converge the
    // envelope to steady state and check the curve, not the attack step.
    var level: Float = 0
    for _ in 0..<50 {
      level = MicCapture.meterLevel(rms: 0.1, previous: level)
    }
    XCTAssertEqual(level, 0.6, accuracy: 0.01)
  }

  func testWhisperStillRegisters() {
    // RMS 0.01 = −40 dB → 0.2 normalized: quiet input is visible, not flat.
    var level: Float = 0
    for _ in 0..<50 {
      level = MicCapture.meterLevel(rms: 0.01, previous: level)
    }
    XCTAssertEqual(level, 0.2, accuracy: 0.01)
  }

  // MARK: - Envelope

  func testAttackIsFasterThanRelease() {
    // One step up from 0 toward 0.6 vs one step down from 0.6 toward 0.
    let attackStep = MicCapture.meterLevel(rms: 0.1, previous: 0)
    let releaseStep = 0.6 - MicCapture.meterLevel(rms: 0, previous: 0.6)
    XCTAssertGreaterThan(attackStep, releaseStep)
  }

  func testReleaseDecaysGradually() {
    // A single silent buffer must not drop the meter to zero.
    let level = MicCapture.meterLevel(rms: 0, previous: 0.6)
    XCTAssertGreaterThan(level, 0.4)
    XCTAssertLessThan(level, 0.6)
  }

  func testLevelStaysNormalized() {
    // Even absurdly hot input clamps to 1.
    let level = MicCapture.meterLevel(rms: 10, previous: 1)
    XCTAssertLessThanOrEqual(level, 1)
    XCTAssertGreaterThanOrEqual(MicCapture.meterLevel(rms: 0, previous: 0), 0)
  }
}
