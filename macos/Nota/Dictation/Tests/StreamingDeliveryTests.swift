import XCTest

@testable import Nota

private extension SentenceSegmenter {
  /// Just the text of what a delta releases — most segmentation tests care
  /// about where the cuts land, not how each piece is labelled.
  mutating func appendText(_ text: String) -> [String] {
    append(text).map(\.text)
  }
}

// MARK: - Sentence segmentation

final class SentenceSegmenterTests: XCTestCase {
  func testHoldsTextWithoutATerminator() {
    var segmenter = SentenceSegmenter()
    XCTAssertEqual(segmenter.appendText("the quick brown fox"), [])
    XCTAssertEqual(segmenter.pending, "the quick brown fox")
  }

  func testReleasesASentenceEndingAtTheEndOfFinalizedText() {
    var segmenter = SentenceSegmenter()
    // Finalized text never changes, so a trailing period is a real boundary —
    // waiting for a following space would hold the last sentence of every
    // pause hostage.
    XCTAssertEqual(segmenter.appendText("the quick brown fox."), ["the quick brown fox."])
    XCTAssertEqual(segmenter.pending, "")
  }

  func testSplitsSeveralSentencesFromOneDelta() {
    var segmenter = SentenceSegmenter()
    XCTAssertEqual(
      segmenter.appendText("One thing. Two things! Three?"),
      ["One thing.", "Two things!", "Three?"]
    )
    XCTAssertEqual(segmenter.pending, "")
  }

  func testKeepsTheRemainderAfterTheLastBoundary() {
    var segmenter = SentenceSegmenter()
    XCTAssertEqual(segmenter.appendText("Done. And then"), ["Done."])
    XCTAssertEqual(segmenter.pending, "And then")
  }

  func testJoinsSuccessiveDeltasWithASingleSpace() {
    var segmenter = SentenceSegmenter()
    XCTAssertEqual(segmenter.appendText("hello"), [])
    XCTAssertEqual(segmenter.appendText("world."), ["hello world."])
  }

  func testDoesNotDoubleASpaceTheDeltaAlreadyCarries() {
    var segmenter = SentenceSegmenter()
    XCTAssertEqual(segmenter.appendText("hello"), [])
    XCTAssertEqual(segmenter.appendText(" world."), ["hello world."])
  }

  func testKeepsAClosingQuoteWithItsSentence() {
    var segmenter = SentenceSegmenter()
    XCTAssertEqual(
      segmenter.appendText("She said \"stop.\" Then she left."),
      ["She said \"stop.\"", "Then she left."]
    )
  }

  func testEllipsisAndInterrobangCountAsOneBoundary() {
    var segmenter = SentenceSegmenter()
    XCTAssertEqual(segmenter.appendText("Really?! Yes... ok"), ["Really?!", "Yes..."])
    XCTAssertEqual(segmenter.pending, "ok")
  }

  func testDecimalNumbersAreNotBoundaries() {
    var segmenter = SentenceSegmenter()
    XCTAssertEqual(segmenter.appendText("pi is 3.14159 roughly"), [])
    XCTAssertEqual(segmenter.pending, "pi is 3.14159 roughly")
  }

  func testAbbreviationDoesNotEndASentence() {
    var segmenter = SentenceSegmenter()
    XCTAssertEqual(segmenter.appendText("Ask Dr. Chen about it."), ["Ask Dr. Chen about it."])
  }

  func testInitialDoesNotEndASentence() {
    var segmenter = SentenceSegmenter()
    XCTAssertEqual(segmenter.appendText("Email J. Smith today."), ["Email J. Smith today."])
  }

  func testNumberedListItemDoesNotEndASentence() {
    var segmenter = SentenceSegmenter()
    XCTAssertEqual(segmenter.appendText("1. buy milk"), [])
    XCTAssertEqual(segmenter.pending, "1. buy milk")
  }

