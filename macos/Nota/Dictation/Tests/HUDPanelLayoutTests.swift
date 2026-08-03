import AppKit
import SwiftUI
import XCTest

@testable import Nota

// MARK: - Panel layout

/// Where the panel hangs, and what the growth rule needs from that placement.
@MainActor
final class HUDPanelLayoutTests: XCTestCase {
  private static let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
  private static let floorHeight = HUDPrompterMetrics.cardHeight(
    lineCount: HUDPrompterMetrics.minLines
  )
  private static let capHeight = HUDPrompterMetrics.cardHeight(
    lineCount: HUDPrompterMetrics.maxLines
  )

  /// An anchor with room under it still gets exactly "hang 12pt below the
  /// focused window" — the resting margin is a floor, not a nudge.
  func testAnAnchorWithRoomUnderItHangsUnderTheWindow() {
    for anchorMinY in [800.0, 400.0, 200.0] as [CGFloat] {
      let y = HUDPanelLayout.pillOriginY(
        anchorMinY: anchorMinY, screenFrame: Self.screen, pillHeight: 96, reservedHeight: 96
      )
      XCTAssertEqual(y, anchorMinY - 12 - 96, accuracy: 0.01, "anchor at \(anchorMinY)")
    }
  }

  /// Which styles reserve growth room. The pill is in this list now: its draft
  /// block grows to eight lines, and a growing style that reserves nothing is
  /// one whose bottom edge the clamp walks downward.
  func testEveryStyleThatCanGrowDeclaresItsGrownHeight() {
    XCTAssertNil(HUDStyle.bar.reservedCardHeight)
    XCTAssertEqual(HUDStyle.pill.reservedCardHeight, HUDPillMetrics.maxCardHeight)
    XCTAssertEqual(HUDStyle.prompter.reservedCardHeight, Self.capHeight)
  }

  /// The default placement never comes to rest on the screen's bottom edge.
  ///
  /// Nearly every window reaches close to the bottom of the visible frame, so
  /// "12pt below the focused window" used to collapse onto the 8pt hard floor
  /// for almost every anchor — the HUD sat in the last few points of the screen
  /// and read as hanging off it.
  func testTheHUDNeverComesToRestOnTheScreenEdge() {
    for anchorMinY in [120.0, 60.0, 8.0, 0.0, -400.0] as [CGFloat] {
      let y = HUDPanelLayout.pillOriginY(
        anchorMinY: anchorMinY,
        screenFrame: Self.screen,
        pillHeight: Self.floorHeight,
        reservedHeight: Self.capHeight
      )
      XCTAssertEqual(
        y,
        Self.screen.minY + HUDPanelLayout.screenInset + HUDPanelLayout.restingBottomMargin,
        accuracy: 0.01,
        "anchor at \(anchorMinY)"
      )
    }
  }

  func testWithoutAnAnchorTheCardRestsAtTheSameHeight() {
    XCTAssertEqual(
      HUDPanelLayout.pillOriginY(
        anchorMinY: nil,
        screenFrame: Self.screen,
        pillHeight: Self.floorHeight,
        reservedHeight: Self.capHeight
      ),
      Self.screen.minY + HUDPanelLayout.screenInset + HUDPanelLayout.restingBottomMargin,
      accuracy: 0.01
    )
  }

  /// Growth reserves room ABOVE: with the bottom edge pinned at the screen's
  /// bottom inset, the fully grown card's top still fits on screen.
  func testAnAnchorAtTheScreenBottomStillLeavesRoomForTheFullyGrownCard() {
    let y = HUDPanelLayout.pillOriginY(
      anchorMinY: Self.screen.minY,
      screenFrame: Self.screen,
      pillHeight: Self.floorHeight,
      reservedHeight: Self.capHeight
    )
    XCTAssertLessThanOrEqual(
      y + Self.capHeight, Self.screen.maxY - HUDPanelLayout.screenInset,
      "the grown card's top would walk off the screen"
    )
    XCTAssertGreaterThanOrEqual(
      y, Self.screen.minY + HUDPanelLayout.screenInset,
      "the card was placed below the screen"
    )
  }

