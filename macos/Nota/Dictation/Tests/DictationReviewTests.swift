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

  /// One session, one surface (owner call 2026-08-03): while the card is up
  /// the HUD stays down even for a continuation — the card's own header
  /// carries the mic dot and "Listening…", and a second panel narrating the
  /// same microphone read as two HUDs.
  func testThePillStaysDownWhileAContinuationIsRecording() {
    XCTAssertEqual(
      HUDState.compute(
        controllerState: .listening,
        isPolishInProgress: false,
        lastPolishWarning: nil,
        lastSecureFieldNotice: nil,
        lastProcessedText: nil,
        rmsLevel: 0.4,
        isReviewing: true
      ),
      .hidden
    )
    XCTAssertEqual(
      HUDState.compute(
        controllerState: .finalizing,
        isPolishInProgress: true,
        lastPolishWarning: nil,
        lastSecureFieldNotice: nil,
        lastProcessedText: nil,
        rmsLevel: 0,
        isReviewing: true
      ),
      .hidden
    )
  }

  /// The idle-derived states stay suppressed too: a success snippet speaks
  /// for text that is still sitting in the card, uninserted.
  func testTheSuccessSnippetStaysSuppressedDuringAContinuation() {
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

  /// The last exception is gone (owner call 2026-08-03, "one pill only"). A
  /// failure used to come out on the pill because "a review card has nowhere to
  /// put an error"; the card has a status line now, and the controller mirrors
  /// `state` into it. The pill is down for the WHOLE lifecycle of a card.
  func testEvenAFailureStaysOffThePillWhileACardIsOpen() {
    XCTAssertEqual(
      HUDState.compute(
        controllerState: .failed(message: "Microphone unavailable"),
        isPolishInProgress: false,
        lastPolishWarning: nil,
        lastSecureFieldNotice: nil,
        lastProcessedText: nil,
        rmsLevel: 0,
        isReviewing: false
      ),
      .error(message: "Microphone unavailable"),
      "with no card, the pill is still where a failure goes"
    )
    XCTAssertEqual(
      HUDState.compute(
        controllerState: .failed(message: "Microphone unavailable"),
        isPolishInProgress: false,
        lastPolishWarning: nil,
        lastSecureFieldNotice: nil,
        lastProcessedText: nil,
        rmsLevel: 0,
        isReviewing: true
      ),
      .hidden,
      "with a card, the card says it — two surfaces for one session is the bug"
    )
  }

  /// `isReviewing` is exactly "a card exists", which is what makes the split
  /// above total rather than a hole: every controller state a review session
  /// can be in is suppressed, and the only way for one to reach the pill is for
  /// there to be no card to put it on.
  func testNoControllerStateSurvivesAnOpenCard() {
    let states: [DictationState] = [
      .idle,
      .listening,
      .finalizing,
      .injecting,
      .failed(message: "boom"),
      .disabled(reason: "no microphone"),
    ]
    for state in states {
      XCTAssertEqual(
        HUDState.compute(
          controllerState: state,
          isPolishInProgress: true,
          lastPolishWarning: "Polish failed: offline.",
          lastSecureFieldNotice: "Secure field",
          lastProcessedText: "Ship it.",
          rmsLevel: 0.9,
          isReviewing: true
        ),
        .hidden,
        "\(state) reached the pill while a card was up"
      )
    }
  }
}

// MARK: - The ⌘↩ gate

/// The bounded wait that keeps the owner's own held modifiers out of Nota's
/// synthetic keystrokes.
///
/// This is the pure half of the ⌘↩ fix (2026-07-28): with the review card open,
/// the shortcut took the card down and inserted nothing while the Apply button
/// inserted fine. Both routes run identical code; what differed was that the
/// owner's ⌘ was physically down on one of them, and a `CGEvent` built from
/// `.combinedSessionState` inherits the real keyboard's modifiers — so the
/// keystroke carrying the text arrived tagged as a command and was dispatched
/// as a shortcut instead of inserted.
final class ModifierClearanceTests: XCTestCase {
  private let command = CGEventFlags.maskCommand

  func testCommandControlAndOptionBlockButShiftDoesNot() {
    XCTAssertTrue(ModifierClearance.isBlocked(.maskCommand))
    XCTAssertTrue(ModifierClearance.isBlocked(.maskControl))
    XCTAssertTrue(ModifierClearance.isBlocked(.maskAlternate))
    XCTAssertFalse(ModifierClearance.isBlocked([]))
    // Nota posts a Unicode payload, not a virtual key, so shift cannot change
    // what the target reads — and waiting on it would delay every capitalized
    // sentence for nothing.
    XCTAssertFalse(ModifierClearance.isBlocked(.maskShift))
  }

  /// The Apply *button*'s case, and the common one: nothing is held, so nothing
  /// is waited for.
  func testAnUnheldKeyboardNeverSleeps() async {
    var sleeps = 0
    let outcome = await ModifierClearance.wait(
      flags: { [] },
      sleep: { _ in sleeps += 1 }
    )
    XCTAssertEqual(outcome, .alreadyClear)
    XCTAssertEqual(sleeps, 0)
  }

  func testItReturnsAsSoonAsTheModifierComesUp() async {
    var polls = 0
    let outcome = await ModifierClearance.wait(
      timeoutNs: 500_000_000,
      pollIntervalNs: 10_000_000,
      flags: {
        defer { polls += 1 }
        // Down for the initial check and the first two polls.
        return polls < 3 ? self.command : []
      },
      sleep: { _ in }
    )
    XCTAssertEqual(outcome, .cleared(afterNs: 30_000_000))
  }

  /// A stuck modifier may delay the text and never swallow it.
  func testAHeldModifierIsBoundedAndTheTextGoesAnyway() async {
    var slept: UInt64 = 0
    let outcome = await ModifierClearance.wait(
      timeoutNs: 500_000_000,
      pollIntervalNs: 10_000_000,
      flags: { self.command },
      sleep: { slept += $0 }
    )
    XCTAssertEqual(outcome, .timedOut(afterNs: 500_000_000))
    XCTAssertEqual(slept, 500_000_000, "the cap is a cap on real time, not on polls")
  }

  /// A poll interval longer than the cap must not overshoot it.
  func testTheLastSliceIsTrimmedToTheCap() async {
    var slept: UInt64 = 0
    let outcome = await ModifierClearance.wait(
      timeoutNs: 25_000_000,
      pollIntervalNs: 10_000_000,
      flags: { self.command },
      sleep: { slept += $0 }
    )
    XCTAssertEqual(outcome, .timedOut(afterNs: 25_000_000))
    XCTAssertEqual(slept, 25_000_000)
  }

