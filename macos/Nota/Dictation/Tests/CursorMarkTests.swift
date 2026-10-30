import XCTest

@testable import Nota

// MARK: - Phase

/// The Cursor style's state machine: dot ↔ waveform ↔ rolling wave, and the
/// tinted problem state — decided from one controller snapshot, with no panel.
final class CursorMarkPhaseTests: XCTestCase {
  private func phase(
    _ state: DictationState,
    starting: Bool = false,
    reviewing: Bool = false,
    voice: Bool = false,
    inFlight: Int = 0,
    polishing: Bool = false,
    warning: String? = nil,
    notice: String? = nil
  ) -> CursorMarkPhase {
    CursorMarkPhase.compute(
      controllerState: state,
      isStartingSession: starting,
      isReviewing: reviewing,
      voiceHeard: voice,
      sentencesInFlight: inFlight,
      isPolishInProgress: polishing,
      lastPolishWarning: warning,
      lastSecureFieldNotice: notice
    )
  }

  /// "Fn down → dot at caret": the mark is up from the press, before a cloud
  /// engine's handshake has let `state` reach `.listening`.
  func testTheDotIsUpFromThePress() {
    XCTAssertEqual(phase(.idle, starting: true), .quiet)
    XCTAssertEqual(phase(.listening), .quiet)
  }

  func testTheVoiceWidensTheMarkIntoTheWaveform() {
    XCTAssertEqual(phase(.listening, voice: true), .talking)
    XCTAssertTrue(CursorMarkPhase.talking.isWide)
    XCTAssertFalse(CursorMarkPhase.quiet.isWide)
  }

  /// "A wave rolling through the bars while a sentence is being processed":
  /// between a pause and its text landing, in Insert While Speaking.
  func testASentenceOnItsWayRollsTheWave() {
    XCTAssertEqual(phase(.listening, inFlight: 1), .working)
    XCTAssertEqual(phase(.listening, polishing: true), .working)
  }

  /// The owner's own voice outranks the processing wave: it is the thing they
  /// are watching for.
  func testTalkingOutranksWorking() {
    XCTAssertEqual(phase(.listening, voice: true, inFlight: 2), .talking)
  }

  /// "Fn up → last cleanup wave → fade out", in both delivery modes.
  func testAfterReleaseTheWaveRollsUntilTheTextLands() {
    XCTAssertEqual(phase(.finalizing), .working)
    XCTAssertEqual(phase(.injecting), .working)
    XCTAssertEqual(phase(.idle), .hidden, "a clean finish just fades — no Inserted card")
  }

  func testProblemsTintTheMark() {
    XCTAssertEqual(
      phase(.idle, warning: "Polish failed. Using rules-only result."),
      .problem(CursorProblem(kind: .warning, message: "Polish failed. Using rules-only result."))
    )
    XCTAssertEqual(
      phase(.idle, notice: "Secure field"),
      .problem(CursorProblem(kind: .warning, message: "Secure field"))
    )
    XCTAssertEqual(
      phase(.failed(message: "Nota could not insert the text")),
      .problem(CursorProblem(kind: .error, message: "Nota could not insert the text"))
    )
  }

  /// Review Before Inserting keeps its card, unchanged: the card is that
  /// session's one surface, so the mark never appears in any state.
  func testReviewNeverShowsTheMark() {
    let states: [DictationState] = [
      .idle, .listening, .finalizing, .injecting, .failed(message: "boom"),
    ]
    for state in states {
      XCTAssertEqual(
        phase(state, starting: true, reviewing: true, voice: true, inFlight: 1, warning: "w"),
        .hidden,
        "\(state)"
      )
    }
  }

  func testAPermissionBlockShowsNothing() {
    XCTAssertEqual(phase(.disabled(reason: "no mic"), starting: true), .hidden)
  }

  func testAPressAfterAFailureIsANewSessionNotTheOldError() {
    XCTAssertEqual(phase(.failed(message: "boom"), starting: true), .quiet)
  }
}

// MARK: - Voice gate

final class CursorVoiceGateTests: XCTestCase {
  func testRoomNoiseNeverOpensTheGate() {
    var gate = CursorVoiceGate()
    for step in 0..<20 {
      XCTAssertFalse(gate.update(level: 0.12, now: Double(step) * 0.066))
    }
  }

