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

  func testTheLegacyBoolIsNotWrittenBackOut() throws {
    var settings = DictationSettings()
    settings.deliveryMode = .review
    let json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
    XCTAssertFalse(json.contains("streamingDelivery"))
    XCTAssertTrue(json.contains("review"))
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