  func testOverflowReleasesAtAWordBoundary() throws {
    var segmenter = SentenceSegmenter()
    // A speaker who never lands a period must still get text, but never half
    // a word.
    let long = Array(repeating: "word", count: 80).joined(separator: " ")
    let released = segmenter.appendText(long)

    XCTAssertEqual(released.count, 1)
    let chunk = try XCTUnwrap(released.first)
    XCTAssertTrue(chunk.hasSuffix("word"))
    XCTAssertEqual(segmenter.pending, "word")
    XCTAssertEqual(
      StreamingDelivery.joined(chunk, segmenter.pending),
      long,
      "overflow release must not lose or duplicate a word"
    )
  }

  func testACutAtARealBoundaryIsAWholeSentence() throws {
    var segmenter = SentenceSegmenter()
    let segment = try XCTUnwrap(segmenter.append("All done.").first)
    XCTAssertTrue(segment.isWholeSentence)
  }

  func testTheOverflowValveReleasesAFragmentNotASentence() throws {
    var segmenter = SentenceSegmenter()
    let long = Array(repeating: "word", count: 80).joined(separator: " ")
    let fragment = try XCTUnwrap(segmenter.append(long).first)

    // The valve cut mid-sentence. Saying otherwise is what makes the formatter
    // append a period and capitalize the continuation — into a live document,
    // where neither can be taken back.
    XCTAssertTrue(fragment.startsSentence, "it does open the sentence")
    XCTAssertFalse(fragment.endsSentence, "but it does not end one")
    XCTAssertFalse(fragment.isWholeSentence)
  }

  func testTheSegmentAfterAFragmentContinuesItRatherThanStartingASentence() throws {
    var segmenter = SentenceSegmenter()
    let long = Array(repeating: "word", count: 80).joined(separator: " ")
    _ = segmenter.append(long)

    let next = try XCTUnwrap(segmenter.append(" and then we stopped.").first)
    XCTAssertFalse(next.startsSentence, "this continues the run-on the valve cut")
    XCTAssertTrue(next.endsSentence)

    // And once a real boundary lands, the next one starts a sentence again.
    let after = try XCTUnwrap(segmenter.append("Fresh start.").first)
    XCTAssertTrue(after.isWholeSentence)
  }

  func testFlushReturnsTheRemainderAndClears() {
    var segmenter = SentenceSegmenter()
    _ = segmenter.appendText("half a thought")
    XCTAssertEqual(segmenter.flush()?.text, "half a thought")
    XCTAssertEqual(segmenter.pending, "")
    XCTAssertNil(segmenter.flush())
  }

  func testTheFlushedTailEndsASentenceBecauseTheSessionDoes() throws {
    var segmenter = SentenceSegmenter()
    _ = segmenter.append("half a thought")
    let tail = try XCTUnwrap(segmenter.flush())
    XCTAssertTrue(tail.isWholeSentence, "the tail gets the period batch delivery would give it")
  }

  func testTheTailAfterAFragmentStillDoesNotStartASentence() throws {
    var segmenter = SentenceSegmenter()
    let long = Array(repeating: "word", count: 80).joined(separator: " ")
    _ = segmenter.append(long)
    let tail = try XCTUnwrap(segmenter.flush())
    XCTAssertFalse(tail.startsSentence)
    XCTAssertTrue(tail.endsSentence)
  }

  func testFlushOfWhitespaceOnlyPendingIsNil() {
    var segmenter = SentenceSegmenter()
    _ = segmenter.appendText("   ")
    XCTAssertNil(segmenter.flush())
  }

  func testEmptyDeltaIsIgnored() {
    var segmenter = SentenceSegmenter()
    XCTAssertEqual(segmenter.appendText(""), [])
    XCTAssertEqual(segmenter.pending, "")
  }
}

// MARK: - Append-delta computation

final class StreamingAppendDeltaTests: XCTestCase {
  func testFirstDeltaIsTheSentenceItself() {
    XCTAssertEqual(StreamingDelivery.appendDelta(previous: "", next: "Hello."), "Hello.")
  }

  func testLaterDeltasCarryTheirOwnSeparator() {
    XCTAssertEqual(
      StreamingDelivery.appendDelta(previous: "Hello.", next: "World."),
      " World."
    )
  }