  func testSpeechOpensItAtOnce() {
    var gate = CursorVoiceGate()
    XCTAssertTrue(gate.update(level: 0.55, now: 0))
  }

  /// The gap between two words must not flip the capsule back to a dot.
  func testTheGapBetweenWordsKeepsTheWaveform() {
    var gate = CursorVoiceGate()
    _ = gate.update(level: 0.6, now: 0)
    XCTAssertTrue(gate.update(level: 0.1, now: 0.1))
    XCTAssertTrue(gate.update(level: 0.1, now: 0.3))
    XCTAssertTrue(gate.update(level: 0.5, now: 0.35), "the next word arrives")
    XCTAssertTrue(gate.update(level: 0.1, now: 0.6), "the quiet clock restarted")
  }

  func testAPauseReturnsToTheDot() {
    var gate = CursorVoiceGate()
    _ = gate.update(level: 0.6, now: 0)
    _ = gate.update(level: 0.1, now: 0.1)
    XCTAssertTrue(gate.update(level: 0.1, now: 0.1 + CursorVoiceGate.hangover - 0.05))
    XCTAssertFalse(gate.update(level: 0.1, now: 0.1 + CursorVoiceGate.hangover + 0.01))
    XCTAssertFalse(gate.isOpen)
  }

  /// Between the two thresholds the gate holds whatever it was.
  func testHysteresisHoldsTheCurrentAnswer() {
    var closed = CursorVoiceGate()
    XCTAssertFalse(closed.update(level: 0.25, now: 0))
    var open = CursorVoiceGate()
    _ = open.update(level: 0.6, now: 0)
    XCTAssertTrue(open.update(level: 0.25, now: 5))
  }

  func testResetCloses() {
    var gate = CursorVoiceGate()
    _ = gate.update(level: 0.9, now: 0)
    gate.reset()
    XCTAssertFalse(gate.isOpen)
  }
}

// MARK: - Lifecycle

final class CursorMarkLifecycleTests: XCTestCase {
  private let problem = CursorProblem(kind: .error, message: "Nota could not insert the text")

  /// "A one-line glass note beside it that fades ~4s".
  func testAProblemShowsForFourSecondsThenStaysGone() {
    var lifecycle = CursorMarkLifecycle()
    XCTAssertEqual(lifecycle.display(.problem(problem), now: 10), .problem(problem))
    XCTAssertEqual(lifecycle.expiry, 10 + CursorMarkLifecycle.problemDuration)
    XCTAssertEqual(lifecycle.display(.problem(problem), now: 13.9), .problem(problem))
    XCTAssertEqual(lifecycle.display(.problem(problem), now: 14.0), .hidden)
    XCTAssertNil(lifecycle.expiry)
    // The controller's failure field is still set; the note must not return.
    XCTAssertEqual(lifecycle.display(.problem(problem), now: 30), .hidden)
  }

  func testANewSessionClearsTheConsumedProblem() {
    var lifecycle = CursorMarkLifecycle()
    _ = lifecycle.display(.problem(problem), now: 0)
    _ = lifecycle.display(.problem(problem), now: 5)
    XCTAssertEqual(lifecycle.display(.quiet, now: 6), .quiet)
    XCTAssertEqual(lifecycle.display(.problem(problem), now: 7), .problem(problem))
  }

  func testADifferentProblemGetsItsOwnFourSeconds() {
    var lifecycle = CursorMarkLifecycle()
    _ = lifecycle.display(.problem(problem), now: 0)
    let other = CursorProblem(kind: .warning, message: "Polish failed")
    XCTAssertEqual(lifecycle.display(.problem(other), now: 3), .problem(other))
    XCTAssertEqual(lifecycle.expiry, 3 + CursorMarkLifecycle.problemDuration)
  }

  func testSessionPhasesPassStraightThrough() {
    var lifecycle = CursorMarkLifecycle()
    for phase in [CursorMarkPhase.quiet, .talking, .working, .hidden] {
      XCTAssertEqual(lifecycle.display(phase, now: 1), phase)
    }
  }
}

