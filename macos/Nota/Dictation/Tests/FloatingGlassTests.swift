import AppKit
import SwiftUI
import XCTest

@testable import Nota

// MARK: - Glass metrics

/// The glass plate is an AppKit view and cannot take a `Shape`, so each style's
/// curvature has to be restated as one number. These pin the restatement to the
/// styles' own constants rather than to a second copy of them.
final class HUDGlassMetricsTests: XCTestCase {
  func testTheBarAndPrompterAskForTheirOwnCornerRadius() {
    XCTAssertEqual(
      HUDGlassMetrics.cornerRadius(style: .bar, state: .listening(level: 0.3), cardHeight: 40),
      HUDBarMetrics.cornerRadius
    )
    XCTAssertEqual(
      HUDGlassMetrics.cornerRadius(style: .prompter, state: .listening(level: 0.3), cardHeight: 120),
      HUDPrompterMetrics.cornerRadius
    )
  }

  /// The pill is a capsule in its ordinary states — half its own height,
  /// whatever that height is — which is what `HUDPillShape` draws when it has no
  /// cap.
  func testThePillIsACapsuleAtEveryHeight() {
    for height in [48.0, 96.0, 240.0] as [CGFloat] {
      XCTAssertEqual(
        HUDGlassMetrics.cornerRadius(
          style: .pill, state: .listening(level: 0.3), cardHeight: height
        ),
        height / 2,
        accuracy: 0.001,
        "height \(height)"
      )
    }
  }

  /// Warning and error wrap to a second line, and a capsule's end caps grow with
  /// height — the two states `HUDPillShape` caps are the two the plate caps.
  func testWarningAndErrorAreCappedSoATwoLinePillIsNotALozenge() {
    for state in [HUDState.warning(message: "hm"), .error(message: "no")] {
      XCTAssertEqual(
        HUDGlassMetrics.cornerRadius(style: .pill, state: state, cardHeight: 120),
        HUDGlassMetrics.pillCappedCornerRadius,
        "\(state)"
      )
    }
    // Below twice the cap the capsule is still the smaller radius: a short
    // warning must not be squarer than the pill it replaced.
    XCTAssertEqual(
      HUDGlassMetrics.cornerRadius(
        style: .pill, state: .warning(message: "hm"), cardHeight: 30
      ),
      15
    )
  }
}

// MARK: - Glass backing

/// The plate itself: where it sits, what it takes, and what it does not.
@MainActor
final class GlassBackingViewTests: XCTestCase {
  private static let inset: CGFloat = 24

  /// The glass is laid out at the CARD rect — the view's bounds inset by the
  /// transparent margin — and never at the window frame. Filling the frame would
  /// put the material where the shadow goes and square off the corners against
  /// the window's edges.
  func testTheGlassIsInsetByTheShadowMargin() {
    let view = GlassBackingView(inset: Self.inset)
    view.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
    view.layoutSubtreeIfNeeded()

    XCTAssertEqual(
      view.glassView.frame,
      NSRect(x: Self.inset, y: Self.inset, width: 300 - Self.inset * 2, height: 200 - Self.inset * 2)
    )
  }

  /// A style may ask for "as round as possible" (the pill asks for half its
  /// height); the plate clamps to a capsule rather than drawing a radius larger
  /// than the rect can hold.
  func testTheCornerRadiusIsClampedToACapsule() {
    let view = GlassBackingView(inset: Self.inset)
    view.glassCornerRadius = 9999
    view.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
    view.layoutSubtreeIfNeeded()

    let card = view.glassView.frame
    XCTAssertEqual(view.glassView.cornerRadius, min(card.width, card.height) / 2)
  }

  /// A window smaller than twice the margin has no card rect at all. It must
  /// produce an empty plate, not a negative one.
  func testAViewSmallerThanItsMarginDrawsNoGlass() {
    let view = GlassBackingView(inset: Self.inset)
    view.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(view.glassView.frame, .zero)
  }

  /// **The plate takes no clicks.** The HUD claims every point of its surface
  /// for the drag handle and the review card's editor must keep text selection;
  /// a material intercepting events would break one or the other.
  func testTheGlassNeverTakesAHit() {
    let view = GlassBackingView(inset: Self.inset)
    view.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
    view.layoutSubtreeIfNeeded()
    XCTAssertNil(view.glassView.hitTest(NSPoint(x: 20, y: 20)))
  }

  /// The content sits ABOVE the glass and spans the whole view — margin
  /// included, because the padding that produces the margin lives inside the
  /// hosted view and is what every pinned fitting size measures.
  func testTheContentIsAboveTheGlassAndFillsTheView() {
    let view = GlassBackingView(inset: Self.inset)
    let content = NSView()
    view.setContent(content)
    view.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
    view.layoutSubtreeIfNeeded()

    let glassIndex = try? XCTUnwrap(view.subviews.firstIndex(of: view.glassView))
    let contentIndex = try? XCTUnwrap(view.subviews.firstIndex(of: content))
    XCTAssertNotNil(glassIndex)
    XCTAssertNotNil(contentIndex)
    XCTAssertGreaterThan(contentIndex ?? 0, glassIndex ?? 0, "the content is under the glass")
    XCTAssertEqual(content.frame, view.bounds)
  }