  func testNoSeparatorWhenTheTargetAlreadyEndsInWhitespace() {
    XCTAssertEqual(
      StreamingDelivery.appendDelta(previous: "Hello. ", next: "World."),
      "World."
    )
  }

  func testSurroundingWhitespaceInTheSentenceIsTrimmed() {
    XCTAssertEqual(
      StreamingDelivery.appendDelta(previous: "Hello.", next: "  World.  "),
      " World."
    )
  }

  func testEmptySentenceProducesNoDelta() {
    XCTAssertEqual(StreamingDelivery.appendDelta(previous: "Hello.", next: "   "), "")
    XCTAssertEqual(StreamingDelivery.appendDelta(previous: "", next: ""), "")
  }

  func testDeltasConcatenateBackIntoTheDeliveredText() {
    var delivered = ""
    for sentence in ["One.", "Two.", "Three."] {
      delivered += StreamingDelivery.appendDelta(previous: delivered, next: sentence)
    }
    XCTAssertEqual(delivered, "One. Two. Three.")
  }

  // MARK: - joined

  func testJoinedInsertsExactlyOneSpace() {
    XCTAssertEqual(StreamingDelivery.joined("a", "b"), "a b")
    XCTAssertEqual(StreamingDelivery.joined("a ", "b"), "a b")
    XCTAssertEqual(StreamingDelivery.joined("a", " b"), "a b")
    XCTAssertEqual(StreamingDelivery.joined("", "b"), "b")
    XCTAssertEqual(StreamingDelivery.joined("a", ""), "a")
  }

  // MARK: - Rough draft

  func testRoughDraftTailCollapsesWhitespace() {
    XCTAssertEqual(StreamingDelivery.roughDraftTail("  hello   world \n"), "hello world")
  }

  func testRoughDraftTailIsNilWhenThereIsNothingToShow() {
    XCTAssertNil(StreamingDelivery.roughDraftTail(""))
    XCTAssertNil(StreamingDelivery.roughDraftTail("   \n  "))
  }

  func testRoughDraftTailKeepsTheEndNotTheStart() {
    let text = String(repeating: "a", count: 40) + " tail end here"
    let tail = StreamingDelivery.roughDraftTail(text, limit: 10)
    XCTAssertEqual(tail, "…" + String(text.suffix(10)))
    XCTAssertTrue(tail?.hasSuffix("here") ?? false)
  }

  func testRoughDraftTailShorterThanTheLimitIsUnmarked() {
    XCTAssertEqual(StreamingDelivery.roughDraftTail("short", limit: 60), "short")
  }
}

// MARK: - Ordered delivery buffer

final class OrderedDeliveryBufferTests: XCTestCase {
  func testInOrderCompletionsPassStraightThrough() {
    var buffer = OrderedDeliveryBuffer()
    XCTAssertEqual(buffer.complete(index: 0, text: "one"), ["one"])
    XCTAssertEqual(buffer.complete(index: 1, text: "two"), ["two"])
    XCTAssertFalse(buffer.isHoldingSegments)
  }

  func testOutOfOrderCompletionsAreHeldUntilTheirPredecessorLands() {
    var buffer = OrderedDeliveryBuffer()
    XCTAssertEqual(buffer.complete(index: 2, text: "three"), [])
    XCTAssertEqual(buffer.complete(index: 1, text: "two"), [])
    XCTAssertTrue(buffer.isHoldingSegments)
    XCTAssertEqual(buffer.complete(index: 0, text: "one"), ["one", "two", "three"])
    XCTAssertFalse(buffer.isHoldingSegments)
  }

  func testAlreadyDeliveredIndexIsIgnored() {
    var buffer = OrderedDeliveryBuffer()
    XCTAssertEqual(buffer.complete(index: 0, text: "one"), ["one"])
    XCTAssertEqual(buffer.complete(index: 0, text: "one again"), [])
  }

  func testDuplicateHeldIndexIsIgnored() {
    var buffer = OrderedDeliveryBuffer()
    XCTAssertEqual(buffer.complete(index: 1, text: "two"), [])
    XCTAssertEqual(buffer.complete(index: 1, text: "two again"), [])
    XCTAssertEqual(buffer.complete(index: 0, text: "one"), ["one", "two"])
  }
}