// MARK: - Metrics

final class CursorMarkMetricsTests: XCTestCase {
  func testTheMarkIsADotOrAWaveformAndAlways20Tall() {
    XCTAssertEqual(CursorMarkMetrics.height, 20)
    XCTAssertEqual(CursorMarkMetrics.width(for: .quiet), 20)
    XCTAssertEqual(CursorMarkMetrics.width(for: .talking), 40)
    XCTAssertEqual(CursorMarkMetrics.width(for: .working), 40)
    XCTAssertEqual(
      CursorMarkMetrics.width(for: .problem(CursorProblem(kind: .warning, message: "x"))), 20
    )
  }

  /// Five bars, and they fit inside the 40pt capsule with room to spare.
  func testFiveBarsFitTheWaveform() {
    let bars = CGFloat(CursorMarkMetrics.barCount) * CursorMarkMetrics.barWidth
      + CGFloat(CursorMarkMetrics.barCount - 1) * CursorMarkMetrics.barSpacing
    XCTAssertEqual(CursorMarkMetrics.barCount, 5)
    XCTAssertLessThan(bars, CursorMarkMetrics.wideWidth - 8)
    XCTAssertLessThanOrEqual(CursorMarkMetrics.barMax, CursorMarkMetrics.height)
  }

  func testTalkingBarsFollowTheLevelWithinTheirBounds() {
    let quiet = CursorMarkMetrics.talkingBarHeight(level: 0, index: 2, breathe: 0)
    let loud = CursorMarkMetrics.talkingBarHeight(level: 1, index: 2, breathe: 0)
    let clipped = CursorMarkMetrics.talkingBarHeight(level: 5, index: 2, breathe: 0.5)
    XCTAssertEqual(quiet, CursorMarkMetrics.barBase)
    XCTAssertEqual(loud, CursorMarkMetrics.barMax)
    XCTAssertEqual(clipped, CursorMarkMetrics.barMax)
    XCTAssertGreaterThan(
      loud, CursorMarkMetrics.talkingBarHeight(level: 1, index: 0, breathe: 0),
      "centre-weighted"
    )
  }

  func testTheWorkingWaveRollsAndHoldsStillUnderReduceMotion() {
    let now = (0..<5).map { CursorMarkMetrics.rollingBarHeight(index: $0, time: 1.0, reduceMotion: false) }
    let later = (0..<5).map { CursorMarkMetrics.rollingBarHeight(index: $0, time: 1.2, reduceMotion: false) }
    XCTAssertNotEqual(now, later, "the wave travels")
    XCTAssertGreaterThan(Set(now).count, 1, "a crest, not a flat line")
    let still = (0..<5).map { CursorMarkMetrics.rollingBarHeight(index: $0, time: 1.0, reduceMotion: true) }
    XCTAssertEqual(Set(still).count, 1)
    XCTAssertEqual(
      still, (0..<5).map { CursorMarkMetrics.rollingBarHeight(index: $0, time: 9.0, reduceMotion: true) }
    )
  }

  /// Reduce Motion stops the decoration (the breathing) and nothing else.
  func testTheDotBreathesExceptUnderReduceMotion() {
    XCTAssertNotEqual(
      CursorMarkMetrics.coreScale(time: 0, reduceMotion: false),
      CursorMarkMetrics.coreScale(time: 1, reduceMotion: false)
    )
    XCTAssertEqual(CursorMarkMetrics.coreScale(time: 0, reduceMotion: true), 1)
    XCTAssertEqual(CursorMarkMetrics.coreScale(time: 7, reduceMotion: true), 1)
  }
}

// MARK: - Placement

final class CursorMarkPlacementTests: XCTestCase {
  private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
  /// A caret line in the middle of the screen (Cocoa coordinates).
  private let caret = CGRect(x: 400, y: 500, width: 0, height: 18)

  func testTheFallbackChainPrefersTheCaretThenTheElement() {
    let element = CGRect(x: 100, y: 100, width: 600, height: 400)
    let point = CGPoint(x: 720, y: 64)
    XCTAssertEqual(
      CursorMarkPlacement.anchor(caret: caret, element: element, fallback: point), .caret(caret)
    )
    XCTAssertEqual(
      CursorMarkPlacement.anchor(caret: nil, element: element, fallback: point), .element(element)
    )
    XCTAssertEqual(
      CursorMarkPlacement.anchor(caret: nil, element: nil, fallback: point), .fallback(point)
    )
  }