  /// What the target app actually receives, read back through AppKit.
  ///
  /// This is the shape of the ⌘↩ failure. `TextInjector` builds one keyboard
  /// event carrying the whole text as a Unicode payload, from a
  /// `CGEventSource(stateID: .combinedSessionState)` — a source whose state
  /// includes the physical keyboard — and used to assign no `flags` at all.
  /// The modifier the owner is still holding therefore rode along, and what
  /// arrived was a ⌘-tagged key-down: a **key equivalent**, which an app routes
  /// to menu/shortcut dispatch instead of inserting. Below, the same event is
  /// read the way AppKit reads it: the characters are right there, and so is
  /// the ⌘ that stops them being typed.
  ///
  /// The physically-held modifier cannot be staged from a test — synthesizing
  /// one means posting a global `flagsChanged` — so the flag is set directly.
  /// That is the same bit the source hands over, which is the point. The
  /// second half is the fix: an explicit assignment wins whatever the keyboard
  /// is doing, and it is what `tryCGEventInject` now does.
  func testAUnicodeKeystrokeCarryingCommandReadsAsAShortcutNotAsText() throws {
    let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
    let event = try XCTUnwrap(
      CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
    )
    let payload = Array("hello".utf16)
    payload.withUnsafeBufferPointer { buffer in
      event.keyboardSetUnicodeString(
        stringLength: payload.count,
        unicodeString: buffer.baseAddress
      )
    }

    event.flags = .maskCommand
    let tagged = try XCTUnwrap(NSEvent(cgEvent: event))
    XCTAssertEqual(tagged.characters, "hello", "the text is right there…")
    XCTAssertTrue(
      tagged.modifierFlags.contains(.command),
      "…and so is the ⌘ that makes it a key equivalent rather than text"
    )
    XCTAssertTrue(ModifierClearance.isBlocked(event.flags))

    event.flags = []
    let plain = try XCTUnwrap(NSEvent(cgEvent: event))
    XCTAssertEqual(plain.characters, "hello")
    XCTAssertFalse(
      plain.modifierFlags.contains(.command),
      "zeroing the flags is what makes a text-carrying keystroke never a shortcut"
    )
    XCTAssertFalse(ModifierClearance.isBlocked(event.flags))
  }

