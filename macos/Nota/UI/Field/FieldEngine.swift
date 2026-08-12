import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// The thing that turns the pure field into a picture on a clock.
///
/// `FieldSimulation` is arithmetic and `FieldImage` is one CoreGraphics call;
/// neither of them knows what time it is or who is looking. This is the half
/// that does, and everything it owes is about **cost** and **breadth** rather
/// than about the look.
///
/// **It is its own object, and only `FieldBackground` observes it.** That is
/// XIA-432's trap written down a second time: the microphone level was a
/// `@Published` property of `LiveMeetingSession`, which `ContentView` *and*
/// `LiveMeetingView` observe, so a 45 Hz feed re-rendered the whole window —
/// toolbar, drawer overlay, every transcript row — forty-five times a second.
/// A ground that redraws twenty times a second is the same publisher on a
/// broader surface: it sits *under* the entire app. So it lives here, held as
/// a `static let` nothing else observes, and the only view with an
/// `@ObservedObject` on it is the one that draws the image. A rate and its
/// observers multiply, and neither number is visible from the line that
/// assigns the value.
///
/// **One ground per launch.** The palette is drawn once, in `init`, excluding
/// whatever the last launch stored — the field morphs continuously and its
/// whole quality is that it never cuts, so a re-roll on a phase change would be
/// the one cut in it. Nothing here re-draws it.
@MainActor
final class FieldEngine: ObservableObject {
  /// The id of the ground the last launch drew, so this one can exclude it.
  /// Two launches in a row on the same palette read as a bug in the draw even
  /// though a uniform draw over sixteen produces one every sixteen launches.
  static let groundDefaultsKey = "notaFieldGroundID"

  /// XIA-446: the launch now draws a **family** rather than a palette, so what
  /// is remembered across launches is the family. A new key rather than a
  /// reused one — the old value is a palette id, and a family lookup would
  /// simply miss it and exclude nothing, which is a silent half-working
  /// exclusion instead of a clean start.
  static let familyDefaultsKey = "notaFieldFamilyID"

  /// 50 ms — twenty frames a second, and deliberately not sixty.
  ///
  /// The field is a 64×36 image blown up across a window: every feature in it
  /// is hundreds of points wide and it moves at a few points a second. There is
  /// nothing in it that a third frame between two others could resolve. Sixty
  /// would triple the main-actor cost (274 µs a step) for a difference nobody
  /// can see on a surface whose entire job is to be ignored.
  static let tickInterval: TimeInterval = 0.05

  /// The longest gap a single step is allowed to represent.
  ///
  /// The tick asks the clock rather than assuming `tickInterval` had really
  /// passed, so a busy main thread does not slow the drift down into a stutter.
  /// The other end of that needs a rail: after a wedged main thread, a sleep, or
  /// a window that was off screen for a minute, the honest `dt` would advect the
  /// whole frame in one step — a jump, which is the one thing this surface may
  /// never do. Past this the field simply loses the time.
  static let maxStep: TimeInterval = 0.25

  /// The one the two production call sites share, so the ground is the same
  /// ground on the home screen and behind a live session, mid-drift, without
  /// either of them owning it.
  ///
  /// **Inert under XCTest**, the way `DictationSettingsStore` backs onto a
  /// private defaults suite there — and for a sharper reason than tidiness.
  /// `RecordingPaneTests.testTheIdlePaneDrawsNoEmber` renders `LiveMeetingView`
  /// and scans the pixels for the recording accent, and its `onAppear` really
  /// does run under `cacheDisplay`, so the shared ground really would be
  /// underneath the pane. Measured 2026-08-10: eleven of the sixteen grounds
  /// register on `RenderProbe.emberPixels`, up to 52,000 pixels of a 600×420
  /// render — and the probe is not wrong, it simply cannot tell the two apart.
  /// The ring is ember stroked at 55–90% over a light ground (closest pixel
  /// ΔE 39.7 from ember) and a warmed ground gets to ΔE 41.3, so no hue,
  /// saturation, lightness or Lab threshold separates them; a ground drawn at
  /// random per launch would have made that assertion a coin flip.
  ///
  /// The ground's own answer to the ember rule is `FieldEngineTests
  /// .testTheGroundNeverComesNearEmber`, which measures the buffer in Lab over
  /// two hours of flow. This keeps the *view* tests looking at the ground they
  /// were written against — `image` stays nil, so `FieldBackground` draws the
  /// wash — instead of at whichever palette the process happened to draw.
  static let shared = FieldEngine(drawsFrames: !FieldEngine.isUnderTest)

