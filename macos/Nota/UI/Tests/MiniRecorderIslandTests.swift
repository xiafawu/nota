import AppKit
import SwiftUI
import XCTest

@testable import Nota

/// The mini-recorder island's promises (XIA-434), asserted against the pure
/// types the views and the panel read — the split `SessionTimerMetrics`,
/// `HUDPillMetrics` and `DictationReviewPresenting` already established.
///
/// The hosting-view cases are here for the one class of claim a constant cannot
/// carry: "the card never resizes" and "there is no ember on a closed
/// microphone" are facts about what got laid out and what got drawn.
///
/// `MiniRecorderIslandController` **is** driven end to end here, through the
/// `IslandSource` / `IslandVerbs` seam. It used to take a `NotaModel` — whose
/// `init` sweeps the real `~/.nota` and runs preflight, so no test in this
/// bundle can build one — and the review found the consequence: swapping the
/// `.stop` and `.show` bodies of `perform(_:)` left every test in this file
/// green, i.e. the island's red capsule could have brought Nota forward while
/// the session kept recording and nothing would have said so.
@MainActor
final class MiniRecorderIslandTests: XCTestCase {
  // MARK: - The visibility rule

  /// The headline rule: up only while a session runs AND Nota is not frontmost.
  func testTheIslandIsUpOnlyWhileASessionRunsAndNotaIsNotFrontmost() {
    XCTAssertEqual(
      MiniIslandVisibility.phase(
        MiniIslandInputs(sessionState: .recording, appIsFrontmost: false, now: 100)
      ),
      .recording
    )
    XCTAssertNil(
      MiniIslandVisibility.phase(
        MiniIslandInputs(sessionState: .idle, appIsFrontmost: false, now: 100)
      ),
      "no session is running, so there is nothing to be an indicator of"
    )
    XCTAssertNil(
      MiniIslandVisibility.phase(
        MiniIslandInputs(sessionState: .recording, appIsFrontmost: true, now: 100)
      ),
      "Nota is in front and its own window says this better"
    )
  }

  /// …and the frontmost check is FIRST, so it applies to every phase. Two live
  /// indicators for one microphone is the mistake `isReviewing` already taught
  /// this codebase, and a failure card floating over the window that is already
  /// showing the failure banner is the same mistake in a louder colour.
  func testBringingNotaForwardDismissesTheIslandInEveryPhase() {
    let cases: [(String, MiniIslandInputs)] = [
      ("recording", MiniIslandInputs(sessionState: .recording, now: 100)),
      (
        "mark confirmation",
        MiniIslandInputs(
          sessionState: .recording,
          mark: MiniIslandMark(at: 12, ordinal: 1, pressedAt: 100),
          now: 100.5
        )
      ),
      ("handoff", MiniIslandInputs(sessionState: .idle, handoffStartedAt: 100, now: 101)),
      ("failure", MiniIslandInputs(sessionState: .failed("Connection lost"), now: 100)),
    ]
    for (name, inputs) in cases {
      var away = inputs
      away.appIsFrontmost = false
      XCTAssertNotNil(MiniIslandVisibility.phase(away), "\(name) should be up while Nota is away")

      var forward = inputs
      forward.appIsFrontmost = true
      XCTAssertNil(
        MiniIslandVisibility.phase(forward),
        "\(name) survived Nota coming forward"
      )
    }
  }

  /// The ember means the microphone is open and nothing else. `.stopping` keeps
  /// the tap installed while every buffer is dropped, which is exactly the lie
  /// `LiveMeetingSession.meterFollowsMicrophone` exists to refuse — so the island
  /// asks that one predicate rather than a second list of states.
  func testTheIslandShowsNoEmberOnceTheMicrophoneStopsBeingKept() {
    XCTAssertTrue(
      MiniIslandVisibility.phase(MiniIslandInputs(sessionState: .recording, now: 1))?.showsEmber
        == true
    )
    XCTAssertNil(
      MiniIslandVisibility.phase(MiniIslandInputs(sessionState: .stopping, now: 1)),
      "a stopping session's audio is not being kept, so it draws no island at all"
    )
    for phase in [
      MiniIslandPhase.handoff(secondsAgo: 2),
      MiniIslandPhase.failure("Connection lost"),
    ] {
      XCTAssertFalse(phase.showsEmber, "\(phase) draws the ember over a closed microphone")
      XCTAssertFalse(phase.showsClock, "\(phase) draws a clock that has stopped meaning anything")
    }
  }

  /// A ⌘K replaces the controls, and only for as long as it says it does.
  func testAMarkConfirmationReplacesTheControlsAndThenExpires() {
    let inputs = MiniIslandInputs(
      sessionState: .recording,
      mark: MiniIslandMark(at: 1720, ordinal: 3, pressedAt: 100),
      now: 100.5
    )
    guard let phase = MiniIslandVisibility.phase(inputs) else {
      return XCTFail("no island during a mark confirmation")
    }
    XCTAssertEqual(phase, .markConfirmed(time: "28:40", ordinal: "3rd", landed: true))
    XCTAssertEqual(phase.message, "Marked 28:40 · 3rd")
    XCTAssertEqual(phase.actions, [], "the confirmation REPLACES the controls")
    // What it does not do is change what the card is otherwise saying: the
    // microphone did not stop being open while the island congratulated itself.
    XCTAssertTrue(phase.showsEmber)
    XCTAssertTrue(phase.showsClock)

    var later = inputs
    later.now = 100 + MiniIslandVisibility.markConfirmationDuration
    XCTAssertEqual(MiniIslandVisibility.phase(later), .recording)
  }

  /// The handoff names its own age and then goes away by itself — the menu
  /// bar's warm slot carries the rest of the work.
  func testTheHandoffNamesItsAgeAndThenGoesAway() {
    var inputs = MiniIslandInputs(sessionState: .idle, handoffStartedAt: 100, now: 103)
    XCTAssertEqual(MiniIslandVisibility.phase(inputs), .handoff(secondsAgo: 3))
    XCTAssertEqual(MiniIslandVisibility.phase(inputs)?.message, "Transcribing… 3s ago")
    XCTAssertEqual(MiniIslandVisibility.phase(inputs)?.actions, [.show])

    inputs.now = 100
    XCTAssertEqual(MiniIslandVisibility.phase(inputs)?.message, "Transcribing… just now")

    inputs.now = 100 + MiniIslandVisibility.handoffWindow
    XCTAssertNil(MiniIslandVisibility.phase(inputs), "the handoff notice outstayed its window")
  }