  /// Growth is upward with the bottom edge pinned: after a reserved placement,
  /// the fully grown card's top stays on screen and `clamped` has nothing
  /// left to correct.
  func testGrowingToTheCapAfterAReservedPlacementIsNotClamped() {
    let grown = Self.grownFrame(reservedHeight: Self.capHeight)
    XCTAssertEqual(DictationHUDPanel.clamped(grown, visibleFrame: Self.screen), grown)
  }

  /// The same growth without the reserve, which is the finding: the clamp
  /// shoves the card back onto the screen and the bottom edge moves.
  func testWithoutTheReserveTheClampMovesTheBottomEdge() {
    let grown = Self.grownFrame(reservedHeight: Self.floorHeight)
    let corrected = DictationHUDPanel.clamped(grown, visibleFrame: Self.screen)
    XCTAssertLessThan(corrected.maxY, grown.maxY)
    XCTAssertLessThan(
      corrected.minY, grown.minY,
      "the pinned bottom edge is what the clamp drags downward"
    )
  }

  // MARK: The owner's own position

  private static let pillSize = CGSize(width: 420, height: 96)

  func testAPinnedPointOnTheScreenIsHonored() {
    let point = CGPoint(x: 700, y: 300)
    XCTAssertEqual(
      HUDPanelLayout.validatedPinnedPoint(
        point, pillSize: Self.pillSize, reservedHeight: 200, visibleFrames: [Self.screen]
      ),
      point
    )
  }

  /// The screen it was recorded on is gone: the stored position is dropped so
  /// the caller falls back to the automatic placement. Clamping it onto
  /// whatever screen is left would call an arbitrary point the owner's choice.
  func testAPinnedPointOnNoCurrentScreenIsRefused() {
    XCTAssertNil(
      HUDPanelLayout.validatedPinnedPoint(
        CGPoint(x: 3000, y: 1400),
        pillSize: Self.pillSize,
        reservedHeight: 200,
        visibleFrames: [Self.screen]
      )
    )
  }

  /// A point the screen still holds but can no longer host comfortably —
  /// lower resolution, or a card that grew — is clamped, not dropped.
  func testAPinnedPointKeepsTheHUDWhollyOnScreenWithItsGrowthRoom() {
    let point = CGPoint(x: Self.screen.maxX - 4, y: Self.screen.maxY - 4)
    let fixed = HUDPanelLayout.validatedPinnedPoint(
      point, pillSize: Self.pillSize, reservedHeight: Self.capHeight,
      visibleFrames: [Self.screen]
    )
    let clamped = try! XCTUnwrap(fixed)
    XCTAssertLessThanOrEqual(
      clamped.x + Self.pillSize.width / 2, Self.screen.maxX - HUDPanelLayout.screenInset
    )
    XCTAssertGreaterThanOrEqual(
      clamped.x - Self.pillSize.width / 2, Self.screen.minX + HUDPanelLayout.screenInset
    )
    XCTAssertLessThanOrEqual(
      clamped.y + Self.capHeight, Self.screen.maxY - HUDPanelLayout.screenInset,
      "a restored card must keep the room it can grow into"
    )
    XCTAssertGreaterThanOrEqual(
      clamped.y, Self.screen.minY + HUDPanelLayout.screenInset
    )
  }

  /// A screen too narrow for the style is refused outright — there is no x that
  /// keeps a 600pt card inside a 400pt screen.
  func testAPinnedPointOnAScreenTooNarrowForTheStyleIsRefused() {
    XCTAssertNil(
      HUDPanelLayout.validatedPinnedPoint(
        CGPoint(x: 200, y: 100),
        pillSize: CGSize(width: 600, height: 96),
        reservedHeight: 96,
        visibleFrames: [NSRect(x: 0, y: 0, width: 400, height: 300)]
      )
    )
  }