  static var isUnderTest: Bool {
    let env = ProcessInfo.processInfo.environment
    return env["XCTestConfigurationFilePath"] != nil
      || env["XCTestBundlePath"] != nil
      || env["XCTestSessionIdentifier"] != nil
  }

  /// The frame to draw. A `CGImage` rather than the `[Float]` buffer, because
  /// everything downstream of here wants a picture and building it twice for
  /// two viewers would be the only reason the buffer had to be public.
  @Published private(set) var image: CGImage?

  /// Whether the clock is running. Published so the refcount is a fact a test
  /// can assert without waiting out a real timer, and so nothing has to reach
  /// for the `Timer` to find out.
  @Published private(set) var isRunning = false

  /// Internal rather than private: the tests drive this directly, and the
  /// engine has no business hiding the thing it is a driver for.
  let simulation: FieldSimulation

  /// False only for `shared` under XCTest — see it. An engine that draws no
  /// frames paints nothing, starts no clock, and steps for nobody; it is not a
  /// slower engine, it is an absent one.
  private let drawsFrames: Bool
  private var viewers = 0

  /// `nonisolated(unsafe)` for one reason: `deinit` is not main-actor isolated
  /// and must still be able to stop this. See `deinit`.
  private nonisolated(unsafe) var timer: Timer?

  private var lastTickAt: TimeInterval?
  private var occlusionObserver: (any NSObjectProtocol)?

  /// Whether the app is on screen at all — **not** whether a view is mounted.
  ///
  /// `onDisappear` does not fire when the window is minimized, hidden with ⌘H,
  /// covered by another app's window, or sitting on another Space, so the
  /// viewer count answers "is this view in the hierarchy", which is a different
  /// question from "can anyone see it". Nota is a menu-bar-resident app the
  /// owner leaves running all day; without this the ground would step, build a
  /// `CGImage` and publish it twenty times a second, forever, for a surface
  /// nobody is looking at. `NSApplication.occlusionState` is one signal that
  /// covers all four cases.
  private(set) var appVisible = true

  /// Internal so a test can drive the occlusion edge without a window server —
  /// the notification is AppKit's and the state it reports is the real screen's.
  func setAppVisible(_ visible: Bool) {
    guard visible != appVisible else { return }
    appVisible = visible
    syncTimer()
  }

  /// The colour scheme, pushed in by the view rather than read from the
  /// environment here: this object outlives every view that draws it and has no
  /// environment of its own. Changing it re-primes the simulation, so the next
  /// frame paints the new band outright instead of advecting a frame built for
  /// the other one — and it is painted immediately, because a Reduce Motion
  /// engine will never tick again and would otherwise hold a light field under
  /// a dark app until the next launch.
  var light: Bool {
    get { simulation.light }
    set {
      guard newValue != simulation.light else { return }
      simulation.light = newValue
      paintOneFrame()
    }
  }

  /// **Reduce Motion is implemented by not calling `step(dt:)`.**
  ///
  /// Not by a slower clock and not by a smaller amplitude: the field either
  /// flows or it is a still photograph, and a ground that creeps is worse for
  /// the owner who asked for less motion than one that holds. The frame that is
  /// already painted stays painted — this is the one accessibility setting that
  /// removes something, so it may not leave the surface blank.
  var reduceMotion: Bool = false {
    didSet {
      guard reduceMotion != oldValue else { return }
      syncTimer()
      if reduceMotion { paintOneFrame() }
    }
  }

  var palette: GroundPalette { simulation.palette }

  /// The chord this launch drew. One per process, still — the *family* is what
  /// the original "one ground per launch" rule now means.
  private(set) var family: GroundFamily = GroundFamily.all[0]