  /// Stopping a FAILED session (Save Transcript) is a real path, and for those
  /// seconds the record is being sealed — which is what the owner just asked
  /// for, not the failure they already read.
  func testAHandoffOutranksTheFailureItLeavesBehind() {
    let inputs = MiniIslandInputs(
      sessionState: .failed("Connection lost"),
      handoffStartedAt: 100,
      now: 101
    )
    XCTAssertEqual(MiniIslandVisibility.phase(inputs), .handoff(secondsAgo: 1))

    var stale = inputs
    stale.now = 100 + MiniIslandVisibility.handoffWindow + 1
    XCTAssertEqual(MiniIslandVisibility.phase(stale), .failure("Connection lost"))
  }

  /// A red card that said only "Connection lost" reads as a session thrown
  /// away. Nothing in Nota deletes a recording on a failure path (XIA-430 /
  /// XIA-436), so the card says so.
  func testAFailureSaysTheAudioIsBeingSaved() {
    let phase = MiniIslandPhase.failure("Connection lost")
    XCTAssertEqual(phase.message, "Connection lost — audio saving")
    // Never doubled, and never empty.
    XCTAssertEqual(
      MiniIslandCopy.failure("Connection lost — audio saving"),
      "Connection lost — audio saving"
    )
    XCTAssertEqual(MiniIslandCopy.failure("   "), "Recording failed — audio saving")
  }

  /// **Try Again is not the only way out, and it is not the first one.**
  ///
  /// A failed session keeps everything it heard, and the route to that
  /// transcript is the window's banner (Save Transcript). Try Again settles the
  /// leftover record through `LiveSessionOwner.start`, which writes a
  /// `failed(stage:)` status and seals nothing — so a card offering it alone
  /// hands the owner one button that throws away the whole meeting's realtime
  /// transcript, directly under copy telling them things are being kept.
  func testTheFailureCardOffersTheWindowBeforeItOffersAFreshStart() {
    XCTAssertEqual(MiniIslandPhase.failure("Connection lost").actions, [.show, .retry])
  }

  /// The message comes off `SessionState.failed(_:)` — whatever the realtime
  /// path had to say, which can quote a server payload or a recognized turn.
  /// Clamping it in the **copy** rather than in the view is what makes "no
  /// transcript, ever" a fact about the type: a view truncation hides it on
  /// screen and still lets the type carry it.
  func testAFailureMessageIsClampedBeforeItCanBecomeASentenceSomebodySpoke() {
    let spoken = String(repeating: "so anyway what I was saying about the migration ", count: 12)
    let drawn = MiniIslandPhase.failure(spoken).message ?? ""
    XCTAssertLessThanOrEqual(
      drawn.count,
      MiniIslandCopy.failureMessageLimit + MiniIslandCopy.audioSavingClause.count + 4
    )
    XCTAssertTrue(drawn.hasSuffix("— \(MiniIslandCopy.audioSavingClause)"))
    // A newline would otherwise let a forged second line onto a one-line card.
    XCTAssertFalse(MiniIslandCopy.failure("one\ntwo").contains("\n"))
  }

  /// Which control does what is exactly the thing that shipped wrong on the
  /// capsule cluster, so it is a table a test reads rather than closures a
  /// rendered window would have to be driven to discover.
  func testEachPhaseOffersExactlyTheActionsItCanRun() {
    XCTAssertEqual(MiniIslandPhase.recording.actions, [.mark, .pause, .stop])
    XCTAssertEqual(
      MiniIslandPhase.markConfirmed(time: "00:01", ordinal: "1st", landed: true).actions,
      []
    )
    // Paused (XIA-447): Resume and Stop, and Mark GONE rather than disabled —
    // the same reasoning the confirmation's empty list has, plus the one
    // `NotaModel.markCurrentMoment` enforces (it refuses a paused session, so a
    // Mark capsule here would do nothing at all).
    XCTAssertEqual(MiniIslandPhase.paused.actions, [.resume, .stop])
    XCTAssertFalse(MiniIslandPhase.paused.actions.contains(.mark))
    XCTAssertEqual(MiniIslandPhase.handoff(secondsAgo: 0).actions, [.show])
    XCTAssertEqual(MiniIslandPhase.failure("x").actions, [.show, .retry])
    // Stop is never offered by a phase with no session left, and Mark never is
    // either: a moment flagged into a session whose audio is not being kept is
    // a timestamp pointing at nothing. A pause is deliberately not in this
    // list — the session is still there, and Stop is terminal from it too.
    for phase in [
      MiniIslandPhase.handoff(secondsAgo: 0),
      MiniIslandPhase.failure("x"),
    ] {
      XCTAssertFalse(phase.actions.contains(.mark))
      XCTAssertFalse(phase.actions.contains(.stop))
      XCTAssertFalse(phase.actions.contains(.pause))
      XCTAssertFalse(phase.actions.contains(.resume))
    }
  }

  /// ⌘K is the only shortcut any of these verbs claims — a nonactivating
  /// surface that took Escape or Return would be taking keys off the app the
  /// owner is actually working in. It is spent by the **menu bar's** row: the
  /// island panel never becomes key, so a shortcut on one of its capsules could
  /// never fire.
  func testMarkIsTheOnlySessionActionCarryingAShortcut() {
    for action in MiniIslandAction.allCases {
      if action == .mark {
        XCTAssertEqual(action.shortcut, KeyboardShortcut("k", modifiers: .command))
      } else {
        XCTAssertNil(action.shortcut, "\(action) claims a key the target app should keep")
      }
    }
  }

  func testTheOrdinalOfAMomentReadsAsEnglish() {
    let expected = [
      1: "1st", 2: "2nd", 3: "3rd", 4: "4th",
      11: "11th", 12: "12th", 13: "13th",
      21: "21st", 22: "22nd", 23: "23rd", 111: "111th",
    ]
    for (n, text) in expected {
      XCTAssertEqual(MiniIslandCopy.ordinal(n), text)
    }
  }