// MARK: - Queue: ordering, fallback, append-only

/// Lets a test decide when each sentence's refinement finishes, so refinements
/// can be made to complete in an order the queue must undo.
private actor RefinementGate {
  private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
  private var released: Set<String> = []

  func wait(for key: String) async {
    guard !released.contains(key) else { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      if released.contains(key) {
        continuation.resume()
      } else {
        waiters[key] = continuation
      }
    }
  }

  func release(_ key: String) {
    released.insert(key)
    waiters.removeValue(forKey: key)?.resume()
  }
}

@MainActor
private final class DeltaRecorder {
  var deltas: [String] = []
  var joined: String { deltas.joined() }
}

@MainActor
final class StreamingDeliveryQueueTests: XCTestCase {
  func testDeliversInOrderWhenRefinementsCompleteOutOfOrder() async {
    let gate = RefinementGate()
    let recorder = DeltaRecorder()
    let queue = StreamingDeliveryQueue(
      refine: { segment in
        await gate.wait(for: segment.text)
        return segment.text
      },
      deliver: { delta in recorder.deltas.append(delta) }
    )

    queue.enqueue("One.")
    queue.enqueue("Two.")
    queue.enqueue("Three.")

    // Polish returns backwards — the queue must still type them forwards.
    await gate.release("Three.")
    await gate.release("Two.")
    await gate.release("One.")
    await queue.finish()

    XCTAssertEqual(recorder.deltas, ["One.", " Two.", " Three."])
    XCTAssertEqual(queue.deliveredText, "One. Two. Three.")
  }

  func testAMiddleSentenceStallingHoldsBackEverythingAfterIt() async {
    let gate = RefinementGate()
    let recorder = DeltaRecorder()
    let queue = StreamingDeliveryQueue(
      refine: { segment in
        await gate.wait(for: segment.text)
        return segment.text
      },
      deliver: { delta in recorder.deltas.append(delta) }
    )

    queue.enqueue("One.")
    queue.enqueue("Two.")
    queue.enqueue("Three.")

    await gate.release("One.")
    await gate.release("Three.")
    // "Two." is still in flight, so nothing after it may be typed yet — no
    // matter how long the queue is given.
    for _ in 0..<50 {
      await Task.yield()
      XCTAssertFalse(
        recorder.deltas.contains(" Three."),
        "a later sentence was delivered while an earlier one was still being polished"
      )
    }
    XCTAssertEqual(recorder.deltas, ["One."])

    await gate.release("Two.")
    await queue.finish()
    XCTAssertEqual(recorder.deltas, ["One.", " Two.", " Three."])
  }

  func testDeliveredTextOnlyEverGrows() async {
    let recorder = DeltaRecorder()
    let queue = StreamingDeliveryQueue(
      refine: { $0.text },
      deliver: { delta in recorder.deltas.append(delta) }
    )

    var snapshots: [String] = []
    for sentence in ["A.", "B.", "C."] {
      queue.enqueue(sentence)
      await queue.finish()
      snapshots.append(queue.deliveredText)
    }

    for (earlier, later) in zip(snapshots, snapshots.dropFirst()) {
      XCTAssertTrue(later.hasPrefix(earlier), "\"\(later)\" must extend \"\(earlier)\"")
    }
    XCTAssertEqual(recorder.joined, queue.deliveredText)
  }

  func testEmptySentencesAreNeverEnqueuedOrDelivered() async {
    let recorder = DeltaRecorder()
    let queue = StreamingDeliveryQueue(
      refine: { $0.text },
      deliver: { delta in recorder.deltas.append(delta) }
    )

    queue.enqueue("   ")
    queue.enqueue("")
    await queue.finish()

    XCTAssertEqual(queue.enqueuedCount, 0)
    XCTAssertEqual(recorder.deltas, [])
    XCTAssertEqual(queue.deliveredText, "")
  }