  /// Which view is on screen, and therefore which of the family's three grounds
  /// the field is heading for.
  ///
  /// Pushed in by `FieldBackground` rather than read from anywhere, for the
  /// reason `light` is: this object outlives every view that draws it. Setting
  /// it moves a target; it never repaints, never reprimes and never rebuilds —
  /// see `GroundMorph`.
  ///
  /// **Under Reduce Motion it paints once instead of morphing.** The morph is
  /// advanced by `step`, and a Reduce Motion engine will never step again, so
  /// without this a view switch would leave the previous view's ground on
  /// screen until the next launch.
  var role: GroundRole = .home {
    didSet {
      guard role != oldValue else { return }
      simulation.morph(to: family.palette(for: role), push: role.push)
      if reduceMotion { landMorphAndPaint() }
    }
  }

  /// Reduce Motion's answer to a view switch: arrive, in one frame.
  ///
  /// `step(dt:)` is the only thing that advances a morph, so a dt large enough
  /// to land it is asked for explicitly rather than reaching into the
  /// simulation's private state. `GroundMorph.timeConstant * 12` is far past
  /// the landing tolerance, and `paintOneFrame`'s own `step(dt: 0)` then fills
  /// the buffer with the ground that has arrived.
  private func landMorphAndPaint() {
    guard drawsFrames else { return }
    simulation.step(dt: GroundMorph.timeConstant * 12)
    paintOneFrame()
  }

  // MARK: - Building one

  /// The production initializer: draws the ground, remembers it, and starts
  /// nothing. A `FieldEngine` with no viewers is inert by construction.
  ///
  /// An engine that will not draw frames does not draw a *ground* either, and
  /// does not read or write the defaults key. `notaFieldGroundID` lives in the
  /// real `com.xiafawu.nota` domain, and an unhosted test bundle reaches it —
  /// so a test run that rolled the ground would be deciding what the owner sees
  /// on their next launch, which is precisely the leak
  /// `DictationSettingsStore` is isolated against.
  convenience init(
    defaults: UserDefaults = .standard,
    light: Bool = true,
    drawsFrames: Bool = true
  ) {
    guard drawsFrames else {
      self.init(
        simulation: FieldSimulation(palette: GroundPalette.all[0], light: light),
        drawsFrames: false)
      return
    }
    var generator = SystemRandomNumberGenerator()
    self.init(defaults: defaults, light: light, using: &generator)
  }

  /// The generator is a parameter for the reason `GroundPalette.pick` takes
  /// one: a test can then pin the ground and assert on the draw instead of
  /// hoping.
  convenience init<G: RandomNumberGenerator>(
    defaults: UserDefaults,
    light: Bool,
    using generator: inout G
  ) {
    let last = defaults.string(forKey: FieldEngine.familyDefaultsKey)
    let family = GroundFamily.pick(excluding: last, using: &generator)
    defaults.set(family.id, forKey: FieldEngine.familyDefaultsKey)
    // The engine opens on `home`'s ground rather than on a neutral one and
    // then morphing to it: the home dashboard is what the first frame is
    // almost always under, and a launch that visibly travelled from some other
    // colour to the right one would be the arrival cut with extra steps.
    let role = GroundRole.home
    self.init(
      simulation: FieldSimulation(
        palette: family.palette(for: role), light: light, push: role.push))
    self.family = family
    self.role = role
  }

  /// The injected form, which starts no timer and draws no ground — the tests
  /// hand it a small simulation and call `tick(dt:)` themselves, so no assertion
  /// in this file's suite ever waits on a run loop.
  init(simulation: FieldSimulation, drawsFrames: Bool = true) {
    self.simulation = simulation
    self.drawsFrames = drawsFrames
    if drawsFrames { observeOcclusion() }
  }

  /// A `Timer` scheduled on `RunLoop.main` is retained by the run loop, not by
  /// us — so an engine that is deallocated while its clock is running does not
  /// take the clock with it. The closure holds `self` weakly, which is what
  /// lets the deallocation happen at all and is therefore exactly what makes
  /// this necessary: what is left behind is a 20 Hz run-loop wakeup firing into
  /// a nil `self`, unreachable and with nothing left that could stop it.
  ///
  /// `shared` never deallocates, so this is for the previews, the tests, and
  /// any future per-window engine — the cases where getting it wrong is
  /// invisible rather than loud.
  deinit {
    timer?.invalidate()
    timer = nil
    if let occlusionObserver {
      NotificationCenter.default.removeObserver(occlusionObserver)
    }
  }

