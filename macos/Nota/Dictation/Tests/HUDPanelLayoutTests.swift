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

  /// A style that reserves nothing gets exactly the arithmetic it always had.
  func testAStyleThatCannotGrowKeepsTheOriginalPlacement() {
    for anchorMinY in [800.0, 400.0, 60.0, 8.0, 0.0] as [CGFloat] {
      let y = HUDPanelLayout.pillOriginY(
        anchorMinY: anchorMinY, screenFrame: Self.screen, pillHeight: 96, reservedHeight: 96
      )
      let original = max(
        Self.screen.minY + 8, min(anchorMinY - 12 - 96, Self.screen.maxY - 96 - 8)
      )
      XCTAssertEqual(y, original, accuracy: 0.01, "anchor at \(anchorMinY)")
    }
    XCTAssertNil(HUDStyle.pill.reservedCardHeight)
    XCTAssertNil(HUDStyle.bar.reservedCardHeight)
    XCTAssertEqual(HUDStyle.prompter.reservedCardHeight, Self.capHeight)
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
  private static func grownFrame(reservedHeight: CGFloat) -> NSRect {
    let margin = DictationHUDContentView.shadowMargin
    let y = HUDPanelLayout.pillOriginY(
      anchorMinY: screen.minY,
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