  func testASentenceRefinedToNothingDeliversNothingButDoesNotStallTheQueue() async {
    let recorder = DeltaRecorder()
    let queue = StreamingDeliveryQueue(
      refine: { $0.text == "skip me." ? "" : $0.text },
      deliver: { delta in recorder.deltas.append(delta) }
    )

    queue.enqueue("First.")
    queue.enqueue("skip me.")
    queue.enqueue("Last.")
    await queue.finish()

    XCTAssertEqual(recorder.deltas, ["First.", " Last."])
  }

  func testFinishIsIdempotentAndSafeOnAnUntouchedQueue() async {
    let queue = StreamingDeliveryQueue(refine: { $0.text }, deliver: { _ in })
    await queue.finish()
    await queue.finish()
    XCTAssertEqual(queue.deliveredText, "")
  }
}

// MARK: - Per-sentence refinement and polish fallback

private struct StubPolishFailure: LocalizedError {
  var errorDescription: String? { "stub polish failure" }
}

final class StreamingRefineTests: XCTestCase {
  func testPolishDisabledYieldsTheOfflineText() async {
    let refined = await StreamingDelivery.refine("hello world", terms: [], polish: nil)
    XCTAssertEqual(refined.text, "Hello world.")
    XCTAssertEqual(refined.offline, "Hello world.")
    XCTAssertNil(refined.polishError)
  }

  func testDictionaryReplacementRunsBeforePolishSeesTheText() async {
    let terms = [DictionaryTerm(term: "genc2rust", spokenForms: ["gency to rust"])]
    var seenByPolish: String?
    let refined = await StreamingDelivery.refine(
      "run gency to rust now",
      terms: terms,
      polish: { text in
        seenByPolish = text
        return text
      }
    )
    XCTAssertEqual(seenByPolish, "Run genc2rust now.")
    XCTAssertEqual(refined.text, "Run genc2rust now.")
  }

  func testPolishFailureFallsBackToTheOfflineTextOfThatSentence() async {
    let refined = await StreamingDelivery.refine(
      "hello world",
      terms: [],
      polish: { _ in throw StubPolishFailure() }
    )
    XCTAssertEqual(refined.text, "Hello world.")
    XCTAssertEqual(refined.text, refined.offline)
    XCTAssertNotNil(refined.polishError)
  }

  func testPolishSuccessReplacesTheTextButKeepsTheOfflineResult() async {
    let refined = await StreamingDelivery.refine(
      "hello world",
      terms: [],
      polish: { _ in "Hello, world!" }
    )
    XCTAssertEqual(refined.text, "Hello, world!")
    XCTAssertEqual(refined.offline, "Hello world.")
    XCTAssertNil(refined.polishError)
  }

  func testAnEmptySentenceNeverReachesPolish() async {
    var polishCalled = false
    let refined = await StreamingDelivery.refine(
      "",
      terms: [],
      polish: { text in
        polishCalled = true
        return text
      }
    )
    XCTAssertFalse(polishCalled)
    XCTAssertEqual(refined.text, "")
  }

  // MARK: - Fragments released by the overflow valve

  func testAFragmentIsNotGivenATerminalPeriod() async {
    let fragment = StreamingDelivery.Segment(
      text: "and then we went to the",
      startsSentence: true,
      endsSentence: false
    )
    let refined = await StreamingDelivery.refine(fragment, terms: [], polish: nil)

    XCTAssertEqual(refined.text, "And then we went to the")
    XCTAssertFalse(refined.text.hasSuffix("."), "a period here lands mid-sentence, permanently")
  }

  func testAContinuationIsNotCapitalized() async {
    let continuation = StreamingDelivery.Segment(
      text: "store on the corner.",
      startsSentence: false,
      endsSentence: true
    )
    let refined = await StreamingDelivery.refine(continuation, terms: [], polish: nil)

    XCTAssertEqual(refined.text, "store on the corner.")
  }

  func testPolishNeverSeesAFragment() async {
    // Polish is a sentence-level rewriter: hand it half a sentence and it hands
    // back a whole one, capital and full stop included. A polish that ran would
    // be visible in the text, so no flag is needed to catch it.
    let fragment = StreamingDelivery.Segment(
      text: "and then we went to the",
      startsSentence: true,
      endsSentence: false
    )
    let refined = await StreamingDelivery.refine(
      fragment,
      terms: [],
      polish: { text in text + " POLISHED." }
    )

    XCTAssertEqual(refined.text, "And then we went to the")
    XCTAssertEqual(refined.text, refined.offline)
    XCTAssertNil(refined.polishError)
  }