  /// Beside: just after the caret, centred on its line, and the morph grows it
  /// away from the text — the left edge never moves.
  func testBesideHoldsItsLeftEdgeWhileItWidens() {
    let dot = CursorMarkPlacement.markFrame(
      anchor: .caret(caret), width: 20, position: .beside, visibleFrame: screen
    )
    let wave = CursorMarkPlacement.markFrame(
      anchor: .caret(caret), width: 40, position: .beside, visibleFrame: screen
    )
    XCTAssertEqual(dot.minX, caret.maxX + CursorMarkMetrics.besideGap)
    XCTAssertEqual(dot.midY, caret.midY)
    XCTAssertEqual(dot.height, 20)
    XCTAssertEqual(wave.minX, dot.minX)
    XCTAssertEqual(wave.width, 40)
  }

  /// At the right edge of the screen the mark goes to the caret's left rather
  /// than being clamped back over the text.
  func testBesideFlipsLeftAtTheScreenEdge() {
    let edgeCaret = CGRect(x: 1425, y: 500, width: 0, height: 18)
    let rect = CursorMarkPlacement.markFrame(
      anchor: .caret(edgeCaret), width: 40, position: .beside, visibleFrame: screen
    )
    XCTAssertEqual(rect.maxX, edgeCaret.minX - CursorMarkMetrics.besideGap)
  }

  /// Below: under the caret's line, centred on it, so the morph grows
  /// symmetrically about the caret.
  func testBelowIsCentredUnderTheCaret() {
    for width in [CGFloat(20), 40] {
      let rect = CursorMarkPlacement.markFrame(
        anchor: .caret(caret), width: width, position: .below, visibleFrame: screen
      )
      XCTAssertEqual(rect.midX, caret.minX)
      XCTAssertEqual(rect.maxY, caret.minY - CursorMarkMetrics.belowGap)
    }
  }

  /// Rung two: inside the focused element's bottom-right corner, right edge
  /// pinned so the morph never pushes it out of the field.
  func testTheElementFallbackSitsInsideTheBottomRightCorner() {
    let element = CGRect(x: 100, y: 100, width: 600, height: 400)
    let dot = CursorMarkPlacement.markFrame(
      anchor: .element(element), width: 20, position: .beside, visibleFrame: screen
    )
    let wave = CursorMarkPlacement.markFrame(
      anchor: .element(element), width: 40, position: .below, visibleFrame: screen
    )
    XCTAssertEqual(dot.maxX, element.maxX - CursorMarkMetrics.elementInset)
    XCTAssertEqual(dot.minY, element.minY + CursorMarkMetrics.elementInset)
    XCTAssertEqual(wave.maxX, dot.maxX)
    XCTAssertTrue(element.contains(wave))
  }

  /// Rung three: the pill's usual spot — centred under the focused window.
  func testTheLastFallbackIsWhereThePillWouldHang() {
    let window = CGRect(x: 200, y: 300, width: 800, height: 500)
    let point = CursorMarkPlacement.fallbackPoint(windowFrame: window, visibleFrame: screen)
    XCTAssertEqual(point.x, window.midX)
    XCTAssertEqual(
      point.y,
      HUDPanelLayout.pillOriginY(
        anchorMinY: window.minY, screenFrame: screen, pillHeight: 20, reservedHeight: 20
      )
    )
    let rect = CursorMarkPlacement.markFrame(
      anchor: .fallback(point), width: 40, position: .beside, visibleFrame: screen
    )
    XCTAssertEqual(rect.midX, window.midX)
    XCTAssertEqual(rect.minY, point.y)

    let bare = CursorMarkPlacement.fallbackPoint(windowFrame: nil, visibleFrame: screen)
    XCTAssertEqual(bare.x, screen.midX)
  }

