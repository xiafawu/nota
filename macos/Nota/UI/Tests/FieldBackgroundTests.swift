import AppKit
import CoreGraphics
import SwiftUI
import XCTest

@testable import Nota

/// The driver's promises, as opposed to the field's.
///
/// `FieldEngineTests` asserts on the `[Float]` buffer and never builds a frame;
/// everything here is about the half that has a clock and a refcount — who is
/// looking, whether it is ticking, and what happens when the owner has asked
/// for less motion. None of it waits on a run loop: the engine takes an
/// injected simulation and `tick(dt:)` is called directly, so a timer that
/// never fires cannot make a green suite lie.
@MainActor
final class FieldBackgroundTests: XCTestCase {
  /// Its own defaults domain. The ground id is a real key in the real
  /// `com.xiafawu.nota` domain, and a test that drew a ground into
  /// `UserDefaults.standard` would silently decide the owner's next launch —
  /// the same trap `DictationSettingsStore` is isolated against.
  private var defaults: UserDefaults!
  private let suiteName = "com.xiafawu.nota.field-tests"

  override func setUp() {
    super.setUp()
    UserDefaults.standard.removePersistentDomain(forName: suiteName)
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() {
    UserDefaults.standard.removePersistentDomain(forName: suiteName)
    defaults = nil
    super.tearDown()
  }

  /// A small field, so a test that renders a few frames costs microseconds.
  /// The dimensions are odd on purpose — they are asserted against the image,
  /// and 64×36 is also the production default, which would pass by coincidence.
  private static let width = 24
  private static let height = 14

  private func makeEngine(light: Bool = true) -> FieldEngine {
    FieldEngine(
      simulation: FieldSimulation(
        width: FieldBackgroundTests.width,
        height: FieldBackgroundTests.height,
        palette: GroundPalette.palette(id: "tide")!,
        light: light))
  }

  // MARK: - The draw

  /// One **family** per launch, and never the one before it.
  ///
  /// XIA-446 moved the draw up a level: a launch used to pick a palette and the
  /// whole app wore it, and now it picks a chord of three and each view wears
  /// one of them. The rule is unchanged — a different ground every morning —
  /// and only the noun it applies to moved.
  func testTheEngineDrawsAFamilyThatIsNotLastLaunchesAndRemembersIt() {
    for previous in GroundFamily.all {
      defaults.set(previous.id, forKey: FieldEngine.familyDefaultsKey)
      var rng = SplitMix64(seed: 0xA11CE &+ UInt64(previous.name.count))
      let engine = FieldEngine(defaults: defaults, light: true, using: &rng)

      XCTAssertNotEqual(
        engine.family.id, previous.id,
        "the launch drew the family the last one used")
      XCTAssertEqual(
        defaults.string(forKey: FieldEngine.familyDefaultsKey), engine.family.id,
        "the family was drawn but not stored, so the next launch can repeat it")
    }
  }

  /// A first-ever launch has nothing to exclude and still gets a family.
  func testTheFirstLaunchDrawsWithNothingStored() {
    XCTAssertNil(defaults.string(forKey: FieldEngine.familyDefaultsKey))
    var rng = SplitMix64(seed: 99)
    let engine = FieldEngine(defaults: defaults, light: false, using: &rng)
    XCTAssertTrue(GroundFamily.all.contains(engine.family))
    XCTAssertEqual(defaults.string(forKey: FieldEngine.familyDefaultsKey), engine.family.id)
  }

  /// The launch opens on the home ground rather than on some neutral one it
  /// then travels away from. The first frame is almost always under the home
  /// dashboard, and a visible journey from the wrong colour to the right one
  /// would be the arrival cut with extra steps.
  func testTheEngineOpensOnItsFamilysHomeGround() {
    var rng = SplitMix64(seed: 7)
    let engine = FieldEngine(defaults: defaults, light: true, using: &rng)
    XCTAssertEqual(engine.palette, engine.family.palette(for: .home))
    XCTAssertEqual(engine.role, .home)
  }

  // MARK: - Who is looking

  /// The clock belongs to the viewers, not to whichever one appeared first.
  /// Both production surfaces can be up at once and the second to appear must
  /// not restart a running clock, nor the first to leave stop it.
  func testTheClockRunsWhileAnyViewerIsOnScreen() {
    let engine = makeEngine()
    XCTAssertFalse(engine.isRunning, "an engine nobody is looking at is inert")

    engine.addViewer()
    XCTAssertTrue(engine.isRunning)

    engine.addViewer()
    engine.removeViewer()
    XCTAssertTrue(engine.isRunning, "one of two viewers left and the ground froze")

    engine.removeViewer()
    XCTAssertFalse(engine.isRunning, "the last viewer left and the clock kept running")
  }

  /// An unbalanced remove may not drive the count negative — the next viewer
  /// would then arrive to a still ground and nothing on screen would say why.
  func testAnExtraRemoveCannotWedgeTheClockOff() {
    let engine = makeEngine()
    engine.removeViewer()
    engine.removeViewer()
    engine.addViewer()
    XCTAssertTrue(engine.isRunning)
    engine.removeViewer()
    XCTAssertFalse(engine.isRunning)
  }

  /// The simulation survives a viewer leaving, so returning to a screen rejoins
  /// the ground mid-drift instead of restarting it at minute zero.
  func testLeavingAndReturningKeepsTheSameGroundAndItsElapsedTime() {
    let engine = makeEngine()
    let ground = engine.palette.id
    engine.addViewer()
    for _ in 0..<10 { engine.tick(dt: 0.05) }
    engine.removeViewer()

    XCTAssertEqual(engine.simulation.elapsed, 0.5, accuracy: 1e-9)
    engine.addViewer()
    XCTAssertEqual(engine.palette.id, ground)
    XCTAssertEqual(engine.simulation.elapsed, 0.5, accuracy: 1e-9)
    engine.removeViewer()
  }

  // MARK: - Ticking

  /// A tick is exactly the time it was handed, and the frame it publishes is
  /// **this simulation's**.
  ///
  /// Checking `width`/`height` alone was the version of this test that could not
  /// fail: those come from the engine's own constants, so it passed against an
  /// all-black image, an all-white one, or one built from an uninitialized
  /// buffer. So it now reads the published bytes back and compares them to the
  /// buffer they were supposed to come from.
  func testATickAdvancesTheFieldByItsOwnDtAndPublishesThatFrame() {
    let engine = makeEngine()
    engine.tick(dt: 0.05)
    engine.tick(dt: 0.02)
    engine.tick(dt: 0.1)

    XCTAssertEqual(engine.simulation.elapsed, 0.17, accuracy: 1e-9)
    guard let image = engine.image else { return XCTFail("no frame was published") }
    XCTAssertEqual(image.width, FieldBackgroundTests.width)
    XCTAssertEqual(image.height, FieldBackgroundTests.height)

    let pixels = FieldBackgroundTests.rgbBytes(of: image)
    XCTAssertEqual(
      pixels.count, FieldBackgroundTests.width * FieldBackgroundTests.height * 3,
      "the published frame is not the shape of the field")

    // Not a constant image: a ground whose every cell is the same colour is what
    // a broken buffer looks like, and it would clear every other assertion here.
    XCTAssertGreaterThan(
      Set(pixels).count, 3,
      "the published frame is a flat colour — the buffer did not reach the image")

    for i in stride(from: 0, to: pixels.count, by: 97) {
      XCTAssertEqual(
        Int(pixels[i]), Int(engine.simulation.buffer[i].rounded()), accuracy: 1,
        "byte \(i) of the published frame is not the simulation's own value")
    }
  }

  /// A gap longer than the rail loses the time rather than advecting the whole
  /// frame in one step: after a sleep or a wedged main thread the honest `dt`
  /// is a jump, and a jump is the one thing this surface may never do.
  ///
  /// Swept rather than sampled at one value — a single `dt = 30` passes against
  /// a "clamp" that returns the cap unconditionally, and against one with no
  /// lower bound at all. A negative `dt` is not hypothetical: it is what a
  /// clock that went backwards hands you, and it would run the field in reverse.
  func testAStallIsClampedAtBothEnds() {
    for (dt, expected) in [
      (30.0, FieldEngine.maxStep),
      (FieldEngine.maxStep + 0.01, FieldEngine.maxStep),
      (0.05, 0.05),
      (0.0, 0.0),
      (-1.0, 0.0),
    ] {
      let engine = makeEngine()
      engine.tick(dt: dt)
      XCTAssertEqual(
        engine.simulation.elapsed, expected, accuracy: 1e-9,
        "dt \(dt) should have advanced the field by \(expected)")
    }
  }

  /// Nil is a state that exists only before the first frame — after that there
  /// is always something to draw.
  func testTheImageIsNilOnlyBeforeTheFirstFrame() {
    let engine = makeEngine()
    XCTAssertNil(engine.image)
    engine.tick(dt: 0.05)
    XCTAssertNotNil(engine.image)
  }

  /// A viewer never sees the fallback wash: appearing paints a frame before the
  /// clock is asked for one, so there is no cut between two different grounds.
  func testAViewerArrivingIsPaintedBeforeTheFirstTick() {
    let engine = makeEngine()
    engine.addViewer()
    XCTAssertNotNil(engine.image)
    XCTAssertEqual(engine.simulation.elapsed, 0, accuracy: 1e-9)
    engine.removeViewer()
  }

  // MARK: - The layering

  /// **One grain layer, and the floor is a gradient.**
  ///
  /// `CraftWashBackground` is `CraftTokens.washGradient` *plus its own*
  /// `CraftNoiseLayer`, so using it as the floor and hanging the grain over the
  /// field drew two full-window `Canvas` passes — ~952 seeded ellipse fills at
  /// 1280×800 — on every body evaluation and every resize step, with the lower
  /// one permanently occluded by the opaque field image. Exactly one could ever
  /// be seen; both were always drawn.
  ///
  /// Asserted against the body's **static type**, which names every sibling in
  /// the `ZStack` and is the only place a duplicated layer is visible without a
  /// window server. A renderer closure is not comparable, so nothing about the
  /// cost shows up in a bitmap: the second `Canvas` draws the same grain in the
  /// same place, which is precisely why it survived review.
  func testTheGroundDrawsExactlyOneGrainLayerOverAGradientFloor() {
    let description = String(describing: type(of: FieldBackground(role: .home, engine: makeEngine()).body))

    let grainLayers = description.components(separatedBy: "CraftNoiseLayer").count - 1
    XCTAssertEqual(
      grainLayers, 1,
      "the ground is drawing \(grainLayers) grain layers: \(description)")
    XCTAssertFalse(
      description.contains("CraftWashBackground"),
      "the floor is CraftWashBackground, which carries a second CraftNoiseLayer "
        + "of its own — it must be CraftTokens.washGradient: \(description)")
    XCTAssertTrue(
      description.contains("LinearGradient"),
      "the wash floor is gone; the CoreGraphics-refusal case degrades to a hole")
  }

  // MARK: - Paper

  /// Host a ground in an offscreen window and let `onAppear` run. An unhosted
  /// `NSHostingView` never fires it (`RenderProbe.bitmap`'s limit), and every
  /// viewer decision the ground makes is made there.
  private func host(_ view: some View, dark: Bool) -> NSWindow {
    let hosting = NSHostingView(rootView: view)
    hosting.frame = CGRect(x: 0, y: 0, width: 200, height: 120)
    let window = NSWindow(
      contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = hosting
    window.layoutIfNeeded()
    hosting.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.08))
    return window
  }