  func testAFragmentStillGetsTheOfflineDictionaryPass() async {
    // Skipping polish must not cost the fragment its spelling fixes — offline
    // replacement is the only one left.
    let terms = [DictionaryTerm(term: "genc2rust", spokenForms: ["gency to rust"])]
    let fragment = StreamingDelivery.Segment(
      text: "we ran gency to rust over the",
      startsSentence: true,
      endsSentence: false
    )
    let refined = await StreamingDelivery.refine(fragment, terms: terms, polish: nil)

    XCTAssertEqual(refined.text, "We ran genc2rust over the")
  }

  func testAWholeSentenceStillGetsBothRules() async {
    let refined = await StreamingDelivery.refine(
      StreamingDelivery.Segment(text: "hello world"),
      terms: [],
      polish: nil
    )
    XCTAssertEqual(refined.text, "Hello world.")
  }

  /// One sentence failing polish must not change what the ones around it
  /// deliver — that is the difference between a degraded session and a lost
  /// one.
  func testOneFailingSentenceDoesNotDegradeItsNeighbours() async {
    var results: [String] = []
    for sentence in ["first one", "second one", "third one"] {
      let refined = await StreamingDelivery.refine(
        sentence,
        terms: [],
        polish: { text in
          if text.contains("Second") { throw StubPolishFailure() }
          return text.uppercased()
        }
      )
      results.append(refined.text)
    }
    XCTAssertEqual(results, ["FIRST ONE.", "Second one.", "THIRD ONE."])
  }
}

// MARK: - Append-mode injection

final class AppendInjectionTests: XCTestCase {
  func testAppendedValueExtendsTheExistingFieldContents() {
    XCTAssertEqual(
      TextInjector.appendedValue(current: "Dear Alex,", delta: " thanks."),
      "Dear Alex, thanks."
    )
  }

  func testAppendedValueOnAnEmptyOrUnreadableFieldIsJustTheDelta() {
    XCTAssertEqual(TextInjector.appendedValue(current: "", delta: "Hello."), "Hello.")
    XCTAssertEqual(TextInjector.appendedValue(current: nil, delta: "Hello."), "Hello.")
  }

  func testAppendedValueNeverRewritesWhatIsAlreadyThere() {
    let existing = "Text the user typed themselves."
    let result = TextInjector.appendedValue(current: existing, delta: " And ours.")
    XCTAssertTrue(result.hasPrefix(existing))
  }

  func testSecureFieldRefusalIsUnchangedInAppendMode() async {
    let injector = TextInjector(overrides: [:])
    let target = FocusedTarget(
      bundleID: "com.apple.TextEdit",
      isSecureInput: true,
      accessibilityElement: nil
    )

    await injector.inject("secret", target: target, mode: .append)

    XCTAssertNotNil(injector.lastSecureFieldNotice)
  }

  func testStrategyResolutionIsIndependentOfMode() {
    let injector = TextInjector()
    XCTAssertEqual(injector.resolveStrategy(for: "com.google.Chrome"), .paste)
    XCTAssertEqual(injector.resolveStrategy(for: "com.apple.Terminal"), .keyEvents)
  }
}

// MARK: - Toggle-off regression

final class StreamingDeliveryToggleTests: XCTestCase {
  override func tearDown() {
    DictationSettingsStore.reset()
    super.tearDown()
  }

  func testStreamingDeliveryDefaultsOff() {
    DictationSettingsStore.reset()
    XCTAssertFalse(DictationSettings().streamingDelivery)
    XCTAssertFalse(DictationSettingsStore.load().streamingDelivery)
  }

  func testStreamingDeliveryRoundTrips() {
    var settings = DictationSettingsStore.load()
    settings.streamingDelivery = true
    DictationSettingsStore.save(settings)
    XCTAssertTrue(DictationSettingsStore.load().streamingDelivery)

    settings.streamingDelivery = false
    DictationSettingsStore.save(settings)
    XCTAssertFalse(DictationSettingsStore.load().streamingDelivery)
  }

