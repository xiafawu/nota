import AppKit
import SwiftUI
import XCTest

@testable import Nota

/// The recording accent's promises, asserted against the pure decisions rather
/// than against a rendered view — the split `HUDPillMetrics` and
/// `HUDPrompterMetrics` already established. The two hosting-view cases at the
/// end are there because "the plate keeps its width" is a claim about layout,
/// and only a layout can answer it.
@MainActor
final class RecordingAccentTests: XCTestCase {
  // MARK: - Reduce Motion: the asymmetry

  /// The meter is information. Under Reduce Motion it keeps moving, because a
  /// frozen meter and a dead microphone look the same.
  func testMeterStillAnimatesUnderReduceMotion() {
    XCTAssertNotNil(RecordingMotion.meterAnimation(reduceMotion: true))
    XCTAssertNotNil(RecordingMotion.meterAnimation(reduceMotion: false))
  }

  /// The ring is decoration. Under Reduce Motion it holds.
  func testRingDoesNotAnimateUnderReduceMotion() {
    XCTAssertNil(RecordingMotion.ringAnimation(reduceMotion: true))
    XCTAssertNotNil(RecordingMotion.ringAnimation(reduceMotion: false))
    XCTAssertFalse(SessionRingMetrics.breathes(reduceMotion: true))
    XCTAssertTrue(SessionRingMetrics.breathes(reduceMotion: false))
  }

  /// The heights themselves are what the microphone is doing, so Reduce Motion
  /// cannot reach them at all — it is not a parameter of `barHeights`, and this
  /// pins the consequence: the meter still *tracks* the level either way.
  func testMeterHeightsTrackTheLevelForEveryVariant() {
    for variant in SessionMeterMetrics.Variant.allCases {
      let quiet = SessionMeterMetrics.barHeights(level: 0.05, variant: variant)
      let loud = SessionMeterMetrics.barHeights(level: 0.9, variant: variant)
      XCTAssertNotEqual(quiet, loud, "\(variant) meter did not respond to the level")
      XCTAssertEqual(quiet.count, variant.barCount)
      XCTAssertEqual(loud.count, variant.barCount)
    }
  }

  /// The ring's two animated values collapse to their resting halves when the
  /// view never asks for the peak — which is exactly what Reduce Motion does.
  func testRingHoldsAtASteadyScaleAndOpacityWhenItDoesNotBreathe() {
    XCTAssertEqual(SessionRingMetrics.scale(atPeak: false), 1)
    XCTAssertEqual(SessionRingMetrics.opacity(atPeak: false), SessionRingMetrics.restOpacity)
    XCTAssertEqual(
      SessionRingMetrics.scale(atPeak: true),
      1 + SessionRingMetrics.scaleAmplitude
    )
  }

  func testRingBreathesAboutThreeAndAHalfPercentOnATwoPointSixSecondCycle() {
    XCTAssertEqual(SessionRingMetrics.scaleAmplitude, 0.035, accuracy: 0.0001)
    XCTAssertEqual(SessionRingMetrics.cycle, 2.6, accuracy: 0.0001)
  }

  // MARK: - Meter sizing

  func testMeterBarsStayWithinTheVariantsBounds() {
    for variant in SessionMeterMetrics.Variant.allCases {
      for level in stride(from: Float(-0.5), through: 1.5, by: 0.1) {
        for height in SessionMeterMetrics.barHeights(level: level, variant: variant) {
          XCTAssertGreaterThanOrEqual(height, variant.minBarHeight)
          XCTAssertLessThanOrEqual(height, variant.maxBarHeight)
        }
      }
    }
  }

  /// A silent room still draws a meter.
  func testSilenceDrawsTheFloorAndNotNothing() {
    for variant in SessionMeterMetrics.Variant.allCases {
      let heights = SessionMeterMetrics.barHeights(level: 0, variant: variant)
      XCTAssertEqual(Set(heights), [variant.minBarHeight])
    }
  }

  func testCompactVariantIsSmallerThanTheTallOne() {
    let tall = SessionMeterMetrics.Variant.tall
    let compact = SessionMeterMetrics.Variant.compact
    XCTAssertLessThan(compact.maxBarHeight, tall.maxBarHeight)
    XCTAssertLessThan(compact.width, tall.width)
  }

  // MARK: - Timer: the step function

  func testElapsedFormStepsExactlyOnceAtTheHour() {
    XCTAssertEqual(SessionTimerMetrics.text(elapsed: 0), "00:00")
    XCTAssertEqual(SessionTimerMetrics.text(elapsed: 3599), "59:59")
    XCTAssertEqual(SessionTimerMetrics.text(elapsed: 3600), "1:00:00")
    XCTAssertEqual(SessionTimerMetrics.form(elapsed: 3599), .minutesSeconds)
    XCTAssertEqual(SessionTimerMetrics.form(elapsed: 3600), .hoursMinutesSeconds)
  }