  func testTheMarkNeverLeavesTheScreen() {
    let anchors: [CursorAnchor] = [
      .caret(CGRect(x: -50, y: 2, width: 0, height: 18)),
      .caret(CGRect(x: 2000, y: 2000, width: 0, height: 18)),
      .element(CGRect(x: 1400, y: -40, width: 30, height: 30)),
      .fallback(CGPoint(x: 0, y: 0)),
    ]
    let inner = screen.insetBy(dx: CursorMarkMetrics.screenInset, dy: CursorMarkMetrics.screenInset)
    for anchor in anchors {
      for position in CursorMarkPosition.allCases {
        let rect = CursorMarkPlacement.markFrame(
          anchor: anchor, width: 40, position: position, visibleFrame: screen
        )
        XCTAssertTrue(inner.contains(rect), "\(anchor) \(position): \(rect)")
      }
    }
  }

  func testTheNoteSitsBesideTheMarkAndFlipsAtTheEdge() {
    let mark = CGRect(x: 400, y: 500, width: 20, height: 20)
    let note = CursorMarkPlacement.noteFrame(
      mark: mark, noteSize: CGSize(width: 200, height: 24), visibleFrame: screen
    )
    XCTAssertEqual(note.minX, mark.maxX + CursorMarkMetrics.noteGap)
    XCTAssertEqual(note.midY, mark.midY)

    let edgeMark = CGRect(x: 1380, y: 500, width: 20, height: 20)
    let flipped = CursorMarkPlacement.noteFrame(
      mark: edgeMark, noteSize: CGSize(width: 200, height: 24), visibleFrame: screen
    )
    XCTAssertEqual(flipped.maxX, edgeMark.minX - CursorMarkMetrics.noteGap)

    let long = CursorMarkPlacement.noteFrame(
      mark: mark, noteSize: CGSize(width: 900, height: 24), visibleFrame: screen
    )
    XCTAssertEqual(long.width, CursorMarkMetrics.noteMaxWidth, "one line, capped")
  }
}

// MARK: - Caret geometry

final class CaretGeometryTests: XCTestCase {
  private let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]

  /// AX is top-left origin; Cocoa bottom-left. A caret line whose top is 100pt
  /// below the top of a 900pt primary screen has its bottom 782pt above the
  /// bottom edge.
  func testTheAXRectIsFlippedOntoCocoa() {
    let ax = CGRect(x: 300, y: 100, width: 2, height: 18)
    XCTAssertEqual(
      CaretGeometry.cocoaRect(fromAX: ax, primaryScreenMaxY: 900),
      CGRect(x: 300, y: 782, width: 2, height: 18)
    )
  }

  func testACollapsedRangeThatAnswersIsTheCaret() {
    let caret = CaretGeometry.caret(
      collapsed: CGRect(x: 300, y: 100, width: 0, height: 18), preceding: nil, following: nil
    )
    XCTAssertEqual(caret, CGRect(x: 300, y: 100, width: 0, height: 18))
  }

  /// The common failure: a zero-length range answers with a zero rect, and the
  /// character before the caret answers properly. Its trailing edge is the caret.
  func testAZeroRectFallsBackToTheCharacterBefore() {
    let caret = CaretGeometry.caret(
      collapsed: CGRect(x: 300, y: 100, width: 0, height: 0),
      preceding: CGRect(x: 290, y: 100, width: 8, height: 18),
      following: nil
    )
    XCTAssertEqual(caret, CGRect(x: 298, y: 100, width: 0, height: 18))
  }

  func testAtTheStartOfAFieldTheCharacterAfterIsUsed() {
    let caret = CaretGeometry.caret(
      collapsed: nil, preceding: nil, following: CGRect(x: 40, y: 60, width: 9, height: 17)
    )
    XCTAssertEqual(caret, CGRect(x: 40, y: 60, width: 0, height: 17))
  }

  func testImplausibleAnswersAreRefused() {
    XCTAssertFalse(CaretGeometry.isPlausibleLine(.zero))
    XCTAssertFalse(CaretGeometry.isPlausibleLine(CGRect(x: 0, y: 0, width: 0, height: 18)))
    XCTAssertFalse(
      CaretGeometry.isPlausibleLine(CGRect(x: 10, y: 10, width: 400, height: 700)),
      "a whole text view answering for a collapsed range"
    )
    XCTAssertFalse(
      CaretGeometry.isPlausibleLine(CGRect(x: CGFloat.nan, y: 10, width: 0, height: 18))
    )
    XCTAssertNil(CaretGeometry.caret(collapsed: .zero, preceding: .zero, following: nil))
  }

  /// A caret on no screen, or nowhere near its own element, is a server
  /// answering in the wrong coordinate space — fall through to the element.
  func testACaretFarFromItsElementOrOffScreenIsDropped() {
    let element = CGRect(x: 100, y: 100, width: 600, height: 300)
    let inside = CGRect(x: 300, y: 200, width: 0, height: 18)
    XCTAssertEqual(
      CaretGeometry.validated(caret: inside, element: element, screens: screens), inside
    )
    XCTAssertNil(
      CaretGeometry.validated(
        caret: CGRect(x: 1300, y: 850, width: 0, height: 18), element: element, screens: screens
      )
    )
    XCTAssertNil(
      CaretGeometry.validated(
        caret: CGRect(x: 3000, y: 200, width: 0, height: 18), element: nil, screens: screens
      )
    )
  }

  func testAnElementMustBeOnAScreenAndHaveASize() {
    XCTAssertNil(CaretGeometry.validated(element: .zero, screens: screens))
    XCTAssertNil(
      CaretGeometry.validated(
        element: CGRect(x: 5000, y: 5000, width: 100, height: 40), screens: screens
      )
    )
    let field = CGRect(x: 100, y: 100, width: 300, height: 40)
    XCTAssertEqual(CaretGeometry.validated(element: field, screens: screens), field)
  }
}