  func testSettingsSavedBeforeThisFlagExistedKeepEveryOtherPreference() throws {
    // A payload written by the previous build has no `streamingDelivery` key.
    // The synthesized decoder throws on a missing key and `load()` turns any
    // throw into factory defaults — so without a tolerant decode, shipping this
    // toggle would silently reset the user's engine, trigger, polish and HUD
    // preferences on first launch.
    let legacy = """
    {"engine":"assemblyAIRealtime","trigger":{"kind":"keyCode","keyCode":49},\
    "activation":"toggle","polishEnabled":true,"polishModelID":"deepseek-v4-flash",\
    "showHUD":false}
    """
    let settings = try JSONDecoder().decode(
      DictationSettings.self,
      from: Data(legacy.utf8)
    )

    XCTAssertFalse(settings.streamingDelivery, "a setting that did not exist must default off")
    XCTAssertEqual(settings.engine, .assemblyAIRealtime)
    XCTAssertEqual(settings.trigger, TriggerKey(kind: .keyCode, keyCode: 49))
    XCTAssertEqual(settings.activation, .toggle)
    XCTAssertTrue(settings.polishEnabled)
    XCTAssertEqual(settings.polishModelID, "deepseek-v4-flash")
    XCTAssertFalse(settings.showHUD)
  }

  func testSettingsRoundTripThroughTheTolerantDecoder() throws {
    var settings = DictationSettings()
    settings.engine = .assemblyAIRealtime
    settings.trigger = TriggerKey(kind: .keyCode, keyCode: 0x31)
    settings.activation = .toggle
    settings.polishEnabled = true
    settings.polishModelID = "deepseek-v4-flash"
    settings.showHUD = false
    settings.streamingDelivery = true

    let data = try JSONEncoder().encode(settings)
    XCTAssertEqual(try JSONDecoder().decode(DictationSettings.self, from: data), settings)
  }

  func testAWhollyUnreadablePayloadStillResetsToDefaults() {
    // Tolerance is per field, not per file: a payload that is not even a
    // keyed container must still fail so `load()` falls back.
    XCTAssertNil(try? JSONDecoder().decode(DictationSettings.self, from: Data("[]".utf8)))
  }

  func testHypothesisIsNotASegmentUnlessSaidSo() {
    // Every producer other than streaming-mode Apple recognition keeps the
    // original two-field contract.
    XCTAssertFalse(Hypothesis(text: "hi", isFinal: false).isSegment)
    XCTAssertFalse(Hypothesis(text: "hi", isFinal: true).isSegment)
    XCTAssertTrue(Hypothesis(text: "hi", isFinal: true, isSegment: true).isSegment)
  }

  func testHypothesisEqualityIgnoresNothing() {
    XCTAssertEqual(Hypothesis(text: "a", isFinal: true), Hypothesis(text: "a", isFinal: true))
    XCTAssertNotEqual(
      Hypothesis(text: "a", isFinal: true),
      Hypothesis(text: "a", isFinal: true, isSegment: true)
    )
  }

  func testStreamsReportNoSegmentsBeforeTheyStart() {
    // `deliversSegments` is only meaningful after start(); before it, every
    // stream must claim nothing so the caller uses batch delivery.
    XCTAssertFalse(makeDictationStream(for: .apple).deliversSegments)
    XCTAssertFalse(makeDictationStream(for: .apple, streaming: true).deliversSegments)
    XCTAssertFalse(makeDictationStream(for: .assemblyAIRealtime, streaming: true).deliversSegments)
  }

  func testAssemblyAIIgnoresTheStreamingRequest() {
    // Its "finals" are whole formatted turns, not deltas — asking for segments
    // must not produce an Apple stream or a half-configured AssemblyAI one.
    let stream = makeDictationStream(for: .assemblyAIRealtime, streaming: true)
    XCTAssertTrue(stream is AssemblyAIRealtimeStream)
    XCTAssertFalse(stream.deliversSegments)
  }
}
