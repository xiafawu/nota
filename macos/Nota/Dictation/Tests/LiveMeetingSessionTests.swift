import XCTest

@testable import Nota

// MARK: - LiveMeetingSession pure-logic tests (no mic, no network)

@MainActor
final class LiveMeetingSessionTests: XCTestCase {
  // MARK: - JSON fixtures

  private static let beginJSON = #"{"type":"Begin","id":"sess-1"}"#
  private static let terminationWithDurationJSON = #"{"type":"Termination","audio_duration_seconds":2.5}"#

  private static func turnJSON(_ text: String, endOfTurn: Bool) -> String {
    #"{"type":"Turn","transcript":"\#(text)","end_of_turn":\#(endOfTurn)}"#
  }

  // MARK: - Message handling / state machine

  func testBeginTransitionsToRecording() {
    let session = LiveMeetingSession()
    session.handleMessageJSON(Self.beginJSON)
    XCTAssertEqual(session.state, .recording)
  }

  func testPartialTurnUpdatesPartialTextOnly() {
    let session = LiveMeetingSession()
    session.handleMessageJSON(Self.beginJSON)
    session.handleMessageJSON(Self.turnJSON("hello world", endOfTurn: false))
    XCTAssertEqual(session.partialText, "hello world")
    XCTAssertTrue(session.segments.isEmpty)
    XCTAssertEqual(session.state, .recording)
  }

  func testFinalTurnAppendsSegmentAndClearsPartial() {
    let session = LiveMeetingSession()
    session.handleMessageJSON(Self.beginJSON)
    session.handleMessageJSON(Self.turnJSON("Hello world.", endOfTurn: true))
    XCTAssertEqual(session.segments.count, 1)
    XCTAssertEqual(session.segments[0].text, "Hello world.")
    XCTAssertNil(session.partialText)
  }

  func testTurnsAccumulateInOrder() {
    let session = LiveMeetingSession()
    session.handleMessageJSON(Self.beginJSON)
    session.handleMessageJSON(Self.turnJSON("First sentence.", endOfTurn: true))
    session.handleMessageJSON(Self.turnJSON("Second sentence.", endOfTurn: true))
    XCTAssertEqual(session.segments.map(\.text), ["First sentence.", "Second sentence."])
  }

  func testEmptyFinalTurnIsAppended() {
    // Contract behavior: every final Turn appends, even an empty one.
    let session = LiveMeetingSession()
    session.handleMessageJSON(Self.beginJSON)
    session.handleMessageJSON(Self.turnJSON("", endOfTurn: true))
    XCTAssertEqual(session.segments.count, 1)
    XCTAssertEqual(session.segments[0].text, "")
  }

  func testSegmentEndTimeUsesElapsedClock() {
    let session = LiveMeetingSession()
    session.handleMessageJSON(Self.beginJSON)
    session.setElapsedForTesting(12.5)
    session.handleMessageJSON(Self.turnJSON("Late.", endOfTurn: true))
    XCTAssertEqual(session.segments[0].endTime, 12.5, accuracy: 0.001)
  }