  /// The store round-trips through the same defaults suite the settings store
  /// uses — private and wiped under XCTest, so this cannot move the owner's
  /// real HUD.
  func testTheDraggedPositionRoundTripsAndClears() {
    HUDPositionStore.clear()
    XCTAssertNil(HUDPositionStore.load())
    HUDPositionStore.save(CGPoint(x: 512.5, y: 96))
    XCTAssertEqual(HUDPositionStore.load(), CGPoint(x: 512.5, y: 96))
    HUDPositionStore.clear()
    XCTAssertNil(HUDPositionStore.load())
  }

  /// Reserving room the screen does not have would push the card off the top;
  /// staying on screen wins.
  func testAScreenTooShortForTheGrownCardPrefersStayingOnScreen() {
    let short = NSRect(x: 0, y: 0, width: 800, height: 200)
    let y = HUDPanelLayout.pillOriginY(
      anchorMinY: 190, screenFrame: short, pillHeight: 120, reservedHeight: 600
    )
    XCTAssertLessThanOrEqual(y, short.maxY - 120 - 8)
    XCTAssertGreaterThanOrEqual(y, short.minY)
  }

  func testWithoutAnAnchorTheCardStillReservesItsGrowthRoom() {
    let y = HUDPanelLayout.pillOriginY(
      anchorMinY: nil,
      screenFrame: Self.screen,
      pillHeight: Self.floorHeight,
      reservedHeight: Self.capHeight
    )
    XCTAssertLessThanOrEqual(
      y + Self.capHeight, Self.screen.maxY - HUDPanelLayout.screenInset,
      "the grown card's top would walk off the screen"
    )
  }

  // MARK: Animation authority

  /// A style switch is not growth: the caller repositions right after it, and
  /// an animation still in flight means the reposition reads an interpolated
  /// frame and is then overwritten by the animation's destination.
  func testAStyleSwitchIsNeverAnimated() {
    for style in HUDStyle.allCases {
      XCTAssertFalse(
        DictationHUDPanel.animatesFrameChange(
          style: style, styleChanged: true, isVisible: true
        ),
        "\(style) animated its own switch"
      )
    }
  }

  func testGrowthIsAnimatedForEveryStyleThatCanGrow() {
    XCTAssertTrue(
      DictationHUDPanel.animatesFrameChange(style: .pill, styleChanged: false, isVisible: true)
    )
    XCTAssertTrue(
      DictationHUDPanel.animatesFrameChange(style: .prompter, styleChanged: false, isVisible: true)
    )
    XCTAssertFalse(
      DictationHUDPanel.animatesFrameChange(style: .bar, styleChanged: false, isVisible: true)
    )
  }

  func testAHiddenPanelIsNeverAnimated() {
    for style in HUDStyle.allCases {
      XCTAssertFalse(
        DictationHUDPanel.animatesFrameChange(
          style: style, styleChanged: false, isVisible: false
        )
      )
    }
  }

  /// A window frame placed with `reservedHeight` and then grown to the cap the
  /// way `DictationHUDPanel.update` grows it: origin fixed, height up, bottom
  /// edge pinned.
  ///
  /// The anchor is near the screen's TOP, which is where upward growth meets
  /// the clamp. (It was at the bottom while growth was downward, and left both
  /// tests below asserting nothing once the direction flipped: from a
  /// bottom-anchored placement a card can grow to any height it likes.)
  private static func grownFrame(reservedHeight: CGFloat, anchorMinY: CGFloat = 880) -> NSRect {
    let margin = DictationHUDContentView.shadowMargin
    let y = HUDPanelLayout.pillOriginY(
      anchorMinY: anchorMinY,
      screenFrame: screen,
      pillHeight: floorHeight,
      reservedHeight: reservedHeight
    )
    var frame = NSRect(
      x: 300 - margin,
      y: y - margin,
      width: HUDPrompterMetrics.width + margin * 2,
      height: floorHeight + margin * 2
    )
    let growth = capHeight - floorHeight
    frame.size.height += growth
    return frame
  }
}

