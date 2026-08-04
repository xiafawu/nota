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

  /// A plate nobody has touched is already carrying the default weight — the
  /// setting's factory value, not some third number the view invented.
  func testTheGlassStartsAtTheDefaultTint() {
    let view = GlassBackingView(inset: Self.inset)
    XCTAssertEqual(view.tintAlpha, GlassTint.standard)
    XCTAssertEqual(view.glassView.tintColor, GlassTint.color(alpha: GlassTint.standard))
  }

  /// **Assigning the alpha is the whole of applying it.** The setting can move
  /// while a panel is on screen, so the live material has to be retinted rather
  /// than the next-created one.
  func testSettingTheAlphaRetintsTheLiveMaterial() {
    let view = GlassBackingView(inset: Self.inset)
    view.tintAlpha = 0.8
    let tint = try? XCTUnwrap(view.glassView.tintColor?.usingColorSpace(.deviceRGB))
    XCTAssertEqual(tint?.alphaComponent ?? 0, 0.8, accuracy: 0.001)
    // The hue does not move with it: this is a neutral cast that lets white text
    // be read, and a coloured one would be a different surface. Read off the RGB
    // channels, not `whiteComponent` — that accessor throws on anything but a
    // grey colour space.
    XCTAssertEqual(tint?.redComponent ?? -1, GlassTint.hue, accuracy: 0.001)
    XCTAssertEqual(tint?.blueComponent ?? -1, GlassTint.hue, accuracy: 0.001)
  }

  /// The view is the last boundary a stored number crosses before the window
  /// server, so it corrects rather than trusts.
  func testAnOutOfRangeAlphaIsClampedAtTheView() {
    let view = GlassBackingView(inset: Self.inset)
    view.tintAlpha = 5
    XCTAssertEqual(
      view.glassView.tintColor?.usingColorSpace(.deviceRGB)?.alphaComponent ?? 0,
      CGFloat(GlassTint.range.upperBound),
      accuracy: 0.001
    )
    view.tintAlpha = 0
    XCTAssertEqual(
      view.glassView.tintColor?.usingColorSpace(.deviceRGB)?.alphaComponent ?? 0,
      CGFloat(GlassTint.range.lowerBound),
      accuracy: 0.001
    )
  }
}

// MARK: - Glass tint

/// The arithmetic behind the slider. Pure, so the bounds the setting promises
/// are asserted once and every clamp on the path quotes them.
final class GlassTintTests: XCTestCase {
  func testTheDefaultIsInsideTheOfferedRange() {
    XCTAssertTrue(GlassTint.range.contains(GlassTint.standard))
    XCTAssertLessThan(GlassTint.range.lowerBound, GlassTint.range.upperBound)
  }

  func testValuesInsideTheRangeAreUntouched() {
    for alpha in [GlassTint.range.lowerBound, 0.35, GlassTint.standard, GlassTint.range.upperBound] {
      XCTAssertEqual(GlassTint.clamped(alpha), alpha, accuracy: 0.0001, "\(alpha)")
    }
  }

  func testValuesOutsideTheRangeAreClampedToIt() {
    XCTAssertEqual(GlassTint.clamped(-1), GlassTint.range.lowerBound)
    XCTAssertEqual(GlassTint.clamped(0.19), GlassTint.range.lowerBound)
    XCTAssertEqual(GlassTint.clamped(1), GlassTint.range.upperBound)
    XCTAssertEqual(GlassTint.clamped(42), GlassTint.range.upperBound)
  }

  /// A comparison against NaN answers false in both directions, so a plain
  /// min/max clamp would pass it straight through to a colour with no alpha.
  func testANonNumberFallsBackToTheDefault() {
    XCTAssertEqual(GlassTint.clamped(.nan), GlassTint.standard)
    XCTAssertEqual(GlassTint.clamped(.infinity), GlassTint.standard)
  }

  /// Only the alpha is the owner's.
  func testTheHueNeverMoves() {
    for alpha in [0.2, 0.55, 0.9, 12.0] {
      let color = try? XCTUnwrap(GlassTint.color(alpha: alpha).usingColorSpace(.deviceRGB))
      XCTAssertEqual(color?.redComponent ?? -1, GlassTint.hue, accuracy: 0.001, "\(alpha)")
      XCTAssertEqual(color?.greenComponent ?? -1, GlassTint.hue, accuracy: 0.001, "\(alpha)")
    }
  }
}

// MARK: - The setting

/// `hudGlassOpacity` is a new key, and the field-by-field decode is what keeps
/// adding one from costing the owner every other dictation preference they have.
final class GlassOpacitySettingTests: XCTestCase {
  override func tearDown() {
    DictationSettingsStore.reset()
    super.tearDown()
  }