  private func settle(_ window: NSWindow) {
    window.contentView?.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.08))
  }

  /// **Both** light reading states wear paper and ask nothing of the engine
  /// (ADR 0007): no viewer, so no clock and no frame, and the role is left
  /// where the last field surface put it — a ground nobody drew must not
  /// become the one home morphs back from.
  ///
  /// The recording half is what changed. A whole light-mode session — press
  /// Start, talk, press Stop, read — now runs with the field engine inert,
  /// which is the point: there is nothing to swap at Stop because there is
  /// nothing moving on either side of it.
  func testTheLightReadingStatesWearPaperAndAskNothingOfTheEngine() {
    for role in [GroundRole.recording, .transcript] {
      let engine = makeEngine(light: true)
      let window = host(FieldBackground(role: role, engine: engine), dark: false)
      defer { window.close() }

      XCTAssertFalse(engine.isRunning, "\(role): a paper surface started the field's clock")
      XCTAssertNil(engine.image, "\(role): a paper surface had the field painted for nobody")
      XCTAssertEqual(engine.role, .home, "\(role): a paper surface steered the engine's role")
    }
  }

  /// Dark is entirely unchanged: both reading states keep the field, and each
  /// steers the engine to its own ground.
  func testTheDarkReadingStatesStillWearTheField() {
    for role in [GroundRole.recording, .transcript] {
      let engine = makeEngine(light: false)
      let window = host(FieldBackground(role: role, engine: engine), dark: true)
      defer { window.close() }

      XCTAssertTrue(engine.isRunning, "\(role)")
      XCTAssertNotNil(engine.image, "\(role)")
      XCTAssertEqual(engine.role, role)
    }
  }

  /// A scheme flip while either reading state is up moves it between paper and
  /// field in both directions — the viewer is taken and given back, so the
  /// clock follows the surface that is actually drawn.
  func testASchemeFlipMovesAReadingStateBetweenPaperAndField() {
    for role in [GroundRole.recording, .transcript] {
      let engine = makeEngine(light: true)
      let window = host(FieldBackground(role: role, engine: engine), dark: false)
      defer { window.close() }
      XCTAssertFalse(engine.isRunning, "\(role)")

      window.appearance = NSAppearance(named: .darkAqua)
      settle(window)
      XCTAssertTrue(engine.isRunning, "\(role): going dark did not put the field back under it")
      XCTAssertEqual(engine.role, role)
      XCTAssertFalse(engine.light)

      window.appearance = NSAppearance(named: .aqua)
      settle(window)
      XCTAssertFalse(engine.isRunning, "\(role): going light did not take the viewer back")
      XCTAssertTrue(engine.light)
    }
  }

  /// Moving between home (field) and a light recording (paper) hands the
  /// viewer back and forth, in both directions and repeatedly.
  ///
  /// The refcount is the thing at risk: a paper surface that forgot to give
  /// its viewer back would leave a 20 Hz clock painting for nobody for the
  /// rest of the run, and one that took a viewer it never had would drive the
  /// count to zero under a home screen still on screen. Neither shows up on a
  /// single transition.
  func testMovingBetweenHomeAndALightRecordingHandsTheViewerBack() {
    let engine = makeEngine(light: true)
    let box = GroundRoleBox(.home)
    let window = host(GroundRoleSwitcher(box: box, engine: engine), dark: false)
    defer { window.close() }

    XCTAssertTrue(engine.isRunning, "home did not start the clock")
    XCTAssertEqual(engine.role, .home)

    for _ in 0..<2 {
      box.role = .recording
      settle(window)
      XCTAssertFalse(engine.isRunning, "a light recording left the field running")
      XCTAssertEqual(engine.role, .home, "a paper surface steered the engine's role")

      box.role = .home
      settle(window)
      XCTAssertTrue(engine.isRunning, "coming back to home did not restart the clock")
      XCTAssertEqual(engine.role, .home)
    }
  }

  /// …and in dark, where a recording is still a field surface, the same move
  /// keeps the viewer and steers the role. This is the control for the test
  /// above: without it, "the engine stopped" would also pass for a recording
  /// surface that had simply stopped working.
  func testMovingBetweenHomeAndADarkRecordingKeepsTheViewerAndSteersTheRole() {
    let engine = makeEngine(light: false)
    let box = GroundRoleBox(.home)
    let window = host(GroundRoleSwitcher(box: box, engine: engine), dark: true)
    defer { window.close() }

    XCTAssertEqual(engine.role, .home)
    box.role = .recording
    settle(window)
    XCTAssertTrue(engine.isRunning, "a dark recording stopped the field")
    XCTAssertEqual(engine.role, .recording)

    box.role = .home
    settle(window)
    XCTAssertTrue(engine.isRunning)
    XCTAssertEqual(engine.role, .home, "home did not take the ground back")
  }

  /// **Nothing changes at Stop.** The live page and the document draw the same
  /// pixels in light mode, because both tint from the family's *transcript*
  /// palette — the family gives them different grounds, so paper resolved per
  /// role would still swap the colour under the owner at the press.
  ///
  /// The third render is what stops this passing vacuously: with no frame
  /// painted, a `FieldBackground` that had drawn no paper at all would fall
  /// through to the wash floor for both roles and compare equal. Home on a
  /// non-drawing engine *is* that floor, so requiring the reading states to
  /// differ from it is the assertion that paper was really drawn.
  func testTheRecordingPageAndTheDocumentDrawTheSamePaper() {
    let engine = makeEngine(light: true)
    let size = CGSize(width: 120, height: 80)

    func render(_ role: GroundRole, on engine: FieldEngine) -> NSBitmapImageRep? {
      RenderProbe.bitmap(
        FieldBackground(role: role, engine: engine).environment(\.colorScheme, .light),
        size: size)
    }

    guard
      let recording = render(.recording, on: engine),
      let transcript = render(.transcript, on: engine),
      // A non-drawing engine paints no frame, so `.home` here is exactly the
      // wash floor plus the grain — the surface paper has to differ from.
      let wash = render(
        .home,
        on: FieldEngine(
          simulation: FieldSimulation(
            width: FieldBackgroundTests.width,
            height: FieldBackgroundTests.height,
            palette: GroundPalette.palette(id: "tide")!,
            light: true),
          drawsFrames: false))
    else { return XCTFail("no bitmap") }

    var sampled = 0
    var differedFromWash = 0
    for x in stride(from: 0, to: recording.pixelsWide, by: 3) {
      for y in stride(from: 0, to: recording.pixelsHigh, by: 3) {
        guard
          let live = recording.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
          let doc = transcript.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
          let floor = wash.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        else { continue }
        sampled += 1
        XCTAssertEqual(
          FieldBackgroundTests.rgb(live), FieldBackgroundTests.rgb(doc),
          "the ground changes at Stop: pixel (\(x), \(y)) is \(live) live and \(doc) in the document")
        if FieldBackgroundTests.rgb(live) != FieldBackgroundTests.rgb(floor) { differedFromWash += 1 }
      }
    }

    XCTAssertGreaterThan(sampled, 100, "the probe read \(sampled) pixels")
    XCTAssertGreaterThan(
      differedFromWash, sampled / 2,
      "the reading states are drawing the wash floor, not paper — this test would "
        + "pass for two surfaces that draw nothing at all")
  }

  /// Home is untouched by any of this: light or dark, it is the field.
  func testHomeWearsTheFieldInBothThemes() {
    for dark in [false, true] {
      let engine = makeEngine(light: !dark)
      let window = host(FieldBackground(role: .home, engine: engine), dark: dark)
      defer { window.close() }
      XCTAssertTrue(engine.isRunning, dark ? "dark" : "light")
      XCTAssertEqual(engine.role, .home)
    }
  }

  /// Quantized so two renders are compared on what a display shows rather than
  /// on the last bit of a float.
  private static func rgb(_ color: NSColor) -> [Int] {
    [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
  }

  // MARK: - Reduce Motion

  /// Reduce Motion is implemented by not calling `step(dt:)`. The field is
  /// still painted — this setting removes movement, not the ground — and no
  /// later tick moves it.
  func testReduceMotionPaintsOneFrameAndThenHolds() {
    let engine = makeEngine()
    engine.reduceMotion = true
    engine.addViewer()

    XCTAssertNotNil(engine.image, "Reduce Motion left the ground blank")
    XCTAssertFalse(engine.isRunning, "the clock is running under Reduce Motion")

    for _ in 0..<20 { engine.tick(dt: 0.05) }
    XCTAssertEqual(
      engine.simulation.elapsed, 0, accuracy: 1e-9,
      "the field advanced under Reduce Motion")
    engine.removeViewer()
  }

  /// Turning it on mid-session stops the clock and leaves the frame that was
  /// already there.
  func testTurningReduceMotionOnStopsTheClockWithAFrameStillDrawn() {
    let engine = makeEngine()
    engine.addViewer()
    for _ in 0..<5 { engine.tick(dt: 0.05) }
    let elapsed = engine.simulation.elapsed

    engine.reduceMotion = true
    XCTAssertFalse(engine.isRunning)
    XCTAssertNotNil(engine.image)
    XCTAssertEqual(engine.simulation.elapsed, elapsed, accuracy: 1e-9)

    engine.reduceMotion = false
    XCTAssertTrue(engine.isRunning, "clearing Reduce Motion did not restart the clock")
    engine.removeViewer()
  }

  // MARK: - The colour scheme

  /// The band is where readability comes from, so a scheme change has to reach
  /// the published frame — and immediately, because a Reduce Motion engine will
  /// never tick again and would otherwise hold a light field under a dark app.
  func testSettingLightRepaintsTheFieldIntoTheOtherBand() {
    let engine = makeEngine(light: true)
    engine.reduceMotion = true
    engine.addViewer()

    guard
      let lightFrame = engine.image,
      let lightPixel = FieldBackgroundTests.pixel(lightFrame, x: 4, y: 4)
    else { return XCTFail("no light frame") }

    engine.light = false

    guard
      let darkFrame = engine.image,
      let darkPixel = FieldBackgroundTests.pixel(darkFrame, x: 4, y: 4)
    else { return XCTFail("no dark frame") }

    // Not "different pixels" — the bands are on opposite sides of the ink, so
    // the dark ground must be a long way *darker* and not merely another
    // colour. `FieldTheme.make` puts the light band at 0.885…0.985 and the dark
    // one at 0.10…0.26 of value at the shipping push, i.e. well over 100 levels
    // apart out of 255.
    let lightLuma = lightPixel.r + lightPixel.g + lightPixel.b
    let darkLuma = darkPixel.r + darkPixel.g + darkPixel.b
    XCTAssertGreaterThan(
      lightLuma - darkLuma, 300,
      "the published frame did not move to the dark band (light \(lightPixel), dark \(darkPixel))")

    // And the ground itself did not change: a scheme flip re-primes, it does
    // not re-roll.
    XCTAssertEqual(engine.palette.id, "tide")
    engine.removeViewer()
  }

  /// Setting the same value is not a repaint. `FieldSimulation` re-primes on
  /// any assignment that changes the value, and a view that pushes the scheme
  /// on every appearance must not be able to reset the field by agreeing with
  /// it.
  func testSettingTheSameSchemeDoesNotDisturbTheField() {
    let engine = makeEngine(light: true)
    engine.addViewer()
    for _ in 0..<10 { engine.tick(dt: 0.05) }
    let before = engine.simulation.color(x: 5, y: 5)

    engine.light = true

    let after = engine.simulation.color(x: 5, y: 5)
    XCTAssertEqual(before.x, after.x, accuracy: 1e-9)
    XCTAssertEqual(before.y, after.y, accuracy: 1e-9)
    XCTAssertEqual(before.z, after.z, accuracy: 1e-9)
    engine.removeViewer()
  }

  // MARK: - The shared engine, under test

  /// The shared engine is inert in this bundle, and both halves of that matter.
  ///
  /// `RecordingPaneTests.testTheIdlePaneDrawsNoEmber` renders `LiveMeetingView`
  /// and counts ember pixels; that view's ground is `FieldBackground()` on this
  /// engine, and `onAppear` really does run under `cacheDisplay`. Eleven of the
  /// sixteen grounds register on that probe — measured 2026-08-10 — and no
  /// threshold separates them from the ring, so a live shared engine would make
  /// that assertion depend on which palette the process drew. And an engine
  /// that drew one would write `notaFieldGroundID` into the real defaults
  /// domain, choosing the owner's next launch from a test run.
  func testTheSharedEngineDrawsNothingInATestBundle() {
    XCTAssertTrue(FieldEngine.isUnderTest, "the XCTest detection stopped seeing its own bundle")

    FieldEngine.shared.addViewer()
    XCTAssertNil(
      FieldEngine.shared.image,
      "the shared ground painted a frame under XCTest, so every view test now "
        + "renders over whichever palette this process drew")
    XCTAssertFalse(FieldEngine.shared.isRunning, "a 20 Hz clock is running for the whole suite")
    FieldEngine.shared.tick(dt: 1)
    XCTAssertEqual(FieldEngine.shared.simulation.elapsed, 0, accuracy: 1e-9)
    FieldEngine.shared.removeViewer()
  }

  /// …and an inert engine never touches the key that decides the next launch's
  /// ground. Asserted against the real domain, which is the one at risk.
  func testAnInertEngineNeverWritesTheGroundKey() {
    let before = UserDefaults.standard.string(forKey: FieldEngine.groundDefaultsKey)
    _ = FieldEngine(light: true, drawsFrames: false)
    XCTAssertEqual(before, UserDefaults.standard.string(forKey: FieldEngine.groundDefaultsKey))
  }

  // MARK: - Reading a published frame

  /// One pixel out of a `CGImage`, so the assertion above is about what was
  /// actually published rather than about the buffer behind it.
  private static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
    var bytes = [UInt8](repeating: 0, count: 4)
    let ok: Bool = bytes.withUnsafeMutableBytes { raw -> Bool in
      guard
        let context = CGContext(
          data: raw.baseAddress,
          width: 1,
          height: 1,
          bitsPerComponent: 8,
          bytesPerRow: 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { return false }
      context.interpolationQuality = .none
      // Draw the whole image with the wanted pixel over the 1×1 viewport.
      // CoreGraphics is bottom-up, so the row is counted from the far end.
      context.draw(
        image,
        in: CGRect(
          x: -CGFloat(x),
          y: -CGFloat(image.height - 1 - y),
          width: CGFloat(image.width),
          height: CGFloat(image.height)))
      return true
    }
    guard ok else { return nil }
    return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
  }

  /// The whole image as row-major RGB, in the buffer's own layout, so a
  /// published frame can be compared to the simulation byte for byte.
  ///
  /// Read straight off the image's data provider rather than drawn through a
  /// `CGContext`. Drawing was the first attempt and it is the wrong instrument
  /// for this question twice over: a bitmap context's memory row 0 is the
  /// *bottom* of its coordinate space, so the image comes back row-flipped, and
  /// the draw is free to colour-match on the way. Both turn a byte-for-byte
  /// comparison into a comparison of two different things — which is exactly
  /// what it looked like, with sampled bytes off by 5 to 38 in both directions.
  /// The provider hands back what `FieldImage` actually wrote.
  private static func rgbBytes(of image: CGImage) -> [UInt8] {
    guard
      let data = image.dataProvider?.data,
      let base = CFDataGetBytePtr(data)
    else { return [] }

    let w = image.width, h = image.height
    let stride = image.bytesPerRow
    let step = image.bitsPerPixel / 8
    var out = [UInt8](repeating: 0, count: w * h * 3)
    for y in 0..<h {
      for x in 0..<w {
        let src = y * stride + x * step
        let dst = (y * w + x) * 3
        out[dst] = base[src]
        out[dst + 1] = base[src + 1]
        out[dst + 2] = base[src + 2]
      }
    }
    return out
  }

  // MARK: - The clock is a real clock

  /// **The one test in either suite that waits on a run loop, and it earns it.**
  ///
  /// Every other assertion about the clock reads `isRunning`, which is a
  /// `@Published Bool` assigned next to the `Timer` rather than derived from it
  /// — so deleting `RunLoop.main.add(timer, forMode: .common)`, or emptying the
  /// body of the tick, left the whole suite green while the ground never moved.
  /// That is the exact shape of a test that cannot fail, and the only cure is to
  /// let a scheduled timer actually fire once.
  func testAScheduledTimerReallyMovesTheField() {
    let engine = makeEngine()
    engine.addViewer()
    defer { engine.removeViewer() }

    let moved = expectation(description: "the scheduled clock advanced the field")
    let deadline = Date().addingTimeInterval(2)
    func poll() {
      if engine.simulation.elapsed > 0 {
        moved.fulfill()
      } else if Date() < deadline {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll() }
      }
    }
    poll()

    wait(for: [moved], timeout: 3)
    XCTAssertNotNil(engine.image, "the clock ran but published no frame")
  }

  // MARK: - Nobody is looking

  /// A mounted view is not a visible one. `onDisappear` does not fire for ⌘H, a
  /// minimize, another app's window on top, or another Space — and Nota is a
  /// menu-bar app the owner leaves running all day, so without this the ground
  /// would step, build a `CGImage` and publish it twenty times a second forever
  /// for a surface nobody can see.
  func testTheClockStopsWhileTheAppIsOffScreen() {
    let engine = makeEngine()
    engine.addViewer()
    XCTAssertTrue(engine.isRunning)

    engine.setAppVisible(false)
    XCTAssertFalse(engine.isRunning, "the app went off screen and the ground kept drawing")

    // The field is not restarted, only resumed: the ground the owner comes back
    // to is the one they left, further along.
    let held = engine.simulation.elapsed
    engine.setAppVisible(true)
    XCTAssertTrue(engine.isRunning)
    XCTAssertEqual(engine.simulation.elapsed, held, accuracy: 1e-9)

    engine.removeViewer()
  }

  /// Coming back on screen with nobody mounted must not start a clock — the two
  /// conditions are an `&&`, and an occlusion change is the one edge that could
  /// have been written to ignore the viewer count.
  func testReturningToScreenWithNoViewerStartsNothing() {
    let engine = makeEngine()
    engine.setAppVisible(false)
    engine.setAppVisible(true)
    XCTAssertFalse(engine.isRunning)
  }
}

// MARK: - Driving a role change from a test

/// The role, as something a test can move while the view stays mounted.
///
/// `FieldBackground` handles a role change two ways — `.onChange(of: role)`
/// when the same view is re-evaluated, and the `onAppear`/`onDisappear` pair
/// when SwiftUI swaps one surface for another. This drives the first, which is
/// the one the viewer refcount can get wrong quietly: a swap at least leaves
/// two visible lifecycle callbacks to reason about.
@MainActor
final class GroundRoleBox: ObservableObject {
  @Published var role: GroundRole
  init(_ role: GroundRole) { self.role = role }
}

struct GroundRoleSwitcher: View {
  @ObservedObject var box: GroundRoleBox
  let engine: FieldEngine

  var body: some View {
    FieldBackground(role: box.role, engine: engine)
  }
}