// MARK: - The setting and the style

final class CursorStyleSettingsTests: XCTestCase {
  func testTheStylePickerOffersCursor() {
    XCTAssertEqual(HUDStyle.allCases, [.pill, .bar, .prompter, .cursor])
    XCTAssertEqual(HUDStyle.cursor.label, "Cursor")
    XCTAssertFalse(HUDStyle.cursor.isAboutLiveText, "no preview text, so nothing to sit empty")
    XCTAssertNil(HUDStyle.cursor.reservedCardHeight, "the pill panel does not place it")
  }

  func testPositionDefaultsToBesideTheCursor() {
    XCTAssertEqual(DictationSettings().cursorMarkPosition, .beside)
    XCTAssertEqual(CursorMarkPosition.allCases.map(\.label), ["Beside cursor", "Below cursor"])
  }

  func testAPayloadWithoutThePositionKeepsEverythingElse() throws {
    let json = """
      {"showHUD":true,"hudStyle":"cursor","deliveryMode":"streaming","trigger":{"kind":"fnGlobe"}}
      """
    let settings = try JSONDecoder().decode(DictationSettings.self, from: Data(json.utf8))
    XCTAssertEqual(settings.cursorMarkPosition, .beside)
    XCTAssertEqual(settings.hudStyle, .cursor)
    XCTAssertEqual(settings.deliveryMode, .streaming)
  }

  func testAnUnknownPositionDecodesToTheDefault() throws {
    let json = """
      {"hudStyle":"cursor","cursorMarkPosition":"above","trigger":{"kind":"fnGlobe"}}
      """
    let settings = try JSONDecoder().decode(DictationSettings.self, from: Data(json.utf8))
    XCTAssertEqual(settings.cursorMarkPosition, .beside)
    XCTAssertEqual(settings.hudStyle, .cursor)
  }

  func testEveryPositionRoundTrips() throws {
    for position in CursorMarkPosition.allCases {
      var settings = DictationSettings()
      settings.hudStyle = .cursor
      settings.cursorMarkPosition = position
      let decoded = try JSONDecoder().decode(
        DictationSettings.self, from: JSONEncoder().encode(settings)
      )
      XCTAssertEqual(decoded, settings)
    }
  }

  func testTheGlassIsACapsule() {
    XCTAssertEqual(
      HUDGlassMetrics.cornerRadius(style: .cursor, state: .listening(level: 0), cardHeight: 20),
      CursorMarkMetrics.height / 2
    )
  }

