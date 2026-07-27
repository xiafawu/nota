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
    presenter.present(request(onDiscard: { discards += 1 }))
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