  /// One clock. The gutter timestamp, the cluster's clock, the island's and the
  /// menu bar's all name the same instant, and two implementations of that is a
  /// disagreement waiting for a rounding change.
  func testTheIslandsClockIsTheOneClock() {
    for elapsed in [0.0, 59.4, 3599.0, 3600.0, 4360.0] {
      XCTAssertEqual(
        LiveMeetingFormat.duration(elapsed),
        SessionTimerMetrics.text(elapsed: elapsed)
      )
    }
    // And the mark confirmation quotes it rather than formatting its own.
    let phase = MiniIslandVisibility.phase(
      MiniIslandInputs(
        sessionState: .recording,
        mark: MiniIslandMark(at: 4360, ordinal: 1, pressedAt: 0),
        now: 0.1
      )
    )
    XCTAssertEqual(phase?.message, "Marked \(SessionTimerMetrics.text(elapsed: 4360)) · 1st")
  }

  /// The island reports on a session; it never quotes one. No phase carries a
  /// segment, a partial, or anything else the recognizer produced — which is
  /// what makes "NO TRANSCRIPT, EVER" a fact about the type.
  func testNoPhaseCanCarryTranscript() {
    let phases: [MiniIslandPhase] = [
      .recording,
      .markConfirmed(time: "28:40", ordinal: "3rd", landed: true),
      .markConfirmed(time: "28:40", ordinal: "3rd", landed: false),
      .paused,
      .handoff(secondsAgo: 3),
      .failure("Connection lost"),
      // The one input that is not ours: whatever the realtime path had to say.
      // The bound has to hold for a message that IS something a speaker said,
      // or this test is asserting a property of its own fixture.
      .failure(String(repeating: "and then the client asked us to ship it early ", count: 12)),
    ]
    for phase in phases {
      for string in MiniIslandCopy.all(phase) {
        XCTAssertLessThanOrEqual(
          string.count,
          64,
          "\(string) is long enough to be something a speaker said"
        )
      }
    }
  }

  // MARK: - Geometry

  /// Derived from what the card holds, never typed beside it. This is the check
  /// XIA-444 owed and did not have: `controlRowHeight` was written as 40
  /// against a row that laid out at 41, and every geometry test stayed green.
  func testTheIslandHeightIsDerivedFromTheTallestThingItHolds() {
    let glyph = ("0" as NSString)
      .size(withAttributes: [.font: MiniIslandMetrics.actionMeasuringFont])
      .height
    let message = ("0" as NSString)
      .size(withAttributes: [.font: MiniIslandMetrics.messageMeasuringFont])
      .height
    XCTAssertEqual(
      MiniIslandMetrics.contentHeight,
      max(
        SessionTimerMetrics.plateHeight(base: MiniIslandMetrics.clockBase),
        MiniIslandMetrics.meterVariant.maxBarHeight,
        MiniIslandMetrics.dotDiameter,
        MiniIslandMetrics.actionHeight,
        glyph.rounded(.up),
        message.rounded(.up)
      )
    )
    XCTAssertEqual(
      MiniIslandMetrics.cardHeight,
      MiniIslandMetrics.contentHeight + 2 * MiniIslandMetrics.paddingV
    )
    // ~320×44 is the shape asked for; the height is derived, so this is the
    // sanity band rather than the definition.
    XCTAssertEqual(MiniIslandMetrics.cardWidth, 320)
    XCTAssertGreaterThanOrEqual(MiniIslandMetrics.cardHeight, 40)
    XCTAssertLessThanOrEqual(MiniIslandMetrics.cardHeight, 52)
  }

  /// **The card is one size in every phase.** It is up while the owner is
  /// looking at another app, so a surface that resized when a message arrived
  /// would be movement at the edge of vision carrying no information — and the
  /// stored position is a top-left, which is exact only because nothing grows.
  func testTheIslandIsTheSameSizeInEveryPhase() {
    let reserved = MiniIslandMetrics.cardSize
    for phase in Self.everyPhase {
      let size = Self.laidOutCardSize(phase)
      XCTAssertEqual(
        size.width,
        reserved.width,
        accuracy: 0.5,
        "\(phase) draws \(size.width)pt wide against a card of \(reserved.width)pt"
      )
      XCTAssertEqual(
        size.height,
        reserved.height,
        accuracy: 0.5,
        "\(phase) draws \(size.height)pt tall against a card of \(reserved.height)pt"
      )
    }
  }

  /// The ember is a colour with one meaning, and "there is no ember on screen"
  /// is not a claim a constant can carry — the same probe
  /// `testTheIdlePaneDrawsNoEmber` runs on the recording pane.
  func testOnlyTheLiveMicrophonePhasesDrawEmberPixels() {
    // Positive control first: without it a blank canvas would pass the negative.
    XCTAssertTrue(
      Self.drawsEmber(.recording),
      "the probe cannot see the ember it is looking for"
    )
    XCTAssertFalse(
      Self.drawsEmber(.handoff(secondsAgo: 2)),
      "the handoff card draws the ember over a microphone that is closed"
    )
    XCTAssertFalse(
      Self.drawsEmber(.failure("Connection lost")),
      "the failure card draws the ember over a microphone that is closed"
    )
    // XIA-447: a paused session is still a session, and the card stays up and
    // keeps its clock — but the microphone is closed, so the dot and the meter
    // go with it.
    XCTAssertFalse(
      Self.drawsEmber(.paused),
      "the paused card draws the ember over a microphone that is closed"
    )
  }

  // MARK: - The panel