  /// A hidden HUD collapses its SwiftUI content to nothing while the window
  /// frame stays put. Without this the panel would be a bare pane of glass.
  func testTheGlassCanBeStoodDown() {
    let view = GlassBackingView(inset: Self.inset)
    XCTAssertFalse(view.glassView.isHidden)
    view.showsGlass = false
    XCTAssertTrue(view.glassView.isHidden)
  }
}

// MARK: - Panels carry it

/// Both floating dictation surfaces are glass, and both still keep every
/// behavioural promise the flat fill was carrying.
@MainActor
final class DictationPanelGlassTests: XCTestCase {
  /// The HUD's drag view IS the plate carrier, and it still claims every point:
  /// the glass is a sibling underneath it, not a layer over it.
  func testTheHUDPanelIsGlassAndStillDraggableEverywhere() {
    let panel = DictationHUDPanel()
    defer { panel.orderOut(nil) }
    let drag = try? XCTUnwrap(panel.contentView as? HUDDragView)
    XCTAssertNotNil(drag, "the HUD's content view is no longer the drag/glass carrier")
    guard let drag else { return }

    XCTAssertTrue(drag.glassView.superview === drag)
    XCTAssertTrue(
      drag.hitTest(NSPoint(x: 5, y: 5)) === drag,
      "the drag handle stopped claiming its own surface"
    )
    // The ordering trap the panel has always had, re-asserted now that another
    // view sits between the panel and its content.
    XCTAssertEqual(panel.level, .statusBar)
    XCTAssertEqual(panel.appearance?.name, .darkAqua)

    // **The window server accepts it.** Not proof of refraction — nothing in a
    // unit test is — but it is the half that can fail silently: a material the
    // server refuses inside a borderless nonactivating panel would leave the
    // plate laid out and unrendered, and the HUD would look exactly as it does
    // when everything is fine.
    panel.update(state: .listening(level: 0.3), draft: .empty, style: .pill)
    panel.reposition()
    XCTAssertTrue(panel.show(), "the pill never reached the screen")
    XCTAssertGreaterThan(panel.windowNumber, 0)
    XCTAssertGreaterThan(drag.glassView.frame.width, 0)
    XCTAssertFalse(drag.glassView.isHidden)
    // Off the screen again here rather than only in the `defer`: this suite runs
    // alongside tests that read the host's own Accessibility state, and a HUD
    // left on screen is a window they would have to see.
    panel.orderOut(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
  }

  /// The pill's shape reaches the plate: a warning is capped, ordinary states
  /// are capsules, and `.hidden` shows no material at all.
  func testTheHUDPlateFollowsTheStateAndStyle() throws {
    let panel = DictationHUDPanel()
    defer { panel.orderOut(nil) }
    let drag = try XCTUnwrap(panel.contentView as? HUDDragView)

    // A one-line warning is under 40pt tall, so the capsule (half its height) is
    // still the smaller radius and the cap does not bind — which is exactly the
    // rule, and why this asserts the bound rather than the constant.
    panel.update(state: .warning(message: "polish failed"), draft: .empty, style: .pill)
    XCTAssertGreaterThan(drag.glassCornerRadius, 0)
    XCTAssertLessThanOrEqual(drag.glassCornerRadius, HUDGlassMetrics.pillCappedCornerRadius)
    XCTAssertTrue(drag.showsGlass)

    // A tall pill IS capped: the plate must not become a lozenge when the draft
    // block grows the card past twice the cap.
    panel.update(
      state: .listening(level: 0.4),
      draft: HUDDraft(finalized: (1...8).map { "line \($0)" }.joined(separator: "\n"), volatileTail: ""),
      style: .pill
    )
    XCTAssertGreaterThan(
      drag.glassCornerRadius,
      HUDGlassMetrics.pillCappedCornerRadius,
      "an ordinary pill is a capsule at every height"
    )

    panel.update(state: .listening(level: 0.4), draft: .empty, style: .bar)
    XCTAssertEqual(drag.glassCornerRadius, HUDBarMetrics.cornerRadius)

    panel.update(state: .hidden, draft: .empty, style: .pill)
    XCTAssertFalse(drag.showsGlass, "a hidden HUD is a bare pane of glass")
  }

  /// The review card's plate carries the card's own curvature, and the panel's
  /// two load-bearing window flags survive the extra view in between.
  func testTheReviewCardIsGlassAndStillKeyWithoutActivating() throws {
    let panel = DictationReviewPanel(model: DictationReviewModel())
    defer { panel.orderOut(nil) }

    let backing = try XCTUnwrap(panel.contentView as? GlassBackingView)
    XCTAssertEqual(backing.glassCornerRadius, DictationReviewView.cornerRadius)
    XCTAssertFalse(
      backing is HUDDragView,
      "the card must not claim every point — its editor has to select text"
    )
    XCTAssertTrue(panel.canBecomeKey)
    XCTAssertFalse(panel.canBecomeMain)
    XCTAssertEqual(panel.level, .statusBar)
    XCTAssertEqual(panel.appearance?.name, .darkAqua)
    XCTAssertFalse(panel.isMovableByWindowBackground)
    // The editor is still reachable from the content view, which is how the
    // panel focuses it and how the review tests type into it.
    panel.sizeToFitContent()
    XCTAssertTrue(
      spinUntil { DictationReviewPanel.firstTextView(in: panel.contentView) != nil },
      "the glass backing hid the editor from the view tree"
    )
  }

  private func spinUntil(_ condition: () -> Bool, timeout: TimeInterval = 2) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
  }
}
