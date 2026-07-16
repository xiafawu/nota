import XCTest

@testable import Nota

// MARK: - ParsedMessage tests (pure function, no network)

final class AssemblyAIStreamTests: XCTestCase {
  // MARK: - Message mapping

  func testParsedBeginMessage() {
    let json = """
    {"type":"Begin","id":"abc123","expires_at":1712345678}
    """
    XCTAssertEqual(
      AssemblyAIRealtimeStream.ParsedMessage.fromJSON(json),
      .begin(id: "abc123")
    )
  }

  func testParsedPartialTurn() {
    let json = """
    {"type":"Turn","transcript":"hello world","end_of_turn":false,"turn_is_formatted":false}
    """
    XCTAssertEqual(
      AssemblyAIRealtimeStream.ParsedMessage.fromJSON(json),
      .turn(transcript: "hello world", endOfTurn: false)
    )
  }

  func testParsedFinalTurn() {
    let json = """
    {"type":"Turn","transcript":"Hello world.","end_of_turn":true,"turn_is_formatted":true}
    """
    XCTAssertEqual(
      AssemblyAIRealtimeStream.ParsedMessage.fromJSON(json),
      .turn(transcript: "Hello world.", endOfTurn: true)
    )
  }

  func testParsedTurnWithEmptyTranscript() {
    let json = """
    {"type":"Turn","end_of_turn":false}
    """
    XCTAssertEqual(
      AssemblyAIRealtimeStream.ParsedMessage.fromJSON(json),
      .turn(transcript: "", endOfTurn: false)
    )
  }

  func testParsedTerminationWithDuration() {
    let json = """
    {"type":"Termination","audio_duration_seconds":2.5}
    """
    XCTAssertEqual(
      AssemblyAIRealtimeStream.ParsedMessage.fromJSON(json),
      .termination(audioDurationSeconds: 2.5)
    )
  }

  func testParsedTerminationWithoutDuration() {
    let json = """
    {"type":"Termination"}
    """
    XCTAssertEqual(
      AssemblyAIRealtimeStream.ParsedMessage.fromJSON(json),
      .termination(audioDurationSeconds: nil)
    )
  }

  func testParsedMalformedJsonReturnsNil() {
    XCTAssertNil(AssemblyAIRealtimeStream.ParsedMessage.fromJSON("not json"))
  }

  func testParsedUnknownTypeReturnsNil() {
    let json = """
    {"type":"SessionHeartbeat"}
    """
    XCTAssertNil(AssemblyAIRealtimeStream.ParsedMessage.fromJSON(json))
  }

  func testParsedBeginMissingIdReturnsNil() {
    let json = """
    {"type":"Begin"}
    """
    XCTAssertNil(AssemblyAIRealtimeStream.ParsedMessage.fromJSON(json))
  }

  // MARK: - Close-code error mapping

  func testCloseCodeNormalReturnsNil() {
    XCTAssertNil(
      AssemblyAIRealtimeStream.ParsedMessage.errorMessage(forCloseCode: 1000, reason: nil)
    )
  }

  func testCloseCodeGoingAwayReturnsNil() {
    XCTAssertNil(
      AssemblyAIRealtimeStream.ParsedMessage.errorMessage(forCloseCode: 1001, reason: nil)
    )
  }

  func testCloseCode4002MapsToInvalidAPIKey() {
    XCTAssertEqual(
      AssemblyAIRealtimeStream.ParsedMessage.errorMessage(forCloseCode: 4002, reason: nil),
      "AssemblyAI: invalid API key"
    )
  }

  func testCloseCode4003MapsToQuotaExceeded() {
    XCTAssertEqual(
      AssemblyAIRealtimeStream.ParsedMessage.errorMessage(forCloseCode: 4003, reason: nil),
      "AssemblyAI: trial expired or quota exceeded"
    )
  }

  func testCloseCode4001MapsToInvalidJSON() {
    XCTAssertEqual(
      AssemblyAIRealtimeStream.ParsedMessage.errorMessage(forCloseCode: 4001, reason: nil),
      "Invalid JSON sent to AssemblyAI"
    )
  }

  func testCloseCode4004MapsToSampleRateMismatch() {
    XCTAssertEqual(
      AssemblyAIRealtimeStream.ParsedMessage.errorMessage(forCloseCode: 4004, reason: nil),
      "AssemblyAI: sample rate mismatch"
    )
  }

  func testCloseCode4100MapsToGenericServerError() {
    XCTAssertEqual(
      AssemblyAIRealtimeStream.ParsedMessage.errorMessage(forCloseCode: 4100, reason: nil),
      "AssemblyAI: server error (code 4100)"
    )
  }

  func testCloseCodeNon4xxxWithoutReasonReturnsNil() {
    XCTAssertNil(
      AssemblyAIRealtimeStream.ParsedMessage.errorMessage(forCloseCode: 1011, reason: nil)
    )
  }

  func testCloseCodeNon4xxxWithReasonReturnsReason() {
    XCTAssertEqual(
      AssemblyAIRealtimeStream.ParsedMessage.errorMessage(forCloseCode: 1011, reason: "server error"),
      "WebSocket closed: server error"
    )
  }

  // MARK: - Missing-key fast-fail

  func testMissingAPIKeyThrowsCorrectError() {
    // Verify the error type itself (equality + description)
    let err = AssemblyAIError.missingAPIKey
    XCTAssertEqual(err, .missingAPIKey)
    XCTAssertEqual(err.errorDescription, "AssemblyAI: missing API key")
  }

  func testStartThrowsMissingKeyWhenKeyAbsent() async throws {
    try XCTSkipIf(
      ApiKeyStore.value(for: "ASSEMBLYAI_API_KEY").map { !$0.isEmpty } ?? false,
      "ASSEMBLYAI_API_KEY is set — cannot test missing-key path in this environment"
    )

    let stream = AssemblyAIRealtimeStream()
    do {
      try await stream.start()
      XCTFail("expected AssemblyAIError.missingAPIKey")
    } catch let error as AssemblyAIError {
      XCTAssertEqual(error, .missingAPIKey)
    } catch {
      XCTFail("expected AssemblyAIError, got \(error)")
    }
  }

  // MARK: - Error descriptions

  func testAssemblyAIErrorDescriptions() {
    XCTAssertEqual(AssemblyAIError.missingAPIKey.errorDescription, "AssemblyAI: missing API key")
    XCTAssertEqual(AssemblyAIError.connectionTimeout.errorDescription, "AssemblyAI: connection timed out")
    XCTAssertEqual(
      AssemblyAIError.webSocketError("broken pipe").errorDescription,
      "AssemblyAI: broken pipe"
    )
    XCTAssertEqual(
      AssemblyAIError.serverError("rate limited").errorDescription,
      "AssemblyAI: rate limited"
    )
  }
}

// MARK: - Engine factory tests

final class DictationEngineFactoryTests: XCTestCase {
  func testAppleEngineCreatesAppleStream() {
    let stream = makeDictationStream(for: .apple)
    XCTAssertTrue(stream is AppleSpeechStream)
  }

  func testAssemblyAIEngineCreatesAssemblyAIStream() {
    let stream = makeDictationStream(for: .assemblyAIRealtime)
    XCTAssertTrue(stream is AssemblyAIRealtimeStream)
  }
}
