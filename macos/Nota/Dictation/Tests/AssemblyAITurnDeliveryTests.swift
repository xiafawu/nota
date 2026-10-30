import XCTest

@testable import Nota

/// AssemblyAI Realtime delivers each finished turn while the owner is still
/// speaking (2026-10-30). Everything that makes that safe — append-only,
/// spoken order, one fixed target — is the delivery queue's and is tested
/// there; what is AssemblyAI's own is which messages become segments, and how
/// a segment is cut. Both are pure and asserted here without a socket.
final class AssemblyAITurnRouterTests: XCTestCase {
  func testAPartialTurnIsTheLiveDraftOnly() {
    var router = AssemblyAITurnRouter(deliversTurns: true)
    let routed = router.route(transcript: "we agreed to", endOfTurn: false, turnOrder: 0)
    XCTAssertEqual(routed.hypotheses, [Hypothesis(text: "we agreed to", isFinal: false)])
    XCTAssertNil(routed.finalized, "a partial is never part of the transcript")
  }

  func testAFinishedTurnIsASegmentWhenDeliveringWhileSpeaking() {
    var router = AssemblyAITurnRouter(deliversTurns: true)
    let routed = router.route(
      transcript: "we agreed to move the launch to friday", endOfTurn: true, turnOrder: 0
    )
    XCTAssertEqual(
      routed.hypotheses,
      [Hypothesis(text: "we agreed to move the launch to friday", isFinal: true, isSegment: true)]
    )
    XCTAssertEqual(routed.finalized, "we agreed to move the launch to friday")
  }

  /// Insert on Release and Review keep exactly what they had: a final that
  /// feeds the live draft and the transcript, and nothing to deliver.
  func testAFinishedTurnIsNotASegmentOtherwise() {
    var router = AssemblyAITurnRouter(deliversTurns: false)
    let routed = router.route(transcript: "ship it", endOfTurn: true, turnOrder: 0)
    XCTAssertEqual(routed.hypotheses, [Hypothesis(text: "ship it", isFinal: true)])
    XCTAssertFalse(routed.hypotheses[0].isSegment)
    XCTAssertEqual(routed.finalized, "ship it")
  }

  /// With `format_turns=true` the server finalizes every turn twice — raw, then
  /// formatted, same `turn_order`. Delivery is append-only, so the second one
  /// would type the sentence into the owner's document again. One turn, one
  /// segment, one line of transcript.
  func testTheFormattedRepeatOfATurnIsNeverDeliveredTwice() {
    var router = AssemblyAITurnRouter(deliversTurns: true)
    let first = router.route(transcript: "ship it", endOfTurn: true, turnOrder: 3)
    let repeatTurn = router.route(transcript: "Ship it.", endOfTurn: true, turnOrder: 3)
    let next = router.route(transcript: "then land it", endOfTurn: true, turnOrder: 4)

    XCTAssertEqual(first.hypotheses.filter(\.isSegment).count, 1)
    XCTAssertEqual(repeatTurn, AssemblyAITurnRouter.Routed(), "the repeat yields nothing at all")
    XCTAssertEqual(next.hypotheses.filter(\.isSegment).map(\.text), ["then land it"])
  }

  /// A message with no `turn_order` cannot be recognized as a repeat, so it is
  /// never dropped as one — dropping a real turn is the worse failure.
  func testTurnsWithoutAnOrderAreAllDelivered() {
    var router = AssemblyAITurnRouter(deliversTurns: true)
    let a = router.route(transcript: "one", endOfTurn: true)
    let b = router.route(transcript: "two", endOfTurn: true)
    XCTAssertEqual(a.finalized, "one")
    XCTAssertEqual(b.finalized, "two")
  }

  func testAnEmptyFinishedTurnDeliversNothingAndClearsTheTail() {
    var router = AssemblyAITurnRouter(deliversTurns: true)
    let routed = router.route(transcript: "   ", endOfTurn: true, turnOrder: 0)
    XCTAssertEqual(routed.hypotheses, [Hypothesis(text: "", isFinal: false)])
    XCTAssertNil(routed.finalized)
    // And it did not claim the turn: a real final for it still lands.
    let real = router.route(transcript: "hello", endOfTurn: true, turnOrder: 0)
    XCTAssertEqual(real.finalized, "hello")
  }

  func testTheParserReadsTurnOrderAndFormatting() {
    let json = """
      {"type":"Turn","turn_order":7,"transcript":"ship it","end_of_turn":true,"turn_is_formatted":false}
      """
    XCTAssertEqual(
      AssemblyAIRealtimeStream.ParsedMessage.fromJSON(json),
      .turn(transcript: "ship it", endOfTurn: true, turnOrder: 7, isFormatted: false)
    )
  }
}

/// How a finished segment is cut before it reaches the queue.
final class UtteranceSegmentationTests: XCTestCase {
  /// The reason turns bypass the sentence cutter: they arrive unpunctuated,
  /// and a cutter waiting for a terminator would hold every one of them until
  /// the session ended.
  func testAnUnpunctuatedTurnIsReleasedImmediatelyAsOneSentence() {
    var segmenter = SentenceSegmenter()
    let released = StreamingDelivery.segments(
      finalizing: "we agreed to move the launch to friday",
      asUtterance: true,
      segmenter: &segmenter
    )
    XCTAssertEqual(
      released,
      [StreamingDelivery.Segment(text: "we agreed to move the launch to friday")]
    )
    XCTAssertTrue(released[0].isWholeSentence, "a turn is a whole sentence: polish may see it")
    XCTAssertEqual(segmenter.pending, "")
  }

  func testTurnsAreReleasedInTheOrderTheyFinished() {
    var segmenter = SentenceSegmenter()
    let turns = ["kenny will send the deck tonight", "lets check the numbers on monday"]
    let released = turns.flatMap {
      StreamingDelivery.segments(finalizing: $0, asUtterance: true, segmenter: &segmenter)
    }
    XCTAssertEqual(released.map(\.text), turns)
  }

  func testAnEmptyTurnReleasesNothing() {
    var segmenter = SentenceSegmenter()
    XCTAssertEqual(
      StreamingDelivery.segments(finalizing: " \n", asUtterance: true, segmenter: &segmenter),
      []
    )
  }

  /// The Apple path is untouched: an unfinished sentence is held.
  func testAppleDeltasAreStillCutAtSentenceEnds() {
    var segmenter = SentenceSegmenter()
    XCTAssertEqual(
      StreamingDelivery.segments(
        finalizing: "we agreed to", asUtterance: false, segmenter: &segmenter
      ),
      []
    )
    XCTAssertEqual(
      StreamingDelivery.segments(
        finalizing: " move it. Then", asUtterance: false, segmenter: &segmenter
      ).map(\.text),
      ["we agreed to move it."]
    )
  }

  /// The dressing a turn gets is the sentence dressing the batch path gives the
  /// whole transcript: a capital and a full stop, offline.
  func testADeliveredTurnIsPunctuatedLikeASentence() async {
    let refined = await StreamingDelivery.refine(
      StreamingDelivery.Segment(text: "ship the patch"), terms: [], polish: nil
    )
    XCTAssertEqual(refined.text, "Ship the patch.")
  }
}