  /// The trap that merely inconveniences the HUD makes THIS surface useless:
  /// `isFloatingPanel = true` silently rewrites `level` to `.floating`
  /// (CGWindowLayer 3), which sits below a fullscreen app — and the island
  /// exists to float over a fullscreen video call.
  func testTheIslandPanelSitsAboveAFullscreenApp() {
    let panel = MiniRecorderPanel(model: MiniIslandModel())
    XCTAssertTrue(panel.isFloatingPanel)
    XCTAssertEqual(
      panel.level,
      .statusBar,
      "`level` was assigned before `isFloatingPanel`, which silently rewrote it"
    )
    XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.floating.rawValue)
  }

  /// The rest of the inheritance, in one place.
  func testTheIslandPanelInheritsWhatEveryFloatingSurfaceOwes() {
    let panel = MiniRecorderPanel(model: MiniIslandModel())
    XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    XCTAssertTrue(panel.styleMask.contains(.borderless))
    XCTAssertEqual(
      panel.appearance?.name,
      .darkAqua,
      "a SwiftUI .colorScheme does not change an NSWindow's effectiveAppearance"
    )
    // AppKit Liquid Glass, not SwiftUI's: `.glassEffect` inside a transparent
    // panel refracts only its own hierarchy and reads as a flat blur.
    XCTAssertTrue(
      panel.contentView is GlassBackingView,
      "the island is not on an NSGlassEffectView plate"
    )
    // Never typed into, so unlike the review card it never takes the keyboard
    // away from the app the owner is working in.
    XCTAssertFalse(panel.canBecomeKey)
    XCTAssertFalse(panel.canBecomeMain)
    XCTAssertFalse(panel.isOpaque)
    XCTAssertFalse(panel.hasShadow)
    XCTAssertFalse(panel.isReleasedWhenClosed)
    XCTAssertFalse(panel.ignoresMouseEvents, "the island has buttons")
    XCTAssertFalse(panel.isMovableByWindowBackground, "one mover per frame")
  }

  /// `orderFrontRegardless()` has silently produced no window before
  /// (`windowNumber == 0` for a day). One recreate, then a **visible** failure —
  /// never a silent no-op.
  func testTheIslandIsCheckedOntoTheScreenAndRecreatedExactlyOnce() {
    var built: [FakeIslandWindow] = []
    let presenter = MiniRecorderPresenter { _ in
      let window = FakeIslandWindow(succeeds: built.isEmpty ? false : true)
      built.append(window)
      return window
    }

    XCTAssertTrue(presenter.show(MiniIslandRender(phase: .recording), perform: { _ in }))
    XCTAssertEqual(built.count, 2, "a dead window was not replaced exactly once")
    XCTAssertTrue(built[0].dismissed, "the dead window was left on the presenter")
    XCTAssertTrue(presenter.isPresenting)
  }

  func testASecondFailureIsReportedRatherThanSwallowed() {
    var built = 0
    let presenter = MiniRecorderPresenter { _ in
      built += 1
      return FakeIslandWindow(succeeds: false)
    }
    XCTAssertFalse(presenter.show(MiniIslandRender(phase: .recording), perform: { _ in }))
    XCTAssertEqual(built, 2, "it recreated more than once, or not at all")
    XCTAssertFalse(presenter.isPresenting)
  }

  /// Every mutator is a no-op when nothing is up — the shape
  /// `DictationReviewPresenting` established.
  func testThePresenterDoesNothingWhenNoIslandIsUp() {
    let presenter = MiniRecorderPresenter { _ in FakeIslandWindow(succeeds: false) }
    presenter.update(MiniIslandRender(phase: .failure("x")))
    XCTAssertEqual(presenter.model.phase, .recording, "an update landed with no island up")
    presenter.dismiss()
    XCTAssertFalse(presenter.isPresenting)
  }

  // MARK: - Position

  /// **Its own store.** The HUD pins a pill's bottom-center and the review card
  /// a top-left; one shared point would mean dragging either surface moved the
  /// other through an anchor that means nothing on the far side.
  func testTheIslandKeepsItsOwnPositionApartFromTheOtherTwoSurfaces() {
    // The **symbols**, not copies of their strings: an inequality against a
    // transcribed literal survives a rename of the thing it is guarding, and
    // would go on passing after the island adopted the HUD's new key.
    XCTAssertNotEqual(IslandPositionStore.key, ReviewPositionStore.key)
    XCTAssertNotEqual(IslandPositionStore.key, HUDPositionStore.key)

    IslandPositionStore.clear()
    XCTAssertNil(IslandPositionStore.load())
    IslandPositionStore.save(CGPoint(x: 120, y: 400))
    XCTAssertEqual(IslandPositionStore.load(), CGPoint(x: 120, y: 400))
    // A point that is not a number never reaches the window server.
    IslandPositionStore.save(CGPoint(x: CGFloat.nan, y: 400))
    XCTAssertEqual(IslandPositionStore.load(), CGPoint(x: 120, y: 400))
    IslandPositionStore.clear()
  }

  /// Validate rather than trust: a point no current screen can host is DROPPED,
  /// and the automatic placement is the self-heal. Clamping it onto whatever
  /// display is left would call an arbitrary point the owner's choice.
  func testAPinnedPositionNoScreenCanHoldIsDroppedAndOneItCanIsClamped() {
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let card = MiniIslandMetrics.cardSize

    XCTAssertNil(
      IslandPanelLayout.validatedTopLeft(
        CGPoint(x: 3000, y: 3000),
        cardSize: card,
        visibleFrames: [screen]
      )
    )
    guard let clamped = IslandPanelLayout.validatedTopLeft(
      CGPoint(x: 1430, y: 890),
      cardSize: card,
      visibleFrames: [screen]
    ) else {
      return XCTFail("a point the screen holds was dropped")
    }
    XCTAssertLessThanOrEqual(clamped.x + card.width, screen.maxX - IslandPanelLayout.screenInset)
    XCTAssertGreaterThanOrEqual(clamped.y - card.height, screen.minY)
    // The default placement puts the whole card on the screen too, clear of the
    // Dock — the last few points of a screen read as half off it.
    let resting = IslandPanelLayout.defaultTopLeft(cardSize: card, visible: screen)
    XCTAssertGreaterThanOrEqual(
      resting.y - card.height,
      screen.minY + IslandPanelLayout.screenInset
    )
    XCTAssertLessThanOrEqual(resting.x + card.width, screen.maxX)
  }

  /// The card is **placed** before it is ordered on, or the first frame appears
  /// wherever AppKit last left the window and then jumps.
  func testTheCardIsPlacedBeforeItIsOrderedOn() {
    var built: [FakeIslandWindow] = []
    let presenter = MiniRecorderPresenter { _ in
      let window = FakeIslandWindow(succeeds: true)
      built.append(window)
      return window
    }
    XCTAssertTrue(presenter.show(MiniIslandRender(phase: .recording), perform: { _ in }))
    XCTAssertEqual(built.first?.repositionedBeforePresent, true)
  }

  /// The presenter's glass settings reach the window it builds, and a recreate
  /// re-applies them rather than handing the owner a default-tinted card.
  func testGlassSettingsReachEveryWindowThePresenterBuilds() {
    var built: [FakeIslandWindow] = []
    let presenter = MiniRecorderPresenter { _ in
      let window = FakeIslandWindow(succeeds: built.count == 1)
      built.append(window)
      return window
    }
    presenter.glassTintAlpha = 1.5  // out of range on purpose
    presenter.glassMaterial = .clear
    XCTAssertTrue(presenter.show(MiniIslandRender(phase: .recording), perform: { _ in }))
    XCTAssertEqual(built.count, 2)
    for window in built {
      XCTAssertEqual(window.glassTintAlpha, GlassTint.range.upperBound, "a stored number went to the window server unclamped")
      XCTAssertEqual(window.glassMaterial, .clear)
    }
  }

  /// The whole round trip, on the real panel: drag, store, relaunch, restore.
  /// The pure `IslandPanelLayout` functions were tested and the code that calls
  /// them was not — so a `dragEnded` measuring the **window** frame instead of
  /// the card rect would walk the island 24pt up-left on every launch with
  /// nothing to say so.
  func testADraggedIslandComesBackWhereItWasLeft() throws {
    let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
    IslandPositionStore.clear()
    defer { IslandPositionStore.clear() }

    let panel = MiniRecorderPanel(model: MiniIslandModel())
    let margin = MiniIslandMetrics.shadowMargin
    let card = MiniIslandMetrics.cardSize
    // Somewhere unambiguous on the current screen, expressed as a window origin.
    let origin = NSPoint(x: visible.minX + 200, y: visible.minY + 200)

    panel.dragChanged()  // takes the anchor
    panel.setFrameOrigin(origin)
    panel.dragEnded()

    let expected = CGPoint(x: origin.x + margin, y: origin.y + margin + card.height)
    XCTAssertEqual(panel.pinnedCardTopLeft?.x ?? .nan, expected.x, accuracy: 0.5)
    XCTAssertEqual(panel.pinnedCardTopLeft?.y ?? .nan, expected.y, accuracy: 0.5)
    XCTAssertEqual(IslandPositionStore.load()?.x ?? .nan, expected.x, accuracy: 0.5)

    // A fresh panel — the next launch — lands the CARD's top-left back there.
    let relaunched = MiniRecorderPanel(model: MiniIslandModel())
    relaunched.reposition()
    let restoredCard = relaunched.frame.insetBy(dx: margin, dy: margin)
    XCTAssertEqual(restoredCard.minX, expected.x, accuracy: 0.5)
    XCTAssertEqual(restoredCard.maxY, expected.y, accuracy: 0.5)
  }

  // MARK: - The menu bar

  /// The bar's width is elastic and the hour form has to use it. Asserting the
  /// string alone cannot see a `.frame(width:)` or a dropped `lineLimit`
  /// clipping "1:12:40" to "1:12:…" in the status item.
  func testTheMenuBarLabelGrowsForTheHourFormRatherThanClippingIt() throws {
    let minutes = try XCTUnwrap(MenuBarSessionPresence.make(state: .recording, elapsed: 461))
    let hours = try XCTUnwrap(MenuBarSessionPresence.make(state: .recording, elapsed: 4360))
    let short = Self.fittingWidth(MenuBarPresenceLabel(presence: minutes))
    let long = Self.fittingWidth(MenuBarPresenceLabel(presence: hours))
    XCTAssertGreaterThan(short, 0)
    XCTAssertGreaterThan(long, short, "the hour form was clipped into the minute form's width")
    // …and the width is enough for the string itself, not a lane it truncates
    // into: the bar is elastic, so there is no excuse for a cut.
    let ideal = (hours.elapsed as NSString)
      .size(withAttributes: [.font: NSFont.preferredFont(forTextStyle: .caption1)])
      .width
    XCTAssertGreaterThanOrEqual(long, ideal)
  }

  func testTheMenuBarNamesWhatItIsShowingToVoiceOver() {
    XCTAssertEqual(
      MenuBarSessionPresence.make(state: .recording, elapsed: 461)?.accessibilityLabel,
      "Nota: recording, 07:41"
    )
    XCTAssertEqual(
      MenuBarSessionPresence.make(state: .stopping, elapsed: 461)?.accessibilityLabel,
      "Nota: session stopped, 07:41"
    )
  }

  func testTheMenuBarDotIsEmberOnlyWhileTheMicrophoneIsOpen() {
    XCTAssertEqual(
      MenuBarSessionPresence.make(state: .recording, elapsed: 12)?.isEmber,
      true
    )
    XCTAssertEqual(
      MenuBarSessionPresence.make(state: .stopping, elapsed: 12)?.isEmber,
      false,
      "a stopping session's audio is not being kept, so the dot may not be ember"
    )
    XCTAssertEqual(
      MenuBarSessionPresence.make(state: .failed("x"), elapsed: 12)?.isEmber,
      false
    )
    // …and a paused one is not ember either, but it is not "stopped": the item
    // says the word, which a grey dot beside a still clock cannot (XIA-447).
    let paused = MenuBarSessionPresence.make(state: .paused, elapsed: 12)
    XCTAssertEqual(paused?.isEmber, false)
    XCTAssertEqual(paused?.isPaused, true)
    XCTAssertEqual(
      MenuBarSessionPresence.make(state: .stopping, elapsed: 12)?.isPaused,
      false,
      "a stopping session is not a paused one — one is over and the other is waiting"
    )
  }

  /// The elapsed time is IN THE BAR, and past the hour it reads in hours —
  /// through the one clock, so the bar cannot disagree with the window.
  func testTheMenuBarCarriesTheElapsedTimeAndReadsInHoursPastTheHour() {
    XCTAssertEqual(MenuBarSessionPresence.make(state: .recording, elapsed: 461)?.elapsed, "07:41")
    XCTAssertEqual(
      MenuBarSessionPresence.make(state: .recording, elapsed: 4360)?.elapsed,
      "1:12:40"
    )
    XCTAssertEqual(
      MenuBarSessionPresence.make(state: .recording, elapsed: 4360)?.elapsed,
      SessionTimerMetrics.text(elapsed: 4360)
    )
  }

  func testTheMenuBarSaysNothingAboutASessionThatIsNotThere() {
    XCTAssertNil(MenuBarSessionPresence.make(state: .idle, elapsed: 0))
    XCTAssertFalse(SessionMenuRows.showsStatus(state: .idle))
    XCTAssertEqual(SessionMenuRows.rows(state: .idle), [])
  }

  /// The two verbs are offered only while a microphone is open. A failed
  /// session's decisions (Save Transcript / Try Again / Discard) belong to the
  /// window, where the transcript they are about is.
  func testTheMenuOffersMarkAndStopOnlyWhileASessionIsLive() {
    XCTAssertEqual(SessionMenuRows.rows(state: .recording), [.mark, .pause, .stop])
    XCTAssertEqual(SessionMenuRows.rows(state: .stopping), [])
    XCTAssertEqual(SessionMenuRows.rows(state: .failed("x")), [])
    // A paused session is live, so it keeps rows — Resume and Stop (XIA-447).
    // It is the one state where `meterFollowsMicrophone` is the wrong question
    // here: the microphone is closed and the session is not.
    XCTAssertEqual(SessionMenuRows.rows(state: .paused), [.resume, .stop])
    XCTAssertTrue(SessionMenuRows.showsStatus(state: .failed("x")))
    // And each row runs the island's verb, so one press of ⌘K means one thing
    // wherever it is pressed.
    XCTAssertEqual(SessionMenuRow.mark.action, .mark)
    XCTAssertEqual(SessionMenuRow.stop.action, .stop)
    XCTAssertEqual(MenuBarSessionCopy.markTitle, "Mark this moment")
    XCTAssertEqual(MenuBarSessionCopy.stopTitle, "Stop & summarize")
    XCTAssertEqual(
      MenuBarSessionCopy.status(state: .recording, elapsed: 461),
      "Recording · 07:41"
    )
  }

  /// **The other half of the derivation.** `testTheIslandHeightIsDerivedFrom…`
  /// recomputes the same `max(...)` over the same constants — a constant
  /// compared against itself — and `testTheIslandIsTheSameSizeInEveryPhase`
  /// measures a body that is hard-`.frame`d to those constants, so it reports
  /// the reservation whatever is inside it. Measured during the review: giving
  /// `IslandActionButtonStyle` a 78pt height inside a 50pt card left all 26
  /// tests green. This is the `testEveryCapsuleDrawsExactlyTheHeightTheCluster
  /// Reserves` twin: every piece is laid out, and the tallest is the number.
  func testEveryPieceDrawsInsideTheHeightTheCardReserves() {
    var drawn: [(String, CGFloat)] = []

    for action in MiniIslandAction.allCases {
      let button = Button {} label: { Image(systemName: action.symbol) }
        .buttonStyle(IslandActionButtonStyle(tint: action.tint))
      drawn.append(("\(action) capsule", Self.fittingHeight(button)))
    }
    drawn.append(("clock", Self.fittingHeight(SessionTimer(elapsed: 4360, base: MiniIslandMetrics.clockBase))))
    drawn.append(
      (
        "meter",
        Self.fittingHeight(
          SessionMeterFeedView(feed: MicLevelFeed(level: 0.9), variant: MiniIslandMetrics.meterVariant)
        )
      )
    )
    drawn.append(
      (
        "message",
        Self.fittingHeight(
          Text(MiniIslandCopy.marked(time: "28:40", ordinal: "3rd"))
            .font(MiniIslandMetrics.messageFont)
            .lineLimit(1)
        )
      )
    )

    for (name, height) in drawn {
      XCTAssertLessThanOrEqual(
        height,
        MiniIslandMetrics.contentHeight + 0.5,
        "the \(name) draws \(height)pt inside a card reserving \(MiniIslandMetrics.contentHeight)pt"
      )
    }
    let tallest = drawn.map(\.1).max() ?? 0
    XCTAssertEqual(
      tallest,
      MiniIslandMetrics.contentHeight,
      accuracy: 0.5,
      "the reservation is larger than anything in the card, so it is not derived from it"
    )
  }

  // MARK: - The controller

  /// **Which control does what.** The recording cluster shipped with the
  /// Mark-looking capsule opening the marker list, and
  /// `testEachCapsuleRunsItsOwnJobAndNoOtherCapsulesJob` exists because of it.
  /// This drives the same call every island capsule and every menu-bar row
  /// makes — `perform(_:)` — through the one switch there is.
  func testEachActionRunsItsOwnVerbAndNoOtherActionsVerb() {
    for action in MiniIslandAction.allCases {
      let spy = VerbSpy()
      let controller = MiniRecorderIslandController(
        presenter: StubIslandPresenter(),
        frontmost: { false },
        clock: { 100 },
        settings: { DictationSettings() },
        source: { .fake(state: .recording) },
        verbs: spy.verbs
      )
      controller.perform(action)
      XCTAssertEqual(spy.ran, [action], "\(action) ran \(spy.ran) instead of only itself")
    }
  }

  /// A ⌘K whose write did not reach the record may not be congratulated. The
  /// pane draws the same fact through `NotaModel.markersUnsaved`, and the pane
  /// is by construction not on screen whenever the island is.
  func testAMarkThatDidNotReachTheRecordSaysSoRatherThanCongratulating() {
    for landed in [true, false] {
      let spy = VerbSpy()
      spy.markResult = IslandMarkResult(at: 1720, ordinal: 3, landed: landed)
      let presenter = StubIslandPresenter()
      let controller = MiniRecorderIslandController(
        presenter: presenter,
        frontmost: { false },
        clock: { 100 },
        settings: { DictationSettings() },
        source: { .fake(state: .recording) },
        verbs: spy.verbs
      )
      controller.perform(.mark)
      XCTAssertEqual(
        presenter.rendered.last?.phase,
        .markConfirmed(time: "28:40", ordinal: "3rd", landed: landed)
      )
      XCTAssertEqual(
        presenter.rendered.last?.phase.message,
        landed ? "Marked 28:40 · 3rd" : "Marked 28:40 · 3rd · not saved"
      )
    }
  }

  /// A press the microphone refused (`markCurrentMoment` returns nil) leaves the
  /// card exactly as it was — there is nothing to confirm.
  func testAMarkTheMicrophoneRefusedConfirmsNothing() {
    let spy = VerbSpy()
    spy.markResult = nil
    let presenter = StubIslandPresenter()
    let controller = MiniRecorderIslandController(
      presenter: presenter,
      frontmost: { false },
      clock: { 100 },
      settings: { DictationSettings() },
      source: { .fake(state: .recording) },
      verbs: spy.verbs
    )
    controller.perform(.mark)
    XCTAssertNil(controller.mark)
    XCTAssertEqual(presenter.rendered.last?.phase, .recording)
  }

  /// **Discard is not a handoff.** `isLiveSessionHandedOff` is set by Discard
  /// too — which deletes the record and its audio — so the island reads the
  /// stop-specific flag. Otherwise a discarded session put "Transcribing… 3s
  /// ago" plus a Show button over another app, about a recording that is gone.
  func testOnlyAStopRaisesTheHandoffCard() {
    let presenter = StubIslandPresenter()
    var processing = false
    var now: TimeInterval = 100
    let controller = MiniRecorderIslandController(
      presenter: presenter,
      frontmost: { false },
      clock: { now },
      settings: { DictationSettings() },
      source: { .fake(state: .idle, isHandoffProcessing: processing) },
      verbs: VerbSpy().verbs
    )

    // Discard: the session is over, nothing is processing, no island.
    controller.refresh()
    XCTAssertFalse(presenter.isPresenting, "a discarded session raised a handoff card")

    // Stop: the same `.idle` state, and now there is something to say.
    processing = true
    now = 103
    controller.refresh()
    XCTAssertEqual(presenter.rendered.last?.phase, .handoff(secondsAgo: 0))
    now = 106
    controller.refresh()
    XCTAssertEqual(presenter.rendered.last?.phase, .handoff(secondsAgo: 3))
  }

  /// **The failure report may not feed the code that made it.**
  ///
  /// `reportUnavailable` writes `NotaModel.status`, which is `@Published` and
  /// republishes on every assignment, and the controller subscribes to the
  /// model — so an unlatched report was an unbounded main-actor loop building
  /// two `NSPanel`s per iteration, during a live recording, in exactly the
  /// zombie-WindowServer state the check exists for.
  func testAnIslandThatCannotBeShownIsReportedOnceAndNotBuiltAgain() {
    let presenter = StubIslandPresenter()
    presenter.succeeds = false
    var reports = 0
    var spy = VerbSpy().verbs
    spy.reportUnavailable = { reports += 1 }
    var state = LiveMeetingSession.SessionState.recording
    let controller = MiniRecorderIslandController(
      presenter: presenter,
      frontmost: { false },
      clock: { 100 },
      settings: { DictationSettings() },
      source: { .fake(state: state) },
      verbs: spy
    )

    for _ in 0..<25 { controller.refresh() }
    XCTAssertEqual(presenter.showAttempts, 1, "it kept building panels for a dead window server")
    XCTAssertEqual(reports, 1, "it kept rewriting the status line")
    XCTAssertTrue(controller.reportedUnavailable)

    // The latch is per session: when there is nothing to show, it clears, and
    // the next session asks the window server again.
    state = .idle
    controller.refresh()
    XCTAssertFalse(controller.reportedUnavailable)
    state = .recording
    controller.refresh()
    XCTAssertEqual(presenter.showAttempts, 2)
  }

  /// The owner's Glass opacity reaches the island. It did not: the presenter
  /// declared the properties and nothing in the app ever assigned them, so the
  /// slider moved the HUD and the review card and silently did not move this.
  func testTheIslandWearsTheOwnersGlassSettingsAndClampsThem() {
    let presenter = StubIslandPresenter()
    var settings = DictationSettings()
    settings.hudGlassOpacity = 0.90
    settings.hudGlassMaterial = .clear
    let controller = MiniRecorderIslandController(
      presenter: presenter,
      frontmost: { false },
      clock: { 100 },
      settings: { settings },
      source: { .fake(state: .recording) },
      verbs: VerbSpy().verbs
    )
    controller.refresh()
    XCTAssertEqual(presenter.glassTintAlpha, 0.90)
    XCTAssertEqual(presenter.glassMaterial, .clear)

    // And a stored number outside the range never reaches a surface.
    XCTAssertEqual(GlassTint.clamped(1.5), GlassTint.range.upperBound)
  }

  /// Nota coming forward takes the card down, through the whole controller and
  /// not only through the pure rule.
  func testBringingNotaForwardDismissesTheCardThroughTheController() {
    let presenter = StubIslandPresenter()
    var frontmost = false
    let controller = MiniRecorderIslandController(
      presenter: presenter,
      frontmost: { frontmost },
      clock: { 100 },
      settings: { DictationSettings() },
      source: { .fake(state: .recording) },
      verbs: VerbSpy().verbs
    )
    controller.refresh()
    XCTAssertTrue(presenter.isPresenting)
    frontmost = true
    controller.refresh()
    XCTAssertFalse(presenter.isPresenting)
    XCTAssertEqual(presenter.dismissals, 1)
  }

  /// The handoff card counts its own age, so the controller has to wake for it.
  /// Without the `now + 1` term it would freeze on "Transcribing… 0s ago" for
  /// the whole window — the one thing a spinner could not do either.
  func testTheHandoffCardWakesEverySecondAndTheMarkWakesWhenItExpires() {
    let handoff = MiniIslandInputs(sessionState: .idle, handoffStartedAt: 100, now: 100)
    XCTAssertEqual(MiniIslandVisibility.nextDeadline(handoff), 101)

    var later = handoff
    later.now = 100 + MiniIslandVisibility.handoffWindow - 0.5
    XCTAssertEqual(
      MiniIslandVisibility.nextDeadline(later),
      100 + MiniIslandVisibility.handoffWindow,
      "the card would outstay its window with nothing scheduled to take it down"
    )

    let marked = MiniIslandInputs(
      sessionState: .recording,
      mark: MiniIslandMark(at: 12, ordinal: 1, pressedAt: 100),
      now: 100.5
    )
    XCTAssertEqual(
      MiniIslandVisibility.nextDeadline(marked),
      100 + MiniIslandVisibility.markConfirmationDuration
    )
    // Nothing in flight: the recording phase rides the session's own once-a-second
    // publish and needs no timer of its own.
    XCTAssertNil(
      MiniIslandVisibility.nextDeadline(MiniIslandInputs(sessionState: .recording, now: 100))
    )
  }

  // MARK: - Helpers

  private static let everyPhase: [MiniIslandPhase] = [
    .recording,
    .markConfirmed(time: "28:40", ordinal: "3rd", landed: true),
    .markConfirmed(time: "28:40", ordinal: "3rd", landed: false),
    .paused,
    .handoff(secondsAgo: 3),
    // Deliberately longer than the card: it must truncate, not widen.
    .failure("The realtime connection dropped while the meeting was still running"),
  ]

  private static func fittingWidth(_ view: some View) -> CGFloat {
    let host = NSHostingView(rootView: view)
    host.layoutSubtreeIfNeeded()
    return host.fittingSize.width
  }

  private static func fittingHeight(_ view: some View) -> CGFloat {
    let host = NSHostingView(rootView: view)
    host.layoutSubtreeIfNeeded()
    return host.fittingSize.height
  }

  private static func hostingView(_ phase: MiniIslandPhase) -> NSHostingView<MiniRecorderIslandView> {
    let model = MiniIslandModel()
    model.phase = phase
    model.elapsed = 4360
    model.level = MicLevelFeed(level: 0.6)
    let view = NSHostingView(rootView: MiniRecorderIslandView(model: model))
    view.frame = NSRect(origin: .zero, size: MiniIslandMetrics.windowSize)
    view.layoutSubtreeIfNeeded()
    return view
  }

  /// The card rect the hosting view actually laid out — the window's fitting
  /// size less the transparent shadow margin on each side.
  private static func laidOutCardSize(_ phase: MiniIslandPhase) -> CGSize {
    let fitting = hostingView(phase).fittingSize
    let chrome = MiniIslandMetrics.shadowMargin * 2
    return CGSize(width: fitting.width - chrome, height: fitting.height - chrome)
  }

  /// True when anything in the rendered card is the ember. Through the recording
  /// pane's own `RenderProbe`, so both surfaces agree on what "an ember pixel"
  /// is — it matches on hue and saturation rather than RGB distance, because a
  /// meter bar at 55% is a long way from `#e8823a` in RGB and unmistakably the
  /// same colour.
  private static func drawsEmber(_ phase: MiniIslandPhase) -> Bool {
    let model = MiniIslandModel()
    model.phase = phase
    model.elapsed = 4360
    model.level = MicLevelFeed(level: 0.6)
    guard
      let bitmap = RenderProbe.bitmap(
        MiniRecorderIslandView(model: model),
        size: MiniIslandMetrics.windowSize
      )
    else {
      XCTFail("the island produced no bitmap")
      return false
    }
    return RenderProbe.emberPixels(bitmap, scheme: .dark) > 0
  }
}