  func testFiftyEightSteppsToFortyTwoAtTheHour() {
    XCTAssertEqual(SessionTimerMetrics.fontSize(base: 58, elapsed: 3599), 58)
    XCTAssertEqual(SessionTimerMetrics.fontSize(base: 58, elapsed: 3600), 42)
  }

  /// Not a fitted font: the size is a function of the *form* alone, so it takes
  /// exactly two values however long the session runs.
  func testTheSizeTakesExactlyTwoValuesAcrossAWholeDay() {
    let sizes = stride(from: TimeInterval(0), through: 86_400, by: 37)
      .map { SessionTimerMetrics.fontSize(base: 58, elapsed: $0) }
    XCTAssertEqual(Set(sizes), [58, 42])
  }

  /// The reserve is computed from the forms, not from the current elapsed time —
  /// so a session crossing the hour cannot change it.
  func testPlateWidthReservesTheWiderFormAndNeverMoves() {
    let width = SessionTimerMetrics.plateWidth(base: 58)
    XCTAssertGreaterThan(width, 0)
    // The hour form is the wider one at 58/42, which is why the reserve exists.
    XCTAssertGreaterThan(width, Self.renderedWidth(elapsed: 3599, base: 58) - 1)
    XCTAssertGreaterThan(width, Self.renderedWidth(elapsed: 3600, base: 58) - 1)
  }

  func testNegativeAndNonFiniteElapsedReadAsZero() {
    XCTAssertEqual(SessionTimerMetrics.text(elapsed: -12), "00:00")
    XCTAssertEqual(SessionTimerMetrics.text(elapsed: .infinity), "00:00")
    XCTAssertEqual(SessionTimerMetrics.text(elapsed: .nan), "00:00")
  }

  /// A tenth hour is one more glyph, and it must not buy a second step: the
  /// plate already reserves `hh:mm:ss`.
  func testATenthHourNeitherStepsAgainNorOutgrowsThePlate() {
    XCTAssertEqual(SessionTimerMetrics.fontSize(base: 58, elapsed: 36_000), 42)
    XCTAssertEqual(SessionTimerMetrics.text(elapsed: 36_000), "10:00:00")
    XCTAssertEqual(Self.laidOutWidth(elapsed: 36_000, base: 58), Self.laidOutWidth(elapsed: 3599, base: 58))
  }

  // MARK: - Timer: laid out

  /// The acceptance case: 59:59 and 1:00:00 render at different sizes into a
  /// container of identical width.
  func testCrossingTheHourChangesTheSizeAndNotTheWidth() {
    let before = Self.laidOutWidth(elapsed: 3599, base: 58)
    let after = Self.laidOutWidth(elapsed: 3600, base: 58)
    XCTAssertGreaterThan(before, 0, "hosting view produced no layout")
    XCTAssertEqual(before, after, accuracy: 0.5, "the timer plate reflowed at the hour")
    XCTAssertNotEqual(
      SessionTimerMetrics.fontSize(base: 58, elapsed: 3599),
      SessionTimerMetrics.fontSize(base: 58, elapsed: 3600)
    )
  }

  /// Every second of a long session lands in the same box.
  func testThePlateHoldsStillForAWholeSession() {
    let widths = [0, 59, 60, 599, 3599, 3600, 3661, 36_000, 86_399]
      .map { Self.laidOutWidth(elapsed: TimeInterval($0), base: 58) }
    XCTAssertEqual(Set(widths).count, 1, "the timer changed width mid-session: \(widths)")
  }

  // MARK: - Helpers

  private static func laidOutWidth(elapsed: TimeInterval, base: CGFloat) -> CGFloat {
    let view = NSHostingView(rootView: SessionTimer(elapsed: elapsed, base: base))
    view.layoutSubtreeIfNeeded()
    return view.fittingSize.width
  }

  /// The bare text at the size the step function chose, with no plate around
  /// it — what the timer *would* have been if it reflowed.
  private static func renderedWidth(elapsed: TimeInterval, base: CGFloat) -> CGFloat {
    let font = NSFont.monospacedSystemFont(
      ofSize: SessionTimerMetrics.fontSize(base: base, elapsed: elapsed),
      weight: .medium
    )
    let text = SessionTimerMetrics.text(elapsed: elapsed) as NSString
    return text.size(withAttributes: [.font: font]).width
  }
}
