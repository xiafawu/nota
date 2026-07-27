import AppKit
import XCTest

@testable import Nota

// MARK: - Migration

/// The bool this enum replaced shipped, so a user's stored payload may still be
/// carrying it. Losing that preference is not cosmetic: a person who opted into
/// streaming would silently be moved back to insert-on-release.
final class DeliveryModeMigrationTests: XCTestCase {
  override func tearDown() {
    DictationSettingsStore.reset()
    super.tearDown()
  }

  private func decode(_ json: String) throws -> DictationSettings {
    try JSONDecoder().decode(DictationSettings.self, from: Data(json.utf8))
  }

  func testStoredStreamingTrueBecomesStreaming() throws {
    XCTAssertEqual(try decode(#"{"streamingDelivery":true}"#).deliveryMode, .streaming)
  }

  func testStoredStreamingFalseBecomesImmediate() throws {
    XCTAssertEqual(try decode(#"{"streamingDelivery":false}"#).deliveryMode, .immediate)
  }

  func testAbsentKeyBecomesImmediate() throws {
    XCTAssertEqual(try decode(#"{"showHUD":true}"#).deliveryMode, .immediate)
  }

  func testDeliveryModeDecodesEveryMode() throws {
    XCTAssertEqual(try decode(#"{"deliveryMode":"immediate"}"#).deliveryMode, .immediate)
    XCTAssertEqual(try decode(#"{"deliveryMode":"streaming"}"#).deliveryMode, .streaming)
    XCTAssertEqual(try decode(#"{"deliveryMode":"review"}"#).deliveryMode, .review)
  }

  func testDeliveryModeWinsOverTheLegacyBool() throws {
    // Written by this version, then read by it again: the migration must not
    // fire a second time and drag the user back to streaming.
    let settings = try decode(#"{"deliveryMode":"review","streamingDelivery":true}"#)
    XCTAssertEqual(settings.deliveryMode, .review)
  }

  func testAnUnknownModeFallsBackWithoutTakingTheRestDown() throws {
    // Per-field tolerance: a payload from a newer build must not reset the
    // user's engine and trigger on the way past a mode this build cannot read.
    let settings = try decode(
      #"{"deliveryMode":"telepathy","engine":"assemblyAIRealtime","showHUD":false}"#
    )
    XCTAssertEqual(settings.deliveryMode, .immediate)
    XCTAssertEqual(settings.engine, .assemblyAIRealtime)
    XCTAssertFalse(settings.showHUD)
  }

  func testReviewModeRoundTripsThroughTheStore() {
    var settings = DictationSettingsStore.load()
    settings.deliveryMode = .review
    DictationSettingsStore.save(settings)
    XCTAssertEqual(DictationSettingsStore.load().deliveryMode, .review)
  }

  func testTheEnumIsWritten() throws {
    var settings = DictationSettings()
    settings.deliveryMode = .review
    let json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
    XCTAssertTrue(json.contains("review"))
  }

  /// The migration has to work in both directions. A build predating the enum
  /// reads only this bool, and it re-saves without `deliveryMode` — so writing
  /// the bool is what stops one launch of an older build from silently moving
  /// a streaming user to insert-on-release for good.
  func testTheLegacyBoolIsWrittenAlongsideTheEnum() throws {
    func encoded(_ mode: DeliveryMode) throws -> DictationSettings {
      var settings = DictationSettings()
      settings.deliveryMode = mode
      let data = try JSONEncoder().encode(settings)
      // Decoded through the LEGACY reading of the payload: `deliveryMode`
      // stripped, exactly what an older build would see.
      var object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
      )
      object.removeValue(forKey: "deliveryMode")
      return try JSONDecoder().decode(
        DictationSettings.self,
        from: JSONSerialization.data(withJSONObject: object)
      )
    }

    XCTAssertEqual(try encoded(.streaming).deliveryMode, .streaming)
    XCTAssertEqual(try encoded(.immediate).deliveryMode, .immediate)
    // The older build has no review mode; insert-on-release is the honest
    // degradation, and it is what that build would have done anyway.
    XCTAssertEqual(try encoded(.review).deliveryMode, .immediate)
  }

  func testTheWrittenBoolNeverOverridesTheEnumOnTheWayBackIn() throws {
    var settings = DictationSettings()
    settings.deliveryMode = .review
    let data = try JSONEncoder().encode(settings)
    XCTAssertEqual(
      try JSONDecoder().decode(DictationSettings.self, from: data).deliveryMode,
      .review
    )
  }

  func testEverySettingSurvivesTheHandWrittenEncoder() throws {
    var settings = DictationSettings()
    settings.engine = .assemblyAIRealtime
    settings.trigger = TriggerKey(kind: .keyCode, keyCode: 63)
    settings.activation = .toggle
    settings.polishEnabled = true
    settings.polishModelID = "gpt-5.4-mini"
    settings.showHUD = false
    settings.deliveryMode = .streaming

    let data = try JSONEncoder().encode(settings)
    XCTAssertEqual(try JSONDecoder().decode(DictationSettings.self, from: data), settings)
  }
}

// MARK: - Apply / discard

/// What leaves the panel. The two load-bearing claims are that Discard inserts
/// nothing at all and that Apply inserts the EDITED text, not the polished text
/// the panel was opened with.
final class DictationReviewResolutionTests: XCTestCase {
  private let offline = "Ship the gency to rust patch."
  private let polished = "Ship the gency to rust patch."

  func testDiscardInsertsNothing() {
    let resolution = DictationReview.resolve(
      polished: polished,
      offline: offline,
      decision: .discard
    )
    XCTAssertNil(resolution.injection)
    XCTAssertEqual(resolution.learn, [])
  }

  func testDiscardAfterEditingStillInsertsNothing() {
    // The decision carries no text at all — an edited-then-discarded panel
    // cannot inject by any route.
    XCTAssertNil(
      DictationReview.resolve(polished: polished, offline: offline, decision: .discard).injection
    )
  }

  func testApplyInsertsTheEditedText() {
    let edited = "Ship the genc2rust patch."
    let resolution = DictationReview.resolve(
      polished: polished,
      offline: offline,
      decision: .apply(edited)
    )
    XCTAssertEqual(resolution.injection, edited)
  }

  func testApplyingUnchangedTextLearnsTheDiffTheOwnerEndorsed() {
    // No user edit, so nothing to learn from the panel — but applying is an
    // endorsement of the polish diff, which the immediate path learns from
    // unconditionally.
    let resolution = DictationReview.resolve(
      polished: "Ship the genc2rust patch.",
      offline: offline,
      decision: .apply("Ship the genc2rust patch.")
    )
    XCTAssertEqual(resolution.injection, "Ship the genc2rust patch.")
    XCTAssertEqual(
      resolution.learn,
      [DictationReview.LearnPair(before: offline, after: "Ship the genc2rust patch.")]
    )
  }

  func testAnOwnerEditIsTheFirstPairLearned() {
    let edited = "Ship the genc2rust patch."
    let resolution = DictationReview.resolve(
      polished: polished,
      offline: offline,
      decision: .apply(edited)
    )
    XCTAssertEqual(resolution.learn.first?.before, polished)
    XCTAssertEqual(resolution.learn.first?.after, edited)
  }

  func testAPairIsNotLearnedTwiceWhenPolishWasOff() {
    // Polish off (or failed) means polished == offline; one pair, not two.
    let resolution = DictationReview.resolve(
      polished: offline,
      offline: offline,
      decision: .apply("Ship the genc2rust patch.")
    )
    XCTAssertEqual(resolution.learn.count, 1)
  }

  func testApplyingNothingInsertsNothing() {
    XCTAssertNil(
      DictationReview.resolve(
        polished: polished,
        offline: offline,
        decision: .apply("   \n ")
      ).injection
    )
  }

  func testATrailingNewlineIsAKeystrokeNotAnEdit() {
    let resolution = DictationReview.resolve(
      polished: polished,
      offline: polished,
      decision: .apply(polished + "\n")
    )
    XCTAssertEqual(resolution.injection, polished)
    XCTAssertEqual(resolution.learn, [], "a stray return must not read as a correction")
  }

  func testIdenticalTextTeachesNothingAtAll() {
    let resolution = DictationReview.resolve(
      polished: polished,
      offline: polished,
      decision: .apply(polished)
    )
    XCTAssertEqual(resolution.learn, [])
  }
}

// MARK: - Word count

/// The card's title row states how much text is in the box. It counts what a
/// person counts when they glance at a paragraph — whitespace-separated runs —
/// so an identifier is one word, not the three its punctuation splits it into.
final class ReviewWordCountTests: XCTestCase {
  func testAnEmptyBoxHasNoWords() {
    XCTAssertEqual(DictationReview.wordCount(""), 0)
    XCTAssertEqual(DictationReview.wordCount("   \n "), 0)
  }

  func testWordsAreWhitespaceSeparatedRuns() {
    XCTAssertEqual(DictationReview.wordCount("Ship the patch."), 3)
    XCTAssertEqual(DictationReview.wordCount("  Ship   the\npatch. "), 3)
  }

  func testAnIdentifierCountsOnce() {
    // `genc2rust` and `package.json` are one word each to the owner reading
    // them, however a linguistic word enumerator would split them.
    XCTAssertEqual(DictationReview.wordCount("Ship genc2rust and package.json"), 4)
  }
}

// MARK: - Learning from an owner edit

/// The end of the review path: an owner's correction reaches the dictionary as
/// a term whose spoken form is the exact wrong spelling they replaced, so L2
/// fixes it deterministically next session without a paid call.
final class ReviewEditLearningTests: XCTestCase {
  private var url: URL!

  override func setUpWithError() throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("review-learn-\(UUID().uuidString)")
      .appendingPathComponent("dictionary.json")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }

  /// The controller's learn step, run against a temp dictionary.
  private func learn(_ pair: DictationReview.LearnPair) throws {
    for candidate in AutoLearn.candidates(before: pair.before, after: pair.after) {
      try DictionaryStore.add(
        candidate.term,
        spokenForms: [candidate.spokenForm],
        source: .learned,
        at: url
      )
    }
  }

  func testTheReplacedFormIsStoredAsASpokenForm() throws {
    // Polish left the mishearing alone; the owner fixed it in the panel.
    let resolution = DictationReview.resolve(
      polished: "Ship the gency to rust patch.",
      offline: "Ship the gency to rust patch.",
      decision: .apply("Ship the genc2rust patch.")
    )
    for pair in resolution.learn { try learn(pair) }

    let stored = DictionaryStore.load(from: url)
    XCTAssertEqual(stored.map(\.term), ["genc2rust"])
    XCTAssertEqual(stored.first?.spokenForms, ["gency to rust"])
    XCTAssertEqual(stored.first?.source, .learned)
  }

  func testADiscardedPanelTeachesNothing() throws {
    let resolution = DictationReview.resolve(
      polished: "Ship the gency to rust patch.",
      offline: "Ship the gency to rust patch.",
      decision: .discard
    )
    for pair in resolution.learn { try learn(pair) }
    XCTAssertEqual(DictionaryStore.load(from: url), [])
  }

  func testProseTheOwnerRewroteIsStillRefused() throws {
    // A human edit is a reason to trust a correction, not a reason to let
    // ordinary words into the dictionary — every stored term biases every
    // later session's recognition.
    let resolution = DictationReview.resolve(
      polished: "The cat sat down.",
      offline: "The cat sat down.",
      decision: .apply("The dog sat down.")
    )
    for pair in resolution.learn { try learn(pair) }
    XCTAssertEqual(DictionaryStore.load(from: url), [])
  }
}

// MARK: - HUD

final class ReviewHUDTests: XCTestCase {
  func testThePillHidesWhileTheReviewPanelIsOpen() {
    // The panel is the feedback. Without this the pill would sit under it
    // showing a success snippet for text that has not been inserted.
    XCTAssertEqual(
      HUDState.compute(
        controllerState: .idle,
        isPolishInProgress: false,
        lastPolishWarning: "Polish failed: offline.",
        lastSecureFieldNotice: nil,
        lastProcessedText: "Ship the genc2rust patch.",
        rmsLevel: 0,
        isReviewing: true
      ),
      .hidden
    )
  }

  func testTheHUDIsUnchangedWhenNoReviewIsOpen() {
    XCTAssertEqual(
      HUDState.compute(
        controllerState: .idle,
        isPolishInProgress: false,
        lastPolishWarning: nil,
        lastSecureFieldNotice: nil,
        lastProcessedText: "Ship it.",
        rmsLevel: 0,
        isReviewing: false
      ),
      .success(snippet: "Ship it.")
    )
  }
}

// MARK: - What a session asks the recognizer for

/// Review and streaming share the live recognizer and share nothing else. The
/// owner finding: with review on the batch recognizer there was no volatile
/// feed, so the pill sat empty for the whole session.
final class DictationSessionPlanTests: XCTestCase {
  func testReviewRunsTheStreamingRecognizerButDeliversNothingMidSession() {
    let plan = DictationSessionPlan.make(mode: .review, engine: .apple)
    XCTAssertTrue(plan.wantsLiveDraft, "the pill is the only feedback while the owner talks")
    XCTAssertFalse(plan.deliversMidSession, "review inserts nothing until Apply")
    XCTAssertTrue(plan.capturesTarget, "Apply needs the pid the hotkey went down on")
  }

  func testStreamingStillDeliversWhileSpeaking() {
    let plan = DictationSessionPlan.make(mode: .streaming, engine: .apple)
    XCTAssertTrue(plan.wantsLiveDraft)
    XCTAssertTrue(plan.deliversMidSession)
    XCTAssertTrue(plan.capturesTarget)
  }

  func testImmediateAsksForNeither() {
    let plan = DictationSessionPlan.make(mode: .immediate, engine: .apple)
    XCTAssertFalse(plan.wantsLiveDraft)
    XCTAssertFalse(plan.deliversMidSession)
    XCTAssertFalse(plan.capturesTarget, "batch delivery captures at injection time")
  }

  func testAssemblyAIGetsNoLiveDraftInEitherMode() {
    // Whole formatted turns, not deltas: there is no volatile tail to show and
    // no segment to accumulate.
    for mode in [DeliveryMode.streaming, .review] {
      let plan = DictationSessionPlan.make(mode: mode, engine: .assemblyAIRealtime)
      XCTAssertFalse(plan.wantsLiveDraft, "\(mode)")
      XCTAssertFalse(plan.deliversMidSession, "\(mode)")
    }
  }

  func testReviewStillCapturesTheTargetOnAnEngineWithNoLiveDraft() {
    // The pid is what Apply injects through, however the audio was recognized.
    XCTAssertTrue(
      DictationSessionPlan.make(mode: .review, engine: .assemblyAIRealtime).capturesTarget
    )
  }
}

// MARK: - The controller's review branch

/// Stands in for the panel so the branch runs with no window server: which
/// requests were presented, and how often it was told to take one down.
@MainActor
final class StubReviewPresenter: DictationReviewPresenting {
  private(set) var presented: [DictationReviewRequest] = []
  private(set) var dismissCount = 0
  var isPresenting = false
  /// The zombie-WindowServer case the real presenter reports by returning
  /// false: the card never reached the screen and no decision will ever come.
  var canPresent = true

  var latest: DictationReviewRequest? { presented.last }

  @discardableResult
  func present(_ request: DictationReviewRequest) -> Bool {
    presented.append(request)
    isPresenting = canPresent
    return canPresent
  }

  func dismiss() {
    dismissCount += 1
    isPresenting = false
  }
}

/// The half of review delivery that lives in the controller: what opens a
/// panel, what `isReviewing` says while one is open, and which decisions are
/// still allowed to land.
@MainActor
final class DictationReviewBranchTests: XCTestCase {
  private var presenter: StubReviewPresenter!

  override func setUp() {
    super.setUp()
    presenter = StubReviewPresenter()
  }

  override func tearDown() {
    presenter = nil
    DictationSettingsStore.reset()
    super.tearDown()
  }

  /// The controller reads its settings once, at init, so the mode has to be in
  /// the store before it is built.
  private func makeController(_ mode: DeliveryMode) -> DictationController {
    var settings = DictationSettings()
    settings.deliveryMode = mode
    DictationSettingsStore.save(settings)
    return DictationController(review: presenter)
  }

  /// A target the session wiring can actually build a delivery queue against —
  /// without one, "no queue was built" says nothing about the mode.
  private var target: FocusedTarget {
    FocusedTarget(
      bundleID: "com.apple.TextEdit",
      isSecureInput: false,
      accessibilityElement: nil,
      processID: 4242
    )
  }

  /// The live recognizer, in the mode that must not act on it. A volatile
  /// result is a rough draft for the pill; a finalized one accumulates. Neither
  /// reaches the target app — there is nowhere for it to go until Apply.
  func testAReviewSessionShowsADraftAndAccumulatesWithoutInsertingAnything() {
    let controller = makeController(.review)
    controller.beginSessionForTests(target: target)
    XCTAssertFalse(controller.deliversMidSessionForTests, "review builds no delivery queue")

    controller.handleHypothesis(Hypothesis(text: "ship the gency to", isFinal: false))
    XCTAssertEqual(controller.roughDraft, "ship the gency to")
    XCTAssertNil(controller.lastProcessedText, "a rough draft is not an insertion")

    controller.handleHypothesis(
      Hypothesis(text: "Ship the genc2rust patch.", isFinal: true, isSegment: true)
    )
    XCTAssertEqual(controller.roughDraft, "", "the tail this finalized is no longer a draft")
    XCTAssertEqual(controller.recognizedSoFarForTests, "Ship the genc2rust patch.")

    controller.handleHypothesis(
      Hypothesis(text: "Then land it.", isFinal: true, isSegment: true)
    )
    XCTAssertEqual(
      controller.recognizedSoFarForTests,
      "Ship the genc2rust patch. Then land it.",
      "segments accumulate in spoken order"
    )
    XCTAssertNil(controller.lastProcessedText, "nothing was inserted mid-session")
    XCTAssertFalse(controller.isReviewing, "the panel opens on stop, not per segment")
  }

  /// The counterweight: the same session wiring, one mode over, DOES build a
  /// queue. Without this the assertion above passes on a hook that could never
  /// build one, whatever the mode said.
  func testTheSameSessionWiringBuildsAQueueForStreaming() {
    let controller = makeController(.streaming)
    controller.beginSessionForTests(target: target)

    XCTAssertTrue(
      controller.deliversMidSessionForTests,
      "streaming delivers mid-session — if this is nil the review assertion proves nothing"
    )
  }

  /// The default mode never grew a live draft: its recognizer reports whole
  /// hypotheses, and the pill stays a meter.
  func testImmediateModeStillHasNoRoughDraft() {
    let controller = makeController(.immediate)
    controller.handleHypothesis(Hypothesis(text: "ship the patch", isFinal: false))

    XCTAssertEqual(controller.roughDraft, "")
    XCTAssertEqual(controller.lastHypothesis, "ship the patch")
  }

  func testReviewModeOpensThePanelAndInsertsNothing() {
    let controller = makeController(.review)
    controller.deliver("Ship the genc2rust patch.", offline: "Ship the patch.", latency: 1)

    XCTAssertEqual(presenter.presented.count, 1)
    XCTAssertEqual(presenter.latest?.text, "Ship the genc2rust patch.")
    XCTAssertTrue(controller.isReviewing)
    // The HUD's success snippet reads this field; nothing has been inserted.
    XCTAssertNil(controller.lastProcessedText)
  }

  /// The zombie-WindowServer case (`orderFrontRegardless` with
  /// `windowNumber == 0`, as on 2026-07-27). The card is a review session's
  /// only output and `isReviewing` suppresses the pill while one is open, so a
  /// swallowed failure here is a session with no card, no pill and no error —
  /// and the next hotkey press throws the text away.
  func testAPanelThatNeverReachedTheScreenIsReportedInsteadOfWaitedOn() {
    let controller = makeController(.review)
    presenter.canPresent = false
    controller.deliver("Ship the genc2rust patch.", offline: "Ship the patch.", latency: 1)

    XCTAssertFalse(controller.isReviewing, "no decision can ever come — the pill must come back")
    XCTAssertEqual(
      controller.state,
      .failed(message: "Nota could not show the review card. Restart Nota to fix it.")
    )
    XCTAssertNil(controller.lastProcessedText, "the mode still inserted nothing")
  }

  func testImmediateModeNeverOpensThePanel() {
    let controller = makeController(.immediate)
    controller.deliver("Ship it.", offline: "Ship it.", latency: 1)

    XCTAssertTrue(presenter.presented.isEmpty)
    XCTAssertFalse(controller.isReviewing)
  }

  func testAnEmptyResultOpensNoPanel() {
    let controller = makeController(.review)
    controller.deliver("   \n ", offline: "", latency: 1)

    XCTAssertTrue(presenter.presented.isEmpty)
    XCTAssertFalse(controller.isReviewing)
    XCTAssertEqual(controller.state, .idle)
  }

  /// The defect this covers is invisible from the panel: a discard that never
  /// reaches the controller leaves `isReviewing` true forever, and the pill
  /// stays suppressed for every session after it.
  func testADiscardEndsTheReviewAndLetsTheHUDBack() {
    let controller = makeController(.review)
    controller.deliver("Ship the genc2rust patch.", offline: "Ship the patch.", latency: 1)
    presenter.latest?.onDiscard()

    XCTAssertFalse(controller.isReviewing)
    XCTAssertEqual(controller.state, .idle)
    XCTAssertNil(controller.lastProcessedText)
    XCTAssertEqual(presenter.dismissCount, 1)
  }

  /// No session ran, so there is no captured target. Applying must refuse
  /// rather than type the text into whatever is frontmost — which, right after
  /// the panel closes, is Nota.
  func testApplyWithNoCapturedTargetRefusesToInsertAnywhere() {
    let controller = makeController(.review)
    controller.deliver("Ship the genc2rust patch.", offline: "Ship the patch.", latency: 1)
    presenter.latest?.onApply("Ship the genc2rust patch.")

    XCTAssertFalse(controller.isReviewing)
    XCTAssertEqual(
      controller.state,
      .failed(message: "Nota lost track of the app you were dictating into.")
    )
  }

  func testANewReviewCancelsTheOpenOneWithoutInserting() {
    let controller = makeController(.review)
    controller.deliver("First session.", offline: "First session.", latency: 1)
    let stale = presenter.latest
    controller.deliver("Second session.", offline: "Second session.", latency: 1)

    XCTAssertEqual(presenter.presented.count, 2)
    XCTAssertEqual(presenter.presented.first?.text, "First session.")
    XCTAssertEqual(presenter.latest?.text, "Second session.")
    XCTAssertTrue(controller.isReviewing, "the second review is the open one")
    XCTAssertNil(controller.lastProcessedText, "the cancelled session inserted nothing")
    XCTAssertNotNil(stale)
  }

  /// The panel outlives the session that filled it, so a decision can arrive
  /// after another session has taken over. It carries that review's id for the
  /// same reason the streaming path carries an epoch.
  func testADecisionFromASupersededReviewIsIgnored() {
    let controller = makeController(.review)
    controller.deliver("First session.", offline: "First session.", latency: 1)
    let stale = presenter.latest
    controller.deliver("Second session.", offline: "Second session.", latency: 1)

    stale?.onApply("First session, edited.")
    XCTAssertTrue(controller.isReviewing, "the second review is still waiting")
    XCTAssertNil(controller.lastProcessedText)
    XCTAssertEqual(controller.state, .idle, "a stale apply must not report a failure either")

    stale?.onDiscard()
    XCTAssertTrue(controller.isReviewing, "a stale discard must not close the live review")
  }
}

// MARK: - The presenter

/// Every route out of the panel has to deliver exactly one decision. The close
/// button is the one that had no test and no callback: the panel disappeared
/// while the controller went on believing a review was open.
@MainActor
final class DictationReviewPresenterTests: XCTestCase {
  private func request(
    onApply: @escaping (String) -> Void = { text in XCTFail("unexpected apply: \(text)") },
    onDiscard: @escaping () -> Void = { XCTFail("unexpected discard") }
  ) -> DictationReviewRequest {
    DictationReviewRequest(
      text: "Ship the genc2rust patch.",
      onApply: onApply,
      onDiscard: onDiscard
    )
  }

  func testTheCloseButtonDeliversItsDiscard() {
    let presenter = DictationReviewPresenter()
    var discards = 0
    XCTAssertTrue(
      presenter.present(request(onDiscard: { discards += 1 })),
      "the card reached the screen"
    )
    XCTAssertTrue(presenter.isPresenting)

    presenter.windowWillClose(Notification(name: NSWindow.willCloseNotification))

    XCTAssertEqual(discards, 1)
    XCTAssertFalse(presenter.isPresenting)
  }

  func testDismissDeliversItsDiscardExactlyOnce() {
    let presenter = DictationReviewPresenter()
    var discards = 0
    presenter.present(request(onDiscard: { discards += 1 }))

    presenter.dismiss()
    presenter.dismiss()
    presenter.windowWillClose(Notification(name: NSWindow.willCloseNotification))

    XCTAssertEqual(discards, 1)
    XCTAssertFalse(presenter.isPresenting)
  }

  /// A second present without a decision would strand the first session's text.
  func testPresentingAgainDiscardsWhatWasAlreadyUp() {
    let presenter = DictationReviewPresenter()
    var discards = 0
    presenter.present(request(onDiscard: { discards += 1 }))
    presenter.present(request(onDiscard: { discards += 1 }))

    XCTAssertEqual(discards, 1, "only the superseded review is discarded")
    XCTAssertTrue(presenter.isPresenting)

    presenter.dismiss()
    XCTAssertEqual(discards, 2)
  }
}

// MARK: - The panel itself

/// The panel takes typing without Nota ever becoming the active app. Both
/// halves are load-bearing and they pull against each other: drop
/// `.nonactivatingPanel` and opening a review raises Nota's home window over
/// the app being dictated into; drop `canBecomeKey` and the owner is looking at
/// an editor they cannot type in.
@MainActor
final class DictationReviewPanelTests: XCTestCase {
  private func makePanel(_ text: String = "Ship the gency to rust patch.")
    -> (DictationReviewPanel, DictationReviewModel) {
    let model = DictationReviewModel()
    model.text = text
    let panel = DictationReviewPanel(model: model)
    panel.sizeToFitContent()
    return (panel, model)
  }

  /// Give AppKit/SwiftUI turns of the run loop until `condition` holds.
  @discardableResult
  private func spin(
    until condition: () -> Bool,
    timeout: TimeInterval = 2
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return condition()
  }

  /// `present()` really does produce a visible key window under this mask.
  ///
  /// Honest about its reach: the test host is itself the active app, so this
  /// proves the order-front + make-key wiring, not the "while another app is
  /// frontmost" half — that one is the `.nonactivatingPanel` bit asserted below
  /// plus the absence of any `NSApp.activate` on the path, and it is the piece
  /// the owner smoke-tests live.
  func testPresentingProducesAVisibleKeyPanel() {
    let (panel, _) = makePanel()
    defer { panel.orderOut(nil) }

    XCTAssertTrue(panel.present(), "present() reports whether the card reached the screen")

    XCTAssertTrue(panel.isVisible)
    XCTAssertTrue(panel.isKeyWindow)
    XCTAssertTrue(panel.verifyWindowDevice(), "a card with no window device is a lost session")
  }

  func testThePanelIsNonactivatingAndStillTakesKey() {
    let (panel, _) = makePanel()
    defer { panel.orderOut(nil) }

    XCTAssertTrue(
      panel.styleMask.contains(.nonactivatingPanel),
      "without this, showing the panel activates Nota and surfaces the home window"
    )
    XCTAssertTrue(panel.canBecomeKey, "the owner types in this panel")
    XCTAssertFalse(panel.canBecomeMain, "main belongs to the active app, which Nota never becomes")
  }

  /// The mask's whole risk: a nonactivating borderless panel that cannot route
  /// keystrokes into its editor. This types into the same `NSTextView` the
  /// owner would and checks the text came back through the binding.
  func testTypingLandsInTheEditorUnderTheNonactivatingMask() throws {
    let (panel, model) = makePanel("Ship the patch")
    defer { panel.orderOut(nil) }
    panel.present()

    XCTAssertTrue(
      spin(until: { DictationReviewPanel.firstTextView(in: panel.contentView) != nil }),
      "the card never built an editor"
    )
    let editor = try XCTUnwrap(DictationReviewPanel.firstTextView(in: panel.contentView))
    XCTAssertTrue(editor.isEditable)
    XCTAssertTrue(panel.focusEditor(), "the editor refused first responder")
    XCTAssertTrue(
      panel.firstResponder === editor || panel.firstResponder === editor.window?.firstResponder,
      "first responder is \(String(describing: panel.firstResponder))"
    )

    editor.insertText("!", replacementRange: NSRange(location: editor.string.count, length: 0))
    XCTAssertTrue(
      spin(until: { model.text.hasSuffix("!") }),
      "typed text never reached the model: \(model.text)"
    )
  }

  /// Word count and Apply/Discard read the same string the owner edits.
  func testTheModelCarriesWhatTheOwnerTyped() throws {
    let (panel, model) = makePanel("Ship the patch")
    defer { panel.orderOut(nil) }
    panel.present()

    XCTAssertTrue(spin(until: { DictationReviewPanel.firstTextView(in: panel.contentView) != nil }))
    let editor = try XCTUnwrap(DictationReviewPanel.firstTextView(in: panel.contentView))
    editor.insertText(
      " today",
      replacementRange: NSRange(location: editor.string.count, length: 0)
    )
    XCTAssertTrue(spin(until: { DictationReview.wordCount(model.text) == 4 }))

    var applied: String?
    model.onApply = { applied = $0 }
    model.apply()
    XCTAssertEqual(applied, "Ship the patch today")
  }
}