// MARK: - Fakes

/// An island window that can be told whether AppKit gave it a window device —
/// which is what the escalation is about and what no real panel can be made to
/// refuse on demand.
@MainActor
private final class FakeIslandWindow: MiniRecorderWindowing {
  private let succeeds: Bool
  private(set) var dismissed = false
  /// Read by `testTheCardIsPlacedBeforeItIsOrderedOn` — an unread field is a
  /// claim nobody is making.
  private(set) var repositionedBeforePresent: Bool?
  private var repositioned = false
  var glassTintAlpha: Double = GlassTint.standard
  var glassMaterial: GlassMaterial = .standard

  init(succeeds: Bool) { self.succeeds = succeeds }

  func present() -> Bool {
    repositionedBeforePresent = repositioned
    return succeeds
  }
  func dismiss() { dismissed = true }
  func reposition() { repositioned = true }
}

/// A presenter that records what it was asked to show, with no window server.
@MainActor
private final class StubIslandPresenter: MiniRecorderPresenting {
  var succeeds = true
  private(set) var isPresenting = false
  private(set) var rendered: [MiniIslandRender] = []
  private(set) var showAttempts = 0
  private(set) var dismissals = 0
  var glassTintAlpha: Double = GlassTint.standard
  var glassMaterial: GlassMaterial = .standard