  /// A zero interval would otherwise spin forever against a held key.
  func testAZeroPollIntervalStillTerminates() async {
    let outcome = await ModifierClearance.wait(
      timeoutNs: 1_000,
      pollIntervalNs: 0,
      flags: { self.command },
      sleep: { _ in }
    )
    XCTAssertEqual(outcome, .timedOut(afterNs: 1_000))
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

  func testAssemblyAIGetsALiveDraftButNoMidSessionDelivery() {
    // AssemblyAI streams partial Turns in every delivery mode, so the HUD
    // rough draft is always available; nothing can be delivered
    // sentence-by-sentence (no deltas), so mid-session delivery stays off.
    for mode in DeliveryMode.allCases {
      let plan = DictationSessionPlan.make(mode: mode, engine: .assemblyAIRealtime)
      XCTAssertTrue(plan.wantsLiveDraft, "\(mode)")
      XCTAssertFalse(plan.deliversMidSession, "\(mode)")
    }
    XCTAssertTrue(
      DictationSessionPlan.make(mode: .review, engine: .assemblyAIRealtime).capturesTarget
    )
    XCTAssertFalse(
      DictationSessionPlan.make(mode: .immediate, engine: .assemblyAIRealtime).capturesTarget
    )
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
  /// A card that is no longer there to write into — the case that sends a
  /// continuation down the open-a-fresh-review path instead of losing the batch.
  var canEdit = true
  /// What the owner has in the box, edits and all.
  var buffer: String?
  /// Whether the card is showing that a continuation is recording into it.
  private(set) var isShowingListening = false
  private(set) var listeningChanges: [Bool] = []
  /// The live draft the card is currently showing, and every value it was ever
  /// handed — a draft that arrived and was cleared reads the same as one that
  /// never arrived, and the two are different bugs.
  private(set) var draft: HUDDraft = .empty
  private(set) var draftUpdates: [HUDDraft] = []
  /// The failure the card is showing in its status line, and every value it was
  /// ever handed — the card is a review session's only surface, so an error that
  /// arrived and was cleared is a different bug from one that never arrived.
  private(set) var errorMessage: String?
  private(set) var errorUpdates: [String?] = []
  /// What the card's Finish button is wired to. The controller installs it at
  /// init, so a test can press Finish without a microphone or an event tap.
  var onFinishRecording: (() -> Void)?

  var latest: DictationReviewRequest? { presented.last }

  /// The owner pressing Finish (or ⌘↩ while the card records).
  func pressFinish() { onFinishRecording?() }

  @discardableResult
  func present(_ request: DictationReviewRequest) -> Bool {
    presented.append(request)
    isPresenting = canPresent
    buffer = canPresent ? request.text : nil
    isShowingListening = false
    draft = .empty
    errorMessage = nil
    return canPresent
  }

  var editorText: String? {
    guard isPresenting, canEdit else { return nil }
    return buffer
  }

  @discardableResult
  func replaceEditorText(_ text: String) -> Bool {
    guard isPresenting, canEdit else { return false }
    buffer = text
    return true
  }

  func setListening(_ listening: Bool) {
    guard isPresenting else { return }
    isShowingListening = listening
    listeningChanges.append(listening)
  }

  func setDraft(_ draft: HUDDraft) {
    guard isPresenting else { return }
    self.draft = draft
    draftUpdates.append(draft)
  }

  func setError(_ message: String?) {
    guard isPresenting else { return }
    errorMessage = message
    errorUpdates.append(message)
  }

  func dismiss() {
    dismissCount += 1
    isPresenting = false
    isShowingListening = false
    draft = .empty
    errorMessage = nil
    buffer = nil
  }

  /// The owner typing in the card.
  func edit(_ text: String) { buffer = text }
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
    XCTAssertEqual(
      presenter.draft.volatileTail,
      "ship the gency to",
      "the FIRST session's draft is on the card, not on a pill"
    )
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
    XCTAssertTrue(
      controller.isReviewing,
      "the card is up from the press onwards — one surface for the whole session"
    )
    XCTAssertEqual(presenter.presented.count, 1, "and it is ONE card, opened once")
    XCTAssertEqual(presenter.buffer, "", "which nothing has been written into yet")
  }

  /// The mandate, stated as the thing that used to be false: in `.review` the
  /// card goes up when the hotkey goes down, so there is no stretch of a review
  /// session during which a *different* surface carries the live feedback.
  func testTheCardIsOnScreenBeforeAWordIsRecognized() {
    let controller = makeController(.review)
    XCTAssertFalse(controller.isReviewing, "nothing before the press")

    XCTAssertTrue(controller.beginOrOpenReviewCard())

    XCTAssertEqual(presenter.presented.count, 1)
    XCTAssertTrue(controller.isReviewing, "which is what keeps the pill down")
    XCTAssertTrue(presenter.isShowingListening, "and it opens in the recording state")
    XCTAssertTrue(controller.isReviewRecording)
    XCTAssertEqual(presenter.latest?.text, "", "empty: nothing has been said yet")
  }

  /// And nothing of it leaks into the modes that keep the HUD.
  func testNonReviewModesOpenNoCardAtSessionStart() {
    for mode in [DeliveryMode.immediate, .streaming] {
      let controller = makeController(mode)
      XCTAssertFalse(controller.beginOrOpenReviewCard(), "\(mode)")
      XCTAssertTrue(presenter.presented.isEmpty, "\(mode)")
      XCTAssertFalse(controller.isReviewing, "\(mode)")
      presenter = StubReviewPresenter()
    }
  }

  /// One card, two states, no swap: the same presented request carries the
  /// session from recording through to the decision. A second `present` would
  /// mean the recording surface and the deciding surface were different
  /// components after all.
  func testTheSameCardCarriesTheSessionFromRecordingToDeciding() {
    let controller = makeController(.review)
    controller.beginSessionForTests(target: target)
    let opened = controller.pendingReviewIDForTests
    XCTAssertTrue(presenter.isShowingListening)

    controller.deliver("Ship the genc2rust patch.", offline: "Ship the patch.", latency: 1)

    XCTAssertEqual(presenter.presented.count, 1, "no second card was ever presented")
    XCTAssertEqual(controller.pendingReviewIDForTests, opened, "same review, same callbacks")
    XCTAssertFalse(presenter.isShowingListening, "it is the deciding state now")
    XCTAssertEqual(presenter.buffer, "Ship the genc2rust patch.")
    XCTAssertTrue(presenter.draft.isEmpty, "and the live block is down")

    presenter.latest?.onApply("Ship the genc2rust patch.")
    XCTAssertEqual(controller.lastProcessedText, "Ship the genc2rust patch.")
    XCTAssertFalse(controller.isReviewing)
  }

  /// A session that opened a card and then heard nothing must not leave one
  /// sitting there: Apply is disabled on empty text, so the only decision left
  /// would be to throw away nothing.
  func testACardOpenedByASilentSessionGoesAway() {
    let controller = makeController(.review)
    controller.beginSessionForTests(target: target)
    XCTAssertTrue(controller.isReviewing)

    controller.deliver("   \n ", offline: "", latency: 1)

    XCTAssertFalse(controller.isReviewing, "the empty card is gone")
    XCTAssertEqual(presenter.dismissCount, 1)
    XCTAssertEqual(controller.state, .idle)
    XCTAssertNil(controller.lastProcessedText)
  }

  /// …unless the owner typed into it. A silent session is no reason to destroy
  /// text that is theirs.
  func testASilentSessionKeepsACardTheOwnerHasWrittenIn() {
    let controller = makeController(.review)
    controller.beginSessionForTests(target: target)
    presenter.edit("Something I typed myself.")

    controller.deliver("   \n ", offline: "", latency: 1)

    XCTAssertTrue(controller.isReviewing, "the owner's text is still in the box")
    XCTAssertEqual(presenter.dismissCount, 0)
    XCTAssertEqual(presenter.buffer, "Something I typed myself.")
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

  /// The AssemblyAI live draft folds finalized turns into the session draft as
  /// their own lines, so the growing pill keeps everything the user has said —
  /// a tail-only feed would blank every earlier sentence on each new turn.
  func testALiveDraftSessionFoldsFinalTurnsIntoGrowingLines() {
    var settings = DictationSettings()
    settings.deliveryMode = .immediate
    settings.engine = .assemblyAIRealtime
    DictationSettingsStore.save(settings)
    let controller = DictationController(review: presenter)
    controller.beginSessionForTests(target: target)

    controller.handleHypothesis(Hypothesis(text: "Send this one", isFinal: false))
    XCTAssertEqual(controller.roughDraft, "Send this one")
    XCTAssertEqual(controller.recognizedSoFarForTests, "")

    controller.handleHypothesis(Hypothesis(text: "Send this one.", isFinal: true))
    XCTAssertEqual(controller.roughDraft, "", "the finalized tail is no longer volatile")
    XCTAssertEqual(controller.recognizedSoFarForTests, "Send this one.")

    controller.handleHypothesis(Hypothesis(text: "Send this 2.", isFinal: true))
    XCTAssertEqual(
      controller.recognizedSoFarForTests,
      "Send this one.\nSend this 2.",
      "each finalized turn becomes its own line"
    )

    controller.handleHypothesis(Hypothesis(text: "Send this 3.", isFinal: false))
    XCTAssertEqual(controller.roughDraft, "Send this 3.")
    XCTAssertEqual(controller.recognizedSoFarForTests, "Send this one.\nSend this 2.")
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

  // MARK: - Continuation (plan 14)

  /// The rule this replaced: a trigger press used to discard the open card and
  /// the reviewed text went with it. "One more sentence" cost everything
  /// already reviewed, which made the mode worst exactly when it was working.
  func testAnotherSessionExtendsTheOpenReviewInsteadOfDiscardingIt() {
    let controller = makeController(.review)
    controller.deliver("Ship the patch.", offline: "Ship the patch.", latency: 1)
    let opened = controller.pendingReviewIDForTests

    XCTAssertTrue(controller.beginReviewContinuationIfOpen(), "a press with a card open extends it")
    XCTAssertTrue(presenter.isShowingListening)
    controller.deliver("Then land it.", offline: "Then land it.", latency: 2)

    XCTAssertEqual(presenter.presented.count, 1, "the card stayed — no second present")
    XCTAssertEqual(presenter.buffer, "Ship the patch. Then land it.")
    XCTAssertEqual(controller.pendingReviewIDForTests, opened, "extended, not replaced")
    XCTAssertEqual(controller.pendingReviewGenerationForTests, 1)
    XCTAssertFalse(presenter.isShowingListening, "the continuation's text has landed")
    XCTAssertNil(controller.lastProcessedText, "still nothing inserted")
  }

  /// The one thing a continuation may never do. The owner's corrections are
  /// theirs; the pipeline may add after them and must not regenerate them.
  func testAContinuationPreservesTheOwnersEditsVerbatim() {
    let controller = makeController(.review)
    controller.deliver("Ship the gency to rust patch.", offline: "Ship it.", latency: 1)
    presenter.edit("Ship the genc2rust patch.")

    controller.beginReviewContinuationIfOpen()
    controller.deliver("Then land it.", offline: "Then land it.", latency: 2)

    XCTAssertEqual(presenter.buffer, "Ship the genc2rust patch. Then land it.")
    // The pipeline's own accumulation is kept separately: it is the `before`
    // side of the diff Apply learns from, and it never sees the owner's edit.
    XCTAssertEqual(
      controller.pendingReviewPolishedForTests,
      "Ship the gency to rust patch. Then land it."
    )
    XCTAssertEqual(controller.pendingReviewOfflineForTests, "Ship it. Then land it.")
  }

  func testAContinuationThatHeardNothingLeavesTheCardAsItWas() {
    let controller = makeController(.review)
    controller.deliver("Ship the patch.", offline: "Ship the patch.", latency: 1)
    controller.beginReviewContinuationIfOpen()
    controller.deliver("   \n ", offline: "", latency: 2)

    XCTAssertTrue(controller.isReviewing, "an empty continuation must not close the card")
    XCTAssertEqual(presenter.buffer, "Ship the patch.")
    XCTAssertFalse(presenter.isShowingListening)
    XCTAssertEqual(presenter.dismissCount, 0)
  }

  /// Apply is about the whole batch, so while more of the batch is still being
  /// spoken there is nothing to decide about yet.
  func testApplyAndDiscardAreRefusedWhileAContinuationIsRecording() {
    let controller = makeController(.review)
    controller.deliver("Ship the patch.", offline: "Ship the patch.", latency: 1)
    controller.beginReviewContinuationIfOpen()

    presenter.latest?.onApply("Ship the patch.")
    XCTAssertTrue(controller.isReviewing, "the card is still holding the batch")
    XCTAssertNil(controller.lastProcessedText)

    presenter.latest?.onDiscard()
    XCTAssertTrue(controller.isReviewing, "a discard mid-recording throws the batch away")
    XCTAssertEqual(presenter.dismissCount, 0)
  }

  // MARK: - The card's live draft (XIA-406)

  /// The bug this fixes: with the pill suppressed for the whole time a card is
  /// up, a continuation's words appeared NOWHERE — the card said only
  /// "Listening…" while the owner talked.
  func testTheCardShowsTheContinuationsLiveDraft() {
    let controller = makeController(.review)
    controller.deliver("Ship the patch.", offline: "Ship the patch.", latency: 1)
    controller.beginReviewContinuationIfOpen()
    controller.beginSessionForTests(target: target)

    controller.handleHypothesis(Hypothesis(text: "then land", isFinal: false))
    XCTAssertEqual(presenter.draft.volatileTail, "then land", "the tail is live on the card")
    XCTAssertEqual(presenter.draft.finalized, "")

    controller.handleHypothesis(
      Hypothesis(text: "Then land it.", isFinal: true, isSegment: true)
    )
    XCTAssertEqual(presenter.draft.finalized, "Then land it.")
    XCTAssertEqual(presenter.draft.volatileTail, "", "the tail this finalized is gone")

    // Display only: the owner's buffer is untouched until stop.
    XCTAssertEqual(presenter.buffer, "Ship the patch.", "the draft never enters the editor")
  }

  /// The block belongs to a card, and only `.review` has one. This used to also
  /// exclude a review session's FIRST session, which is exactly the gap the
  /// unified card closed — see
  /// `testAReviewSessionShowsADraftAndAccumulatesWithoutInsertingAnything`.
  func testNoDraftReachesACardInANonReviewMode() {
    var settings = DictationSettings()
    settings.deliveryMode = .immediate
    settings.engine = .assemblyAIRealtime  // a mode+engine that DOES produce a draft
    DictationSettingsStore.save(settings)
    let controller = DictationController(review: presenter)
    controller.beginSessionForTests(target: target)
    controller.handleHypothesis(Hypothesis(text: "ship the patch", isFinal: false))

    XCTAssertFalse(controller.roughDraft.isEmpty, "the session did produce a draft")
    XCTAssertTrue(presenter.presented.isEmpty, "and there is no card in this mode")
    XCTAssertTrue(presenter.draftUpdates.isEmpty, "so nothing was published to one")
  }

  // MARK: - Where a failure goes (the pill's last exception)

  /// The pill is down for the whole life of a card, so the card has to be able
  /// to say that something went wrong — otherwise a review session fails in
  /// total silence. Driven off `state`, so no failure path has to remember.
  func testTheCardShowsAndThenClearsAFailure() {
    let controller = makeController(.review)
    controller.beginSessionForTests(target: target)
    XCTAssertNil(presenter.errorMessage)

    controller.failForTests("Microphone unavailable")
    XCTAssertEqual(presenter.errorMessage, "Microphone unavailable")

    controller.deliver("Ship the patch.", offline: "Ship the patch.", latency: 1)
    XCTAssertNil(presenter.errorMessage, "the card stops claiming a failure it recovered from")
  }

  /// With no card there is nothing to write to, and the pill is where the
  /// failure comes back out — `HUDState.compute` is the other half of this.
  func testAFailureWithNoCardTouchesNoCard() {
    let controller = makeController(.review)
    controller.failForTests("Microphone unavailable")

    XCTAssertTrue(presenter.errorUpdates.isEmpty)
    XCTAssertFalse(controller.isReviewing, "so the pill is free to say it")
  }

  /// The block goes when the microphone does — its words are about to be
  /// appended to the buffer, and two copies of them is one too many.
  func testTheDraftIsClearedWhenTheContinuationEnds() {
    let controller = makeController(.review)
    controller.deliver("Ship the patch.", offline: "Ship the patch.", latency: 1)
    controller.beginReviewContinuationIfOpen()
    controller.beginSessionForTests(target: target)
    controller.handleHypothesis(Hypothesis(text: "then land it", isFinal: false))
    XCTAssertFalse(presenter.draft.isEmpty)

    controller.deliver("Then land it.", offline: "Then land it.", latency: 2)

    XCTAssertTrue(presenter.draft.isEmpty, "the block is down")
    XCTAssertEqual(presenter.buffer, "Ship the patch. Then land it.", "and the text landed once")
  }

  /// "A finished session stops talking", at the card. A hypothesis stamped with
  /// a session that has been torn down is dropped rather than drawn on the card
  /// the next session is filling.
  func testAStaleSessionsHypothesisNeverReachesTheCard() {
    let controller = makeController(.review)
    controller.deliver("Ship the patch.", offline: "Ship the patch.", latency: 1)
    controller.beginReviewContinuationIfOpen()
    controller.beginSessionForTests(target: target)
    let stale = controller.sessionEpochForTests
    controller.handleHypothesis(Hypothesis(text: "then land it", isFinal: false), epoch: stale)
    XCTAssertEqual(presenter.draft.volatileTail, "then land it")

    controller.endSessionForTests()
    controller.handleHypothesis(
      Hypothesis(text: "words from a dead session", isFinal: false),
      epoch: stale
    )

    XCTAssertNotEqual(
      presenter.draft.volatileTail,
      "words from a dead session",
      "a torn-down session may not write to the card"
    )
    XCTAssertEqual(controller.roughDraft, "", "nor to the controller's own draft")
  }

  /// The owner may have moved to another app between the first session and the
  /// continuation. The app they were dictating into when they last spoke is
  /// the one they mean.
  func testTheNewestCaptureWinsTheTargetPid() {
    let controller = makeController(.review)
    controller.beginSessionForTests(target: target)
    controller.deliver("Ship the patch.", offline: "Ship the patch.", latency: 1)
    XCTAssertEqual(controller.pendingReviewTargetPIDForTests, 4242)

    controller.beginReviewContinuationIfOpen()
    controller.beginSessionForTests(
      target: FocusedTarget(
        bundleID: "com.apple.Notes",
        isSecureInput: false,
        accessibilityElement: nil,
        processID: 7777
      )
    )
    controller.deliver("Then land it.", offline: "Then land it.", latency: 2)

    XCTAssertEqual(controller.pendingReviewTargetPIDForTests, 7777)
  }

  /// A capture that failed is not an instruction to insert nowhere: the
  /// earlier session already found somewhere valid.
  func testAContinuationWithNoTargetKeepsTheOneThatWorked() {
    let controller = makeController(.review)
    controller.beginSessionForTests(target: target)
    controller.deliver("Ship the patch.", offline: "Ship the patch.", latency: 1)

    controller.beginReviewContinuationIfOpen()
    controller.beginSessionForTests(target: nil)
    controller.deliver("Then land it.", offline: "Then land it.", latency: 2)

    XCTAssertEqual(controller.pendingReviewTargetPIDForTests, 4242)
  }

  /// Newest capture wins — but "newest" has to mean one Apply could actually
  /// use. Nota's own pid is refused by `injectReviewed` *after* the card has
  /// been taken down, so letting one overwrite a working target destroys the
  /// whole batch. The owner opening Settings (or the menu-bar icon) before
  /// adding a sentence is exactly how a press captures Nota.
  func testAContinuationCapturedOnNotaItselfKeepsTheRealTarget() {
    let controller = makeController(.review)
    controller.beginSessionForTests(target: target)
    controller.deliver("Ship the patch.", offline: "Ship the patch.", latency: 1)

    controller.beginReviewContinuationIfOpen()
    controller.beginSessionForTests(
      target: FocusedTarget(
        bundleID: "com.xiafawu.nota",
        isSecureInput: false,
        accessibilityElement: nil,
        processID: ProcessInfo.processInfo.processIdentifier
      )
    )
    controller.deliver("Then land it.", offline: "Then land it.", latency: 2)

    XCTAssertEqual(controller.pendingReviewTargetPIDForTests, 4242, "the usable pid survived")

    presenter.latest?.onApply(presenter.buffer ?? "")
    XCTAssertEqual(
      controller.lastProcessedText,
      "Ship the patch. Then land it.",
      "the batch was still insertable"
    )
  }

  /// One decision, one batch: discarding after two sessions throws away both,
  /// and inserts nothing.
  func testDiscardDropsTheWholeBatch() {
    let controller = makeController(.review)
    controller.deliver("Ship the patch.", offline: "Ship the patch.", latency: 1)
    controller.beginReviewContinuationIfOpen()
    controller.deliver("Then land it.", offline: "Then land it.", latency: 2)

    presenter.latest?.onDiscard()

    XCTAssertFalse(controller.isReviewing)
    XCTAssertNil(controller.lastProcessedText)
    XCTAssertEqual(controller.state, .idle)
    XCTAssertEqual(presenter.dismissCount, 1)
  }

  /// The decision callbacks the card is holding were made for the FIRST
  /// session. A continuation keeps the review's id precisely so they stay
  /// valid — otherwise ⌘↩ after a continuation would be ignored as stale.
  func testTheOriginalCallbacksStillApplyTheWholeBatchAfterAContinuation() {
    let controller = makeController(.review)
    controller.beginSessionForTests(target: target)
    controller.deliver("Ship the patch.", offline: "Ship the patch.", latency: 1)
    let original = presenter.latest

    controller.beginReviewContinuationIfOpen()
    controller.deliver("Then land it.", offline: "Then land it.", latency: 2)

    original?.onApply(presenter.buffer ?? "")
    XCTAssertFalse(controller.isReviewing)
    XCTAssertEqual(controller.lastProcessedText, "Ship the patch. Then land it.")
  }

  // MARK: - Finish

  /// The card's Finish button reaches the controller, and what it reaches is the
  /// *stop* path — not a decision. Nothing is inserted, nothing is discarded, and
  /// the card is exactly where it was: the state it buys is the one in which a
  /// decision becomes possible at all.
  func testFinishEndsTheSessionAndDecidesNothing() {
    let controller = makeController(.review)
    controller.beginSessionForTests(target: target)
    XCTAssertTrue(controller.isReviewRecording)
    XCTAssertNotNil(presenter.onFinishRecording, "the controller wires the card's Finish button")

    presenter.pressFinish()

    XCTAssertTrue(controller.isReviewing, "Finish is not a decision — the card stays")
    XCTAssertNil(controller.lastProcessedText, "and nothing reached the target app")
    XCTAssertEqual(presenter.dismissCount, 0)
  }

  /// The buttons come back the moment the session's text lands, whichever route
  /// ended the session. This is the same `deliver` a trigger-key stop runs — the
  /// point of Finish calling `endCaptureAndFinalize` rather than a teardown of
  /// its own.
  func testAFinishedSessionLeavesTheCardDecidable() {
    let controller = makeController(.review)
    controller.beginSessionForTests(target: target)
    presenter.pressFinish()

    controller.deliver("Ship the patch.", offline: "Ship the patch.", latency: 1)

    XCTAssertFalse(controller.isReviewRecording, "the card offers Discard and Apply again")
    XCTAssertEqual(presenter.buffer, "Ship the patch.", "the batch is in the box, waiting")
    XCTAssertEqual(presenter.presented.count, 1, "still one card, extended not replaced")
  }

  /// A trigger press with no card open is an ordinary new session.
  func testNoOpenCardMeansNoContinuation() {
    let controller = makeController(.review)
    XCTAssertFalse(controller.beginReviewContinuationIfOpen())
    XCTAssertFalse(controller.isReviewRecording)
  }

  // MARK: - Extended vs superseded

  /// A card that is no longer there to write into. The batch must not be lost:
  /// a fresh card is opened carrying the accumulated text, and because it is a
  /// genuine REPLACEMENT it gets a new id — which is what makes a late decision
  /// from the old one ignorable.
  func testACardThatCannotBeEditedIsReplacedNotExtended() {
    let controller = makeController(.review)
    controller.deliver("Ship the patch.", offline: "Ship the patch.", latency: 1)
    let stale = presenter.latest
    let firstID = controller.pendingReviewIDForTests

    controller.beginReviewContinuationIfOpen()
    presenter.canEdit = false
    controller.deliver("Then land it.", offline: "Then land it.", latency: 2)

    XCTAssertEqual(presenter.presented.count, 2, "a fresh card was opened")
    XCTAssertEqual(
      presenter.latest?.text,
      "Ship the patch. Then land it.",
      "the fresh card carries the batch, not just the continuation"
    )
    XCTAssertEqual(
      controller.pendingReviewPolishedForTests,
      "Ship the patch. Then land it.",
      "the learn-from side accumulated too"
    )
    XCTAssertEqual(controller.pendingReviewOfflineForTests, "Ship the patch. Then land it.")
    XCTAssertNotEqual(controller.pendingReviewIDForTests, firstID, "superseded, not extended")
    XCTAssertTrue(controller.isReviewing)

    // The replaced card's callbacks are dead.
    stale?.onApply("Ship the patch, edited.")
    XCTAssertTrue(controller.isReviewing, "the live review is still waiting")
    XCTAssertNil(controller.lastProcessedText)
    XCTAssertEqual(controller.state, .idle, "a stale apply must not report a failure either")

    stale?.onDiscard()
    XCTAssertTrue(controller.isReviewing, "a stale discard must not close the live review")
  }

  // MARK: - The Delivery picker moving under an open card

  /// The card is nonactivating, so Settings opens over it and `reloadSettings`
  /// takes effect immediately. Only `.review` can ever fill a card, so a press
  /// in any other mode must not start a continuation — nothing would ever end
  /// it, and `finishReview` refuses every decision while one is running. It
  /// cancels the orphaned card instead, which is what plan 07 always did.
  func testAPressInANonReviewModeCancelsTheOpenCardRatherThanWedgingIt() {
    let controller = makeController(.review)
    controller.beginSessionForTests(target: target)
    controller.deliver("Ship the patch.", offline: "Ship the patch.", latency: 1)
    XCTAssertTrue(controller.isReviewing)

    switchDelivery(controller, to: .immediate)

    XCTAssertFalse(controller.beginReviewContinuationIfOpen(), "no card to continue in this mode")
    XCTAssertFalse(controller.isReviewRecording, "nothing is left waiting on a decision")
    XCTAssertFalse(controller.isReviewing, "the orphaned card is gone")
    XCTAssertEqual(presenter.dismissCount, 1)
    XCTAssertNil(controller.lastProcessedText, "cancelling a review inserts nothing")
  }

  /// The mode can also change while the continuation is *recording*, and then
  /// `deliver` never reaches `presentReview` — the only success-path clear of
  /// the listening flag. Without a backstop there the card would refuse ⌘↩ and
  /// Escape for the rest of the run.
  func testAModeChangeMidContinuationLeavesTheCardDecidable() {
    let controller = makeController(.review)
    controller.beginSessionForTests(target: target)
    controller.deliver("Ship the patch.", offline: "Ship the patch.", latency: 1)
    XCTAssertTrue(controller.beginReviewContinuationIfOpen())
    XCTAssertTrue(controller.isReviewRecording)

    switchDelivery(controller, to: .immediate)
    controller.deliver("Then land it.", offline: "Then land it.", latency: 2)

    XCTAssertFalse(controller.isReviewRecording, "the card is decidable again")
    XCTAssertEqual(controller.lastProcessedText, "Then land it.", "immediate mode inserted it")
    XCTAssertEqual(presenter.presented.count, 1, "no second card was opened")

    presenter.latest?.onDiscard()
    XCTAssertFalse(controller.isReviewing, "the decision the card was refusing now lands")
  }

  /// Both mode-change paths go through the store, because the controller reads
  /// its settings only at init and on `reloadSettings`.
  private func switchDelivery(_ controller: DictationController, to mode: DeliveryMode) {
    var settings = DictationSettings()
    settings.deliveryMode = mode
    DictationSettingsStore.save(settings)
    controller.reloadSettings()
  }
}

// MARK: - Appending a continuation to the card

/// The bound on the live draft the editor renders as a suffix. It is fed by a
/// string that grows for as long as the owner talks, redrawn many times a
/// second, on the main actor, inside the box they type into. These are the
/// things that stop it costing more as the session runs on.
final class ReviewDraftMetricsTests: XCTestCase {
  func testAShortDraftIsDrawnWhole() {
    let window = ReviewDraftMetrics.windowed(
      finalized: "Ship the patch.",
      volatileTail: "then land"
    )
    XCTAssertEqual(window.finalized, "Ship the patch.")
    XCTAssertEqual(window.volatileTail, "then land")
  }

  func testALongContinuationIsHeadTrimmedNotTailTrimmed() {
    let finalized = String(repeating: "a", count: ReviewDraftMetrics.windowBudget * 2)
    let window = ReviewDraftMetrics.windowed(finalized: finalized, volatileTail: "the newest words")

    XCTAssertEqual(window.volatileTail, "the newest words", "the tail is never cut")
    XCTAssertLessThanOrEqual(
      window.finalized.count + window.volatileTail.count,
      ReviewDraftMetrics.windowBudget + ReviewDraftMetrics.windowStep,
      "what is laid out stays bounded however long the continuation runs"
    )
    XCTAssertTrue(finalized.hasSuffix(window.finalized), "the cut came off the head")
  }

  /// Quantized, not sliding: greedy wrapping starts wherever the window starts,
  /// so a head that moved with every syllable would re-wrap every visible line
  /// on every tick.
  func testTheHeadMovesInStepsNotPerCharacter() {
    let base = ReviewDraftMetrics.windowBudget + 1
    let first = ReviewDraftMetrics.windowed(
      finalized: String(repeating: "a", count: base),
      volatileTail: ""
    )
    let later = ReviewDraftMetrics.windowed(
      finalized: String(repeating: "a", count: base + 10),
      volatileTail: ""
    )
    XCTAssertEqual(first.finalized.count, base, "under one step, nothing moved")
    XCTAssertEqual(later.finalized.count, base + 10, "still under one step")
  }

  /// The runs the card draws must concatenate to the string it was given —
  /// `StreamingDelivery.joined` adds no second space when the volatile result
  /// already brought its own.
  func testTheDrawnRunsReproduceTheJoinedText() {
    let runs = ReviewDraftMetrics.runs(finalized: "Ship it.", volatileTail: " then land")
    XCTAssertEqual(
      runs.finalized + runs.volatileTail,
      StreamingDelivery.joined("Ship it.", " then land")
    )

    let spaced = ReviewDraftMetrics.runs(finalized: "Ship it.", volatileTail: "then land")
    XCTAssertEqual(
      spaced.finalized + spaced.volatileTail,
      StreamingDelivery.joined("Ship it.", "then land")
    )
  }
}

final class ReviewContinuationAppendTests: XCTestCase {
  func testASentenceIsJoinedWithOneSpace() {
    XCTAssertEqual(
      DictationReview.appended(buffer: "Ship the patch.", addition: "Then land it."),
      "Ship the patch. Then land it."
    )
  }

  func testAnUnfinishedBufferGetsTheSameSingleSpace() {
    XCTAssertEqual(
      DictationReview.appended(buffer: "Ship the patch and", addition: "then land it."),
      "Ship the patch and then land it."
    )
  }

  func testWhitespaceTheOwnerTypedIsNotDoubled() {
    // A deliberate newline at the end of the box is a layout choice, not a
    // missing separator.
    XCTAssertEqual(
      DictationReview.appended(buffer: "Ship the patch.\n", addition: "Then land it."),
      "Ship the patch.\nThen land it."
    )
    XCTAssertEqual(
      DictationReview.appended(buffer: "Ship the patch. ", addition: "Then land it."),
      "Ship the patch. Then land it."
    )
  }

  func testAnEmptyAdditionLeavesTheBufferExactlyAsItWas() {
    XCTAssertEqual(DictationReview.appended(buffer: "Ship it.", addition: "   \n "), "Ship it.")
  }

  func testAnEmptyBufferTakesTheAdditionAlone() {
    XCTAssertEqual(DictationReview.appended(buffer: "", addition: "Ship it."), "Ship it.")
  }
}

// MARK: - Where the card sits

/// A card the owner dragged stays where they put it, across sessions and
/// launches — and is validated rather than trusted on the way back, because a
/// card restored off-screen is a session's whole output invisible.
///
/// Its own store key, not the HUD's: `HUDPositionStore` holds the pill rect's
/// bottom-center (the edge the HUD's *upward* growth pins, and the only x that
/// survives a style switch), and this card is a constant-width surface that
/// grows *downward* from a pinned top edge. Sharing one point would mean
/// dragging one surface moved the other, through an anchor meaning nothing on
/// the far side.
final class ReviewPanelLayoutTests: XCTestCase {
  private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
  private let card = CGSize(width: 520, height: 260)

  func testAPointWellInsideTheScreenIsKeptExactly() {
    XCTAssertEqual(
      ReviewPanelLayout.validatedTopLeft(
        CGPoint(x: 300, y: 700),
        cardSize: card,
        visibleFrames: [screen]
      ),
      CGPoint(x: 300, y: 700)
    )
  }

  /// The self-heal. Clamping a point recorded on a display that is no longer
  /// attached onto whatever is left would call an arbitrary place the owner's
  /// choice; dropping it puts the card back under the focused window.
  func testAPointNoScreenHoldsIsDroppedRatherThanClamped() {
    XCTAssertNil(
      ReviewPanelLayout.validatedTopLeft(
        CGPoint(x: 3000, y: 700),
        cardSize: card,
        visibleFrames: [screen]
      ),
      "recorded on a display that is gone"
    )
  }

  /// A screen that still holds the point can have shrunk under it — resolution
  /// change, Dock, menu bar — so the whole card, not just its corner, is put
  /// back on.
  func testTheWholeCardIsClampedOntoTheScreenNotJustItsCorner() throws {
    let origin = try XCTUnwrap(
      ReviewPanelLayout.validatedTopLeft(
        CGPoint(x: 1430, y: 20),
        cardSize: card,
        visibleFrames: [screen]
      )
    )
    XCTAssertEqual(origin.x, screen.maxX - ReviewPanelLayout.screenInset - card.width)
    XCTAssertEqual(origin.y, screen.minY + ReviewPanelLayout.screenInset + card.height)
  }

  func testACardTallerThanTheScreenIsDropped() {
    XCTAssertNil(
      ReviewPanelLayout.validatedTopLeft(
        CGPoint(x: 300, y: 700),
        cardSize: CGSize(width: 520, height: 2000),
        visibleFrames: [screen]
      )
    )
  }

  /// The store rejects garbage rather than restoring a card to a NaN origin.
  func testTheStoreRoundTripsAPointAndRefusesNonsense() {
    defer { ReviewPositionStore.clear() }
    ReviewPositionStore.save(CGPoint(x: 120, y: 640))
    XCTAssertEqual(ReviewPositionStore.load(), CGPoint(x: 120, y: 640))

    ReviewPositionStore.save(CGPoint(x: CGFloat.nan, y: 640))
    XCTAssertEqual(ReviewPositionStore.load(), CGPoint(x: 120, y: 640), "the bad write was refused")

    ReviewPositionStore.clear()
    XCTAssertNil(ReviewPositionStore.load())
  }

  /// Two surfaces, two answers. The pill's stored point must not move the card
  /// or vice versa.
  func testTheCardAndTheHUDDoNotShareAStoredPosition() {
    defer {
      ReviewPositionStore.clear()
      HUDPositionStore.clear()
    }
    HUDPositionStore.save(CGPoint(x: 700, y: 60))
    ReviewPositionStore.save(CGPoint(x: 120, y: 640))

    XCTAssertEqual(HUDPositionStore.load(), CGPoint(x: 700, y: 60))
    XCTAssertEqual(ReviewPositionStore.load(), CGPoint(x: 120, y: 640))
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

  /// The card is the controller's window onto the owner's edits, and a
  /// continuation writes back through it.
  func testTheEditorCanBeReadAndReplacedOnlyWhileACardIsUp() {
    let presenter = DictationReviewPresenter()
    XCTAssertNil(presenter.editorText, "no card, no buffer")
    XCTAssertFalse(presenter.replaceEditorText("anything"))

    presenter.present(request(onDiscard: {}))
    XCTAssertEqual(presenter.editorText, "Ship the genc2rust patch.")
    XCTAssertTrue(presenter.replaceEditorText("Ship the genc2rust patch. Then land it."))
    XCTAssertEqual(presenter.editorText, "Ship the genc2rust patch. Then land it.")

    presenter.dismiss()
    XCTAssertNil(presenter.editorText)
  }

  /// Both routes out of the card go through `model.apply()` / `model.discard()`
  /// — the key monitor no longer reaches into `finish` on its own — so the
  /// refusal is written down exactly once and the shortcut cannot drift from
  /// the button.
  func testNoDecisionLandsWhileTheCardIsListening() {
    let presenter = DictationReviewPresenter()
    var applies = 0
    var discards = 0
    presenter.present(request(onApply: { _ in applies += 1 }, onDiscard: { discards += 1 }))
    presenter.setListening(true)

    presenter.model.apply()
    presenter.model.discard()
    XCTAssertEqual(applies, 0)
    XCTAssertEqual(discards, 0)
    XCTAssertTrue(presenter.isPresenting)

    presenter.setListening(false)
    presenter.model.apply()
    XCTAssertEqual(applies, 1)
  }

  /// ⌘↩ is the primary action, and while a session records the primary action is
  /// Finish, not Apply. Same call the prominent button makes, so the two cannot
  /// drift — which is the whole reason the branch lives on the model.
  func testTheShortcutFinishesWhileRecordingAndAppliesAfterwards() {
    let presenter = DictationReviewPresenter()
    var applies = 0
    var finishes = 0
    presenter.onFinishRecording = { finishes += 1 }
    presenter.present(request(onApply: { _ in applies += 1 }, onDiscard: {}))

    presenter.setListening(true)
    presenter.model.primaryAction()
    XCTAssertEqual(finishes, 1, "⌘↩ while recording ends the session")
    XCTAssertEqual(applies, 0, "and applies nothing")
    XCTAssertTrue(presenter.isPresenting, "the card stays — Finish is not a decision")

    presenter.setListening(false)
    presenter.model.primaryAction()
    XCTAssertEqual(applies, 1, "with the session over, ⌘↩ is Apply again")
    XCTAssertEqual(finishes, 1)
  }

  /// Finish is refused when there is nothing recording, for the same reason
  /// Apply is refused when there is: the two states are exclusive and each
  /// button means one of them.
  func testFinishIsRefusedWhenNoSessionIsRecording() {
    let presenter = DictationReviewPresenter()
    var finishes = 0
    presenter.onFinishRecording = { finishes += 1 }
    presenter.present(request(onDiscard: {}))

    presenter.model.finishRecording()
    XCTAssertEqual(finishes, 0)
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

  /// **One text box, and the draft in it is display only.**
  ///
  /// The merge (owner, 2026-08-03) moved the live draft from a block of its own
  /// into the editor. What must not have moved with it is the boundary: the
  /// suffix is drawn, the buffer is not touched, and `model.text` — the string
  /// Apply inserts and the diff Apply learns from — is exactly what it was
  /// before the recognizer said anything.
  func testTheLiveDraftIsDrawnInTheEditorAndNeverInTheBuffer() throws {
    let (panel, model) = makePanel("Ship the patch.")
    defer { panel.orderOut(nil) }
    panel.present()
    XCTAssertTrue(spin(until: { DictationReviewPanel.firstTextView(in: panel.contentView) != nil }))
    let editor = try XCTUnwrap(DictationReviewPanel.firstTextView(in: panel.contentView))

    model.isListening = true
    model.draft = HUDDraft(finalized: "Then land it.", volatileTail: "and tell")

    XCTAssertTrue(
      spin(until: { editor.string.contains("and tell") }),
      "the draft never reached the box: \(editor.string)"
    )
    XCTAssertTrue(
      editor.string.hasPrefix("Ship the patch."),
      "the owner's buffer is still the head of the box"
    )
    XCTAssertEqual(
      model.text,
      "Ship the patch.",
      "and NOTHING the recognizer said is in the buffer"
    )
    XCTAssertFalse(editor.isEditable, "the box is read-only while a session records")

    // Stop: the block's words go, and the finished text arrives the way it
    // always has — through the buffer, once.
    model.isListening = false
    model.draft = .empty
    model.text = DictationReview.appended(buffer: model.text, addition: "Then land it.")
    XCTAssertTrue(
      spin(until: { editor.string == "Ship the patch. Then land it." && editor.isEditable }),
      "the box did not settle back to the buffer alone: \(editor.string)"
    )
  }

  /// The suffix is bounded before it is laid out, and drawn in two colours —
  /// the prompter's treatment, in the editor's own box.
  func testTheDraftSuffixIsBoundedAndDimmedAtItsTail() {
    let long = String(repeating: "a", count: ReviewDraftMetrics.windowBudget * 2)
    let drawn = ReviewEditor.attributedDraft(
      HUDDraft(finalized: long, volatileTail: "the newest words")
    )
    XCTAssertTrue(drawn.string.hasSuffix("the newest words"), "the tail is never cut")
    XCTAssertLessThanOrEqual(
      drawn.length,
      ReviewDraftMetrics.windowBudget + ReviewDraftMetrics.windowStep + 32,
      "an unbounded suffix is an unbounded main-actor layout on a 15Hz feed"
    )

    var range = NSRange()
    let tailColor = drawn.attribute(
      .foregroundColor,
      at: drawn.length - 1,
      effectiveRange: &range
    ) as? NSColor
    let headColor = drawn.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    XCTAssertNotEqual(
      tailColor,
      headColor,
      "the volatile tail is dimmed against the finalized text"
    )

    XCTAssertEqual(ReviewEditor.attributedDraft(nil).length, 0, "no session, no suffix")
    XCTAssertEqual(ReviewEditor.attributedDraft(.empty).length, 0)
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