  func testMalformedJSONIsIgnored() {
    let session = LiveMeetingSession()
    session.handleMessageJSON(Self.beginJSON)
    session.handleMessageJSON("not json")
    session.handleMessageJSON(#"{"type":"SessionHeartbeat"}"#)
    XCTAssertEqual(session.state, .recording)
    XCTAssertTrue(session.segments.isEmpty)
  }

  func testTerminationFinalizesWithDuration() {
    let session = LiveMeetingSession()
    session.handleMessageJSON(Self.beginJSON)
    session.handleMessageJSON(Self.turnJSON("Hello world.", endOfTurn: true))
    session.handleMessageJSON(Self.terminationWithDurationJSON)
    XCTAssertEqual(session.state, .idle)
    let result = session.lastResult
    XCTAssertNotNil(result)
    XCTAssertEqual(result?.duration, 2.5)
    XCTAssertEqual(result?.transcriptText, "Hello world.")
    XCTAssertEqual(result?.segments.count, 1)
    XCTAssertNil(result?.audioURL) // no real recording in tests
  }

  // MARK: - stop()

  func testStopWatchdogReturnsAccumulatedTranscript() async throws {
    let session = LiveMeetingSession()
    session.finishWatchdogNanoseconds = 50_000_000
    session.handleMessageJSON(Self.beginJSON)
    session.handleMessageJSON(Self.turnJSON("First.", endOfTurn: true))
    session.handleMessageJSON(Self.turnJSON("Second.", endOfTurn: true))

    let result = try await session.stop()
    XCTAssertEqual(result.segments.count, 2)
    XCTAssertEqual(result.transcriptText, "First.\nSecond.")
    XCTAssertEqual(session.state, .idle)
  }

  func testStopWaitsForTermination() async throws {
    let session = LiveMeetingSession()
    session.finishWatchdogNanoseconds = 50_000_000
    session.handleMessageJSON(Self.beginJSON)
    session.handleMessageJSON(Self.turnJSON("Hello world.", endOfTurn: true))

    let stopTask = Task { try await session.stop() }
    await Task.yield()
    session.handleMessageJSON(Self.terminationWithDurationJSON)

    let result = try await stopTask.value
    XCTAssertEqual(result.duration, 2.5)
    XCTAssertEqual(result.transcriptText, "Hello world.")
    XCTAssertEqual(session.state, .idle)
  }

  func testStopAfterServerFinalizationReturnsStoredResult() async throws {
    let session = LiveMeetingSession()
    session.handleMessageJSON(Self.beginJSON)
    session.handleMessageJSON(Self.turnJSON("Done.", endOfTurn: true))
    session.handleMessageJSON(Self.terminationWithDurationJSON)

    let result = try await session.stop()
    XCTAssertEqual(result.duration, 2.5)
    XCTAssertEqual(result.transcriptText, "Done.")
    XCTAssertEqual(session.state, .idle)
  }

  func testStopWhenIdleThrows() async {
    let session = LiveMeetingSession()
    do {
      _ = try await session.stop()
      XCTFail("expected LiveMeetingSessionError.notRecording")
    } catch LiveMeetingSessionError.notRecording {
      // expected
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func testStopAfterFailureFinalizesImmediately() async throws {
    let session = LiveMeetingSession()
    session.handleMessageJSON(Self.beginJSON)
    session.handleMessageJSON(Self.turnJSON("Partial result.", endOfTurn: true))
    session.handleClose(rawValue: 4002, reason: nil)
    XCTAssertEqual(session.state, .failed("AssemblyAI: invalid API key"))

    let result = try await session.stop()
    XCTAssertEqual(result.transcriptText, "Partial result.")
    XCTAssertEqual(session.state, .idle)
  }

  // MARK: - Close-code handling

  func testErrorCloseMarksFailedAndKeepsSegments() {
    let session = LiveMeetingSession()
    session.handleMessageJSON(Self.beginJSON)
    session.handleMessageJSON(Self.turnJSON("Kept.", endOfTurn: true))
    session.handleClose(rawValue: 4002, reason: nil)
    XCTAssertEqual(session.state, .failed("AssemblyAI: invalid API key"))
    XCTAssertEqual(session.segments.count, 1)
  }

  func testCloseCode4001MarksFailed() {
    let session = LiveMeetingSession()
    session.handleMessageJSON(Self.beginJSON)
    session.handleClose(rawValue: 4001, reason: nil)
    XCTAssertEqual(session.state, .failed("Invalid JSON sent to AssemblyAI"))
  }

  func testNormalCloseMidSessionFinalizesAccumulated() {
    let session = LiveMeetingSession()
    session.handleMessageJSON(Self.beginJSON)
    session.handleMessageJSON(Self.turnJSON("Unexpected end.", endOfTurn: true))
    session.handleClose(rawValue: 1000, reason: nil)
    XCTAssertEqual(session.state, .idle)
    XCTAssertEqual(session.lastResult?.transcriptText, "Unexpected end.")
  }

  func testErrorCloseDuringStopResolvesWithAccumulated() async throws {
    let session = LiveMeetingSession()
    session.finishWatchdogNanoseconds = 50_000_000
    session.handleMessageJSON(Self.beginJSON)
    session.handleMessageJSON(Self.turnJSON("Kept.", endOfTurn: true))

    let stopTask = Task { try await session.stop() }
    await Task.yield()
    session.handleClose(rawValue: 4003, reason: nil)

    let result = try await stopTask.value
    XCTAssertEqual(result.transcriptText, "Kept.")
    XCTAssertEqual(session.state, .idle)
  }

  // MARK: - cancel()

  func testCancelResetsToIdleAndClearsState() {
    let session = LiveMeetingSession()
    session.handleMessageJSON(Self.beginJSON)
    session.handleMessageJSON(Self.turnJSON("partial text", endOfTurn: false))
    session.cancel()
    XCTAssertEqual(session.state, .idle)
    XCTAssertTrue(session.segments.isEmpty)
    XCTAssertNil(session.partialText)
    XCTAssertEqual(session.elapsed, 0)
  }

  // MARK: - Missing-key fast-fail (no mic/network touched before the throw)

  func testStartThrowsMissingKeyWhenKeyAbsent() async throws {
    try XCTSkipIf(
      ApiKeyStore.value(for: "ASSEMBLYAI_API_KEY").map { !$0.isEmpty } ?? false,
      "ASSEMBLYAI_API_KEY is set — cannot test missing-key path in this environment"
    )

    let session = LiveMeetingSession()
    do {
      try await session.start()
      XCTFail("expected AssemblyAIError.missingAPIKey")
    } catch let error as AssemblyAIError {
      XCTAssertEqual(error, .missingAPIKey)
      // The error banner renders off the published state, so the session must
      // surface the failure before throwing.
      XCTAssertEqual(session.state, .failed("AssemblyAI: missing API key"))
    } catch {
      XCTFail("expected AssemblyAIError, got \(error)")
    }
  }
}