  func show(_ render: MiniIslandRender, perform: @escaping (MiniIslandAction) -> Void) -> Bool {
    showAttempts += 1
    rendered.append(render)
    isPresenting = succeeds
    return succeeds
  }

  func update(_ render: MiniIslandRender) {
    guard isPresenting else { return }
    rendered.append(render)
  }

  func dismiss() {
    guard isPresenting else { return }
    isPresenting = false
    dismissals += 1
  }
}

/// The four verbs, each recording only that it ran.
@MainActor
private final class VerbSpy {
  var ran: [MiniIslandAction] = []
  var markResult: IslandMarkResult? = IslandMarkResult(at: 12, ordinal: 1, landed: true)

  var verbs: IslandVerbs {
    IslandVerbs(
      mark: { [self] in ran.append(.mark); return markResult },
      pause: { [self] in ran.append(.pause) },
      resume: { [self] in ran.append(.resume) },
      stop: { [self] in ran.append(.stop) },
      show: { [self] in ran.append(.show) },
      retry: { [self] in ran.append(.retry) },
      reportUnavailable: {}
    )
  }
}

extension IslandSource {
  /// A source with no `NotaModel` behind it.
  @MainActor
  static func fake(
    state: LiveMeetingSession.SessionState,
    isHandoffProcessing: Bool = false,
    elapsed: TimeInterval = 12
  ) -> IslandSource {
    IslandSource(
      sessionState: state,
      isHandoffProcessing: isHandoffProcessing,
      elapsed: elapsed,
      level: nil
    )
  }
}