  func testTheSettingsPaneExplainsTheFallbackAndReview() {
    let streaming = HUDStyle.cursorCaveats(mode: .streaming)
    XCTAssertEqual(streaming.count, 1)
    XCTAssertTrue(streaming[0].contains("corner of the text field"))
    let review = HUDStyle.cursorCaveats(mode: .review)
    XCTAssertEqual(review.count, 2)
    XCTAssertTrue(review[1].contains(DeliveryMode.review.label))
  }
}

// MARK: - Sentences in flight

/// The "working" wave's feed: how many accepted sentences have not reached the
/// target yet.
@MainActor
final class StreamingDeliveryInFlightTests: XCTestCase {
  @MainActor
  private final class Log {
    var counts: [Int] = []
    var deltas: [String] = []
  }

  func testTheCountRisesPerSentenceAndFallsAsEachLands() async {
    let log = Log()
    let queue = StreamingDeliveryQueue(
      refine: { $0.text },
      deliver: { log.deltas.append($0) }
    )
    queue.onInFlightChange = { log.counts.append($0) }

    queue.enqueue("One.")
    queue.enqueue("Two.")
    XCTAssertEqual(queue.inFlightCount, 2)
    await queue.finish()

    XCTAssertEqual(queue.inFlightCount, 0)
    XCTAssertEqual(log.deltas, ["One.", " Two."])
    XCTAssertEqual(log.counts, [1, 2, 1, 0])
  }

  func testAnEmptySentenceIsNeverCounted() {
    let queue = StreamingDeliveryQueue(refine: { $0.text }, deliver: { _ in })
    queue.enqueue("   ")
    XCTAssertEqual(queue.inFlightCount, 0)
  }

  /// A refinement that yields nothing to type still leaves the queue.
  func testARefinementWithNothingToTypeStillSettles() async {
    let queue = StreamingDeliveryQueue(refine: { _ in "" }, deliver: { _ in })
    queue.enqueue("Uh.")
    await queue.finish()
    XCTAssertEqual(queue.inFlightCount, 0)
  }

  func testCancelEmptiesIt() {
    let queue = StreamingDeliveryQueue(refine: { $0.text }, deliver: { _ in })
    queue.enqueue("One.")
    queue.cancel()
    XCTAssertEqual(queue.inFlightCount, 0)
  }
}

// MARK: - The panel

/// The mark's panel owes every rule a floating surface owes, plus the one that
/// makes it a different class from the pill's: it takes no clicks. A panel
/// beside the caret that took clicks would swallow the click that moves it.
@MainActor
final class CursorMarkPanelTests: XCTestCase {
  func testThePanelKeepsTheFloatingSurfaceRules() {
    let panel = CursorMarkPanel(cornerRadius: CursorMarkMetrics.height / 2)
    XCTAssertTrue(panel.ignoresMouseEvents)
    XCTAssertTrue(panel.isFloatingPanel)
    // Assigned after isFloatingPanel, which would otherwise have left it at
    // .floating — below a fullscreen app.
    XCTAssertEqual(panel.level, .statusBar)
    XCTAssertEqual(panel.appearance?.name, .darkAqua)
    XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    XCTAssertFalse(panel.canBecomeKey)
    XCTAssertFalse(panel.canBecomeMain)
    XCTAssertFalse(panel.hasShadow)
    XCTAssertTrue(panel.contentView is GlassBackingView, "an AppKit glass plate, not SwiftUI glass")
  }

  /// `PanelMotion.fadeIn` gives a panel its clicks back by default (a panel
  /// caught mid-dismissal had them taken away). The mark must not get them.
  func testFadingInLeavesItClickThrough() {
    let panel = CursorMarkPanel(cornerRadius: CursorMarkMetrics.height / 2)
    PanelMotion.fadeIn(panel, rise: 0, clickThrough: true) { () }
    XCTAssertTrue(panel.ignoresMouseEvents)
    // The default is unchanged for every other floating panel.
    let other = CursorMarkPanel(cornerRadius: 10)
    other.ignoresMouseEvents = true
    PanelMotion.fadeIn(other, rise: 0) { () }
    XCTAssertFalse(other.ignoresMouseEvents)
  }
}