  private func observeOcclusion() {
    occlusionObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeOcclusionStateNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.setAppVisible(NSApp?.occlusionState.contains(.visible) ?? true)
      }
    }
  }

  // MARK: - Who is looking

  /// Refcounted rather than a bare `start()`/`stop()` because both production
  /// call sites can be on screen at once (the home ground and the live
  /// session's), and the second one to appear must not restart a clock the
  /// first is already running — nor must the first one to go away stop it.
  ///
  /// The simulation is never rebuilt on either edge: the field survives with
  /// its drift and its warmth intact, so coming back to a screen rejoins the
  /// ground where it got to rather than restarting the session's ground at
  /// minute zero.
  func addViewer() {
    viewers += 1
    // A viewer that arrives to a nil image would draw the fallback wash for a
    // frame, which is a visible cut between two different grounds. Paint first.
    if image == nil { paintOneFrame() }
    syncTimer()
  }

  /// The clamp keeps an unbalanced remove from driving the count negative.
  ///
  /// It is a floor, not a repair, and the difference is worth stating: an
  /// undercount (SwiftUI removing a `_ConditionalContent` branch and re-inserting
  /// the same identity without a second `onAppear`, say) stops the clock while a
  /// viewer is still mounted, and nothing on screen says so — a frozen field is
  /// pixel-indistinguishable from the still one Reduce Motion asks for. An
  /// `assert` here was tried and removed: the scenario is a plausible SwiftUI
  /// lifecycle quirk rather than a programming error, and trapping the app over
  /// a *background* is the wrong trade in every direction.
  ///
  /// What makes the failure survivable instead is `FieldBackground`'s floor —
  /// the wash is always underneath, so the worst case is a ground that stopped
  /// moving, never a hole.
  func removeViewer() {
    viewers = max(0, viewers - 1)
    syncTimer()
  }

  // MARK: - The clock

  /// One step and one image. `dt` is passed in rather than read from a clock so
  /// the tests advance the field by an exact amount.
  func tick(dt: TimeInterval) {
    guard drawsFrames, !reduceMotion else { return }
    simulation.step(dt: fieldClamp(dt, 0, FieldEngine.maxStep))
    image = FieldImage.makeImage(from: simulation)
  }

  /// Paint what the field is *now*, with no time passing.
  ///
  /// `step(dt: 0)` rather than a separate render path, because `step` is the
  /// simulation's only mutator and a second way to fill the buffer would be a
  /// second thing to keep in step with it. At zero the advection and the seed
  /// motion are no-ops and `elapsed` does not move, so this is safe to call
  /// under Reduce Motion — which is exactly where it is needed.
  private func paintOneFrame() {
    guard drawsFrames else { return }
    simulation.step(dt: 0)
    image = FieldImage.makeImage(from: simulation)
  }

  private func syncTimer() {
    let shouldRun = drawsFrames && viewers > 0 && !reduceMotion && appVisible
    if shouldRun {
      guard timer == nil else { return }
      lastTickAt = ProcessInfo.processInfo.systemUptime
      let timer = Timer.scheduledTimer(
        withTimeInterval: FieldEngine.tickInterval, repeats: true
      ) { _ in
        Task { @MainActor [weak self] in self?.tickFromClock() }
      }
      // The ground is the least urgent thing on screen; letting the kernel
      // coalesce these with whatever else is waking the run loop is free.
      timer.tolerance = FieldEngine.tickInterval / 4
      RunLoop.main.add(timer, forMode: .common)
      self.timer = timer
      isRunning = true
    } else {
      timer?.invalidate()
      timer = nil
      lastTickAt = nil
      isRunning = false
    }
  }

  private func tickFromClock() {
    let now = ProcessInfo.processInfo.systemUptime
    let dt = now - (lastTickAt ?? now - FieldEngine.tickInterval)
    lastTickAt = now
    tick(dt: dt)
  }
}