  func testDefaultIsTheStandardTint() {
    XCTAssertEqual(DictationSettings().hudGlassOpacity, GlassTint.standard)
  }

  func testMissingKeyDecodesToTheDefaultWithoutDisturbingOtherFields() throws {
    // Every payload written before today is this one.
    let json = """
      {"engine":"apple","activation":"toggle","polishEnabled":true,
       "showHUD":true,"deliveryMode":"review","hudStyle":"prompter",
       "trigger":{"kind":"fnGlobe"}}
      """
    let settings = try JSONDecoder().decode(DictationSettings.self, from: Data(json.utf8))
    XCTAssertEqual(settings.hudGlassOpacity, GlassTint.standard)
    XCTAssertEqual(settings.hudStyle, .prompter)
    XCTAssertEqual(settings.deliveryMode, .review)
    XCTAssertEqual(settings.activation, .toggle)
    XCTAssertEqual(settings.polishEnabled, true)
  }

  func testAnOutOfRangeStoredValueIsClampedNotRefused() throws {
    for (stored, expected) in [("0.02", GlassTint.range.lowerBound),
                               ("4", GlassTint.range.upperBound)] {
      let json = """
        {"engine":"apple","activation":"hold","showHUD":true,
         "hudGlassOpacity":\(stored),"trigger":{"kind":"fnGlobe"}}
        """
      let settings = try JSONDecoder().decode(DictationSettings.self, from: Data(json.utf8))
      XCTAssertEqual(settings.hudGlassOpacity, expected, "\(stored)")
      // Refusing would throw, and a throw resets everything.
      XCTAssertEqual(settings.showHUD, true)
    }
  }

  func testAWrongTypeDecodesToTheDefault() throws {
    let json = """
      {"showHUD":true,"hudGlassOpacity":"very","trigger":{"kind":"fnGlobe"}}
      """
    let settings = try JSONDecoder().decode(DictationSettings.self, from: Data(json.utf8))
    XCTAssertEqual(settings.hudGlassOpacity, GlassTint.standard)
    XCTAssertEqual(settings.showHUD, true)
  }

  /// The setter clamps too: the slider cannot produce an out-of-range value, but
  /// nothing else on the path is a slider.
  func testAssigningOutOfRangeIsClamped() {
    var settings = DictationSettings()
    settings.hudGlassOpacity = 3
    XCTAssertEqual(settings.hudGlassOpacity, GlassTint.range.upperBound)
    settings.hudGlassOpacity = -3
    XCTAssertEqual(settings.hudGlassOpacity, GlassTint.range.lowerBound)
  }

  func testItRoundTripsThroughJSONAndTheStore() throws {
    for alpha in [GlassTint.range.lowerBound, 0.4, GlassTint.range.upperBound] {
      var settings = DictationSettings()
      settings.hudGlassOpacity = alpha
      let decoded = try JSONDecoder().decode(
        DictationSettings.self, from: JSONEncoder().encode(settings)
      )
      XCTAssertEqual(decoded.hudGlassOpacity, alpha, accuracy: 0.0001)
      XCTAssertEqual(decoded, settings)

      DictationSettingsStore.save(settings)
      XCTAssertEqual(DictationSettingsStore.load().hudGlassOpacity, alpha, accuracy: 0.0001)
    }
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

  /// The owner's tint weight rides along with the style on the one call the HUD
  /// makes every tick, so whatever Settings last saved is on the panel by its
  /// next frame.
  func testTheHUDPlateTakesTheOwnersTintWeight() throws {
    let panel = DictationHUDPanel()
    defer { panel.orderOut(nil) }
    let drag = try XCTUnwrap(panel.contentView as? HUDDragView)

    panel.update(state: .listening(level: 0.3), draft: .empty, style: .pill, glassOpacity: 0.85)
    XCTAssertEqual(drag.tintAlpha, 0.85, accuracy: 0.0001)

    // Out of range at the caller is corrected here rather than sent on.
    panel.update(state: .listening(level: 0.3), draft: .empty, style: .pill, glassOpacity: 9)
    XCTAssertEqual(drag.tintAlpha, GlassTint.range.upperBound)
  }

  /// The card is retinted through the presenter, which is what makes a Settings
  /// visit reach a card that is already up.
  func testTheReviewCardTakesTheOwnersTintWeight() throws {
    let panel = DictationReviewPanel(model: DictationReviewModel())
    defer { panel.orderOut(nil) }
    let backing = try XCTUnwrap(panel.contentView as? GlassBackingView)

    panel.setGlassTintAlpha(0.25)
    XCTAssertEqual(backing.tintAlpha, 0.25, accuracy: 0.0001)
    panel.setGlassTintAlpha(-4)
    XCTAssertEqual(backing.tintAlpha, GlassTint.range.lowerBound)
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
