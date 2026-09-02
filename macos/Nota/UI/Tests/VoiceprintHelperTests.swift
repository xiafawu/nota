import AVFoundation
import Foundation
import XCTest

@testable import Nota

// MARK: - The fake helper

/// A `LiveVoiceprintNaming` that answers from a table.
///
/// The seam exists for this: a real answer costs a `node` child process, a
/// 27 MB ONNX model and a voiceprint store, and none of that is what the rules
/// are about. What the rules are about is *when* a name is asked for and *when*
/// one may be written, and both are visible from here.
@MainActor
final class FakeVoiceprintHelper: LiveVoiceprintNaming {
  /// Whether `start()` produces a helper that can answer. False is the
  /// "the helper never started" case — a missing binary, a machine with nobody
  /// enrolled, a spawn that threw.
  var startsSuccessfully: Bool

  private(set) var startCount = 0
  private(set) var stopCount = 0
  private(set) var requests: [VoiceprintRequest] = []

  /// Consumed in order, one per request; an exhausted table answers nil.
  var answers: [String?] = []

  private var running = false

  init(startsSuccessfully: Bool = true) {
    self.startsSuccessfully = startsSuccessfully
  }

  func start() {
    startCount += 1
    running = startsSuccessfully
  }

  var isRunning: Bool { running }

  func identify(_ request: VoiceprintRequest) async -> String? {
    requests.append(request)
    guard !answers.isEmpty else { return nil }
    return answers.removeFirst()
  }

  func stop() {
    stopCount += 1
    running = false
  }
}

// MARK: - Tests

/// ADR 0008 — live speaker names, the Swift half.
///
/// The helper process itself is not here: it is a child process, and every rule
/// worth pinning is either pure arithmetic (`LiveTurnAudioBuffer`,
/// `LiveSpeakerAttribution`, the wire encoding) or a fact about the session's
/// lifecycle that a fake answers better than a real one.
@MainActor
final class VoiceprintHelperTests: XCTestCase {
  private func at(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSinceReferenceDate: seconds)
  }

  /// One second of 16 kHz mono Float32 — the shape `MicCapture` delivers.
  private static func secondOfAudio() -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
    buffer.frameLength = 16_000
    return buffer
  }

  /// A session already recording, with `fake` installed as its helper.
  private func startedSession(_ fake: FakeVoiceprintHelper) -> LiveMeetingSession {
    let session = LiveMeetingSession()
    session.setNamingFactoryForTesting { fake }
    session.beginForTesting(startedAt: at(0))
    return session
  }

  /// Put `seconds` of kept audio through the production capture handler.
  private func deliver(_ seconds: Int, to session: LiveMeetingSession) {
    let capture = session.captureForTesting
    for _ in 0..<seconds { capture.enqueueForTesting(Self.secondOfAudio()) }
    capture.flushPending()
  }

  // MARK: - A name lands on the turn it was asked about

  /// **The requirement in one assertion.** A confident match comes back and the
  /// turn it was asked about carries the name.
  func testAConfidentNameLandsOnTheTurnItWasAskedAbout() async {
    let fake = FakeVoiceprintHelper()
    fake.answers = ["Kenny Kim"]
    let session = startedSession(fake)

    deliver(3, to: session)
    session.setElapsedForTesting(3)
    session.appendFinalizedSegmentForTesting(text: "and that is the rollback plan.")
    await session.awaitNamingForTesting()

    XCTAssertEqual(session.segments.count, 1)
    XCTAssertEqual(session.segments.first?.speaker, "Kenny Kim")
    XCTAssertEqual(fake.requests.count, 1, "one finalized turn is one request")
    XCTAssertEqual(fake.requests.first?.sampleRate, LiveTurnAudioBuffer.sampleRate)
  }

  /// **Two turns, two names, each on its own row.** A single-turn test cannot
  /// tell "the name landed on the right segment" from "the name landed on the
  /// only segment".
  func testEachTurnKeepsItsOwnName() async {
    let fake = FakeVoiceprintHelper()
    fake.answers = ["Kenny Kim", "Freya Wu"]
    let session = startedSession(fake)

    deliver(2, to: session)
    session.setElapsedForTesting(2)
    session.appendFinalizedSegmentForTesting(text: "first turn")
    deliver(2, to: session)
    session.setElapsedForTesting(4)
    session.appendFinalizedSegmentForTesting(text: "second turn")
    await session.awaitNamingForTesting()

    XCTAssertEqual(session.segments.map(\.speaker), ["Kenny Kim", "Freya Wu"])
  }

  /// **No name is the correct answer for a voice nobody enrolled.** An
  /// unmatched turn is drawn with no name at all — there is no live
  /// "Speaker 1 / Speaker 2" clustering, which was proposed and rejected.
  func testAnUnmatchedTurnKeepsNoName() async {
    let fake = FakeVoiceprintHelper()
    fake.answers = [nil]
    let session = startedSession(fake)

    deliver(3, to: session)
    session.setElapsedForTesting(3)
    session.appendFinalizedSegmentForTesting(text: "somebody nobody has enrolled")
    await session.awaitNamingForTesting()

    XCTAssertEqual(fake.requests.count, 1, "the turn was asked about")
    XCTAssertNil(session.segments.first?.speaker)
    XCTAssertEqual(session.segments.first?.text, "somebody nobody has enrolled")
  }

  // MARK: - A label once shown is never changed

  /// **A later answer that contradicts an earlier attribution loses.** Driven
  /// through `attribute`, the production write every answer goes through, and
  /// not through the pure rule alone — the rule being right buys nothing if the
  /// write does not consult it.
  func testALaterAnswerDoesNotRewriteALabelAlreadyShown() async throws {
    let fake = FakeVoiceprintHelper()
    fake.answers = ["Kenny Kim"]
    let session = startedSession(fake)

    deliver(3, to: session)
    session.setElapsedForTesting(3)
    session.appendFinalizedSegmentForTesting(text: "a turn")
    await session.awaitNamingForTesting()
    let id = try XCTUnwrap(session.segments.first?.id)
    XCTAssertEqual(session.segments.first?.speaker, "Kenny Kim")

    session.attributeForTesting(name: "Somebody Else", to: id)
    XCTAssertEqual(
      session.segments.first?.speaker, "Kenny Kim",
      "a name flickering from one person to another is worse than one that is incomplete"
    )
  }

  /// The rule itself, stated once: only an unnamed turn may be written.
  func testOnlyAnUnnamedTurnMayBeWritten() {
    XCTAssertTrue(LiveSpeakerAttribution.mayWrite(over: nil))
    XCTAssertFalse(LiveSpeakerAttribution.mayWrite(over: "Kenny Kim"))
  }

  /// **Only a confident match is ever drawn**, and the threshold is re-applied
  /// on this side rather than trusted from the helper's own score.
  func testOnlyAConfidentScoreIsDrawn() {
    XCTAssertEqual(
      VoiceprintHelperProcess.name(fromAnswer: ["id": "1", "ok": true, "name": "Kenny Kim", "score": 0.71]),
      "Kenny Kim"
    )
    XCTAssertNil(
      VoiceprintHelperProcess.name(fromAnswer: ["id": "1", "ok": true, "name": "Kenny Kim", "score": 0.62]),
      "a tentative-band match shows nothing live"
    )
    XCTAssertNil(VoiceprintHelperProcess.name(fromAnswer: ["id": "1", "ok": true, "name": NSNull()]))
    XCTAssertNil(VoiceprintHelperProcess.name(fromAnswer: ["id": "1", "ok": true]))
    XCTAssertNil(
      VoiceprintHelperProcess.name(fromAnswer: ["id": "1", "ok": true, "error": "insufficient_speech"])
    )
    XCTAssertNil(VoiceprintHelperProcess.name(fromAnswer: ["id": "1", "ok": true, "name": ""]))
    // `ok:false` is the helper's refusal shape and carries no name to read.
    XCTAssertNil(
      VoiceprintHelperProcess.name(
        fromAnswer: ["id": "1", "ok": false, "reason": "unavailable"]))
    // …and `ok:true` with a null name plus a reason is the ordinary
    // "nobody we know" answer, not an error.
    XCTAssertNil(
      VoiceprintHelperProcess.name(
        fromAnswer: ["id": "1", "ok": true, "name": NSNull(), "reason": "tentative"]))
    XCTAssertEqual(
      VoiceprintHelperProcess.name(fromAnswer: ["id": "1", "ok": true, "name": "Kenny Kim"]),
      "Kenny Kim",
      "an answer with no score is the helper's own call"
    )
  }

  // MARK: - A helper that never starts costs the session nothing

  /// **Naming is a nicety; capturing the meeting is not.** A helper that will
  /// not start leaves a session that records, transcribes, stops and returns
  /// its whole transcript — with no names on it.
  func testAHelperThatNeverStartsLeavesTheSessionWorkingWithNoNames() async throws {
    let fake = FakeVoiceprintHelper(startsSuccessfully: false)
    fake.answers = ["Kenny Kim"]
    let session = startedSession(fake)
    session.finishWatchdogNanoseconds = 10_000_000

    deliver(3, to: session)
    session.setElapsedForTesting(3)
    session.appendFinalizedSegmentForTesting(text: "first turn")
    session.setElapsedForTesting(6)
    session.appendFinalizedSegmentForTesting(text: "second turn")
    await session.awaitNamingForTesting()

    XCTAssertEqual(fake.startCount, 1, "the session tried")
    XCTAssertTrue(fake.requests.isEmpty, "a helper that is not running is never asked")
    XCTAssertEqual(session.segments.map(\.speaker), [nil, nil])

    let result = try await session.stop()
    XCTAssertEqual(result.segments.map(\.text), ["first turn", "second turn"])
    XCTAssertEqual(session.state, .idle)
  }

  // MARK: - Teardown, on every exit

  /// **A clean stop takes the helper down.**
  func testACleanStopTearsTheHelperDown() async throws {
    let fake = FakeVoiceprintHelper()
    let session = startedSession(fake)
    session.finishWatchdogNanoseconds = 10_000_000

    _ = try await session.stop()

    XCTAssertEqual(fake.stopCount, 1)
    XCTAssertNil(session.namingForTesting)
  }

  /// **Discard takes it down** — `cancel()` is the call `NotaModel
  /// .discardLiveSession` makes.
  func testDiscardTearsTheHelperDown() {
    let fake = FakeVoiceprintHelper()
    let session = startedSession(fake)

    session.cancel()

    XCTAssertEqual(fake.stopCount, 1)
    XCTAssertNil(session.namingForTesting)
  }

  /// **A mid-session failure takes it down.** Driven through the real close
  /// handler with an error code, which is the route a dead socket takes.
  func testAMidSessionFailureTearsTheHelperDown() {
    let fake = FakeVoiceprintHelper()
    let session = startedSession(fake)

    session.handleClose(rawValue: 4002, reason: "bad request")

    guard case .failed = session.state else {
      return XCTFail("expected a failed session, got \(session.state)")
    }
    XCTAssertEqual(fake.stopCount, 1)
    XCTAssertNil(session.namingForTesting)
  }

  /// **A server-initiated end takes it down** — the exit the owner cannot
  /// reach, and the one a teardown list forgets.
  func testAServerInitiatedEndTearsTheHelperDown() {
    let fake = FakeVoiceprintHelper()
    let session = startedSession(fake)

    session.handleMessageJSON("{\"type\":\"Termination\",\"audio_duration_seconds\":12}")

    XCTAssertEqual(session.state, .idle)
    XCTAssertEqual(fake.stopCount, 1)
    XCTAssertNil(session.namingForTesting)
  }

  /// A second session gets a second helper, and the first one's audio never
  /// reaches it: `startNaming` resets the ring.
  func testTheNextSessionStartsFromNothing() {
    let fake = FakeVoiceprintHelper()
    let session = startedSession(fake)
    deliver(3, to: session)
    XCTAssertGreaterThan(session.turnAudioForTesting.totalSamplesWritten, 0)

    session.cancel()
    session.beginForTesting(startedAt: at(0))

    XCTAssertEqual(session.turnAudioForTesting.totalSamplesWritten, 0)
    XCTAssertEqual(fake.startCount, 2)
  }

  // MARK: - A paused span sends nothing

  /// **Audio captured while paused never reaches the helper.**
  ///
  /// The ring is fed from inside `handlePCMBuffer`, behind the same
  /// `capturesAudio` gate the socket send and the file write are behind — so a
  /// paused span is as absent from a naming request as it is from
  /// `recording.caf`. A pause is often taken for privacy, and shipping that
  /// audio to an embedding process is the same failure as writing it to disk.
  func testAPausedSpanReachesNeitherTheRingNorTheHelper() async {
    let fake = FakeVoiceprintHelper()
    fake.answers = ["Kenny Kim"]
    let session = startedSession(fake)

    deliver(3, to: session)
    let keptBeforeThePause = session.turnAudioForTesting.totalSamplesWritten
    XCTAssertEqual(keptBeforeThePause, 3 * LiveTurnAudioBuffer.sampleRate)

    session.pause(now: at(3))
    deliver(5, to: session)
    XCTAssertEqual(
      session.turnAudioForTesting.totalSamplesWritten, keptBeforeThePause,
      "audio from the paused span was buffered for a process the owner never agreed to"
    )

    // A turn that finalizes during the pause — the pre-press tail — is still
    // asked about, and what it carries is pre-pause audio only.
    session.setElapsedForTesting(3)
    session.appendFinalizedSegmentForTesting(text: "the last words before the break")
    await session.awaitNamingForTesting()
    XCTAssertLessThanOrEqual(fake.requests.first?.samples.count ?? .max, keptBeforeThePause)

    // …and a resume starts feeding it again, so this is not a session that
    // simply stopped buffering.
    session.resume(now: at(300))
    deliver(2, to: session)
    XCTAssertEqual(
      session.turnAudioForTesting.totalSamplesWritten,
      keptBeforeThePause + 2 * LiveTurnAudioBuffer.sampleRate
    )
  }

  /// The naming ring may not change one byte of what reaches the socket or the
  /// file. `keptBufferCount` is the count of buffers that got past the gate,
  /// and it is the same with a helper installed and without one.
  func testTheRingDoesNotChangeWhatIsKept() {
    let withHelper = startedSession(FakeVoiceprintHelper())
    deliver(3, to: withHelper)

    let withoutHelper = LiveMeetingSession()
    withoutHelper.setNamingFactoryForTesting { nil }
    withoutHelper.beginForTesting(startedAt: at(0))
    deliver(3, to: withoutHelper)

    XCTAssertEqual(withHelper.keptBufferCountForTesting, 3)
    XCTAssertEqual(
      withoutHelper.keptBufferCountForTesting, withHelper.keptBufferCountForTesting
    )
    XCTAssertEqual(
      withoutHelper.turnAudioForTesting.totalSamplesWritten, 0,
      "a session with no helper pays nothing for the feature"
    )
  }

  // MARK: - The turn buffer

  /// The ring is bounded, and its bound is **derived** from the longest slice
  /// it must be able to answer plus the margin the engine spends deciding to
  /// ask — never a typed literal.
  func testTheRingHoldsTheLongestSlicePlusTheFinalizationMargin() {
    XCTAssertEqual(
      LiveTurnAudioBuffer.capacitySamples,
      Int(
        (LiveTurnAudioBuffer.maxTurnSeconds + LiveTurnAudioBuffer.finalizationMarginSeconds)
          * TimeInterval(LiveTurnAudioBuffer.sampleRate)
      )
    )

    var ring = LiveTurnAudioBuffer()
    ring.append([Int16](repeating: 0, count: LiveTurnAudioBuffer.capacitySamples * 2))
    XCTAssertEqual(ring.count, LiveTurnAudioBuffer.capacitySamples, "the ring is bounded")
    XCTAssertEqual(
      ring.totalSamplesWritten, LiveTurnAudioBuffer.capacitySamples * 2,
      "the write head counts everything, evicted or not"
    )
  }

  /// A turn too short to embed is never sent — ADR 0008 lists it as a turn that
  /// stays blank live, and the ONNX path raises `InsufficientSpeechError` for it
  /// anyway.
  func testATurnTooShortToEmbedIsNeverSent() {
    var ring = LiveTurnAudioBuffer()
    ring.append([Int16](repeating: 0, count: LiveTurnAudioBuffer.sampleRate * 5))

    XCTAssertNil(ring.slice(lastSeconds: 0.4))
    XCTAssertNotNil(ring.slice(lastSeconds: LiveTurnAudioBuffer.minimumTurnSeconds))

    // …and a long span with only a fragment of audio behind it is refused too.
    var nearlyEmpty = LiveTurnAudioBuffer()
    nearlyEmpty.append([Int16](repeating: 0, count: LiveTurnAudioBuffer.sampleRate / 4))
    XCTAssertNil(nearlyEmpty.slice(lastSeconds: 8))
  }

  /// A turn longer than the cap is matched on its last `maxTurnSeconds`, not
  /// refused and not sent whole.
  func testALongTurnIsCutToTheCap() throws {
    var ring = LiveTurnAudioBuffer()
    ring.append([Int16](repeating: 0, count: LiveTurnAudioBuffer.sampleRate * 14))
    let slice = try XCTUnwrap(ring.slice(lastSeconds: 120))
    XCTAssertEqual(
      slice.count,
      Int(LiveTurnAudioBuffer.maxTurnSeconds * TimeInterval(LiveTurnAudioBuffer.sampleRate))
    )
  }

  /// The slice is the **most recent** audio, measured back from the write head.
  func testTheSliceIsTheMostRecentAudio() throws {
    var ring = LiveTurnAudioBuffer()
    ring.append([Int16](repeating: 7, count: LiveTurnAudioBuffer.sampleRate * 2))
    ring.append([Int16](repeating: 9, count: LiveTurnAudioBuffer.sampleRate * 2))
    let slice = try XCTUnwrap(ring.slice(lastSeconds: 2))
    XCTAssertEqual(slice.count, LiveTurnAudioBuffer.sampleRate * 2)
    XCTAssertTrue(slice.allSatisfy { $0 == 9 })
  }

  /// `reset()` is what stops one meeting's audio from becoming the next one's
  /// first turn.
  func testResetForgetsEverything() {
    var ring = LiveTurnAudioBuffer()
    ring.append([Int16](repeating: 1, count: LiveTurnAudioBuffer.sampleRate * 2))
    ring.reset()
    XCTAssertEqual(ring.count, 0)
    XCTAssertEqual(ring.totalSamplesWritten, 0)
    XCTAssertNil(ring.slice(lastSeconds: 2))
  }

  // MARK: - The wire

  /// One request is one newline-terminated JSON line carrying base64 Int16
  /// little-endian — the format the node helper decodes.
  func testARequestIsOneLineOfJSONCarryingLittleEndianPCM() throws {
    let samples: [Int16] = [0, 1, -1, 256, Int16.min, Int16.max]
    let line = try XCTUnwrap(
      VoiceprintHelperProcess.requestLine(
        id: 7, request: VoiceprintRequest(samples: samples, sampleRate: 16_000)
      )
    )
    XCTAssertEqual(line.last, 0x0A, "line-delimited: every request ends in a newline")
    let body = line.dropLast()
    XCTAssertNil(body.firstIndex(of: 0x0A), "one request is exactly one line")

    let parsed = try JSONSerialization.jsonObject(with: Data(body))
    let object = try XCTUnwrap(parsed as? [String: Any])
    XCTAssertEqual(object["id"] as? String, "7")
    XCTAssertEqual(object["op"] as? String, "match")
    let pcm = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(object["pcm"] as? String)))
    XCTAssertEqual(pcm.count, samples.count * MemoryLayout<Int16>.stride)
    let decoded = stride(from: 0, to: pcm.count, by: 2).map { index in
      Int16(bitPattern: UInt16(pcm[index]) | (UInt16(pcm[index + 1]) << 8))
    }
    XCTAssertEqual(decoded, samples)
  }

  // MARK: - The real child, degrading

  /// A stand-in helper: a shell script speaking the line protocol, run through
  /// the same `VoiceprintHelperProcess` production uses.
  ///
  /// The fake conformer above cannot reach any of this. It answers a call; the
  /// three cases below are about a **process** — one that declines to serve,
  /// one that dies mid-meeting, one that speaks the protocol correctly — and
  /// each of them is a claim about spawning, pipes, framing and teardown that
  /// only a real child can make. None of them needs Node or the ONNX model.
  private func scriptedHelper(_ script: String) -> VoiceprintHelperProcess {
    VoiceprintHelperProcess(
      plan: VoiceprintHelperProcess.LaunchPlan(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script],
        currentDirectory: FileManager.default.temporaryDirectory
      )
    )
  }

  private func oneSecondRequest() -> VoiceprintRequest {
    VoiceprintRequest(
      samples: [Int16](repeating: 0, count: LiveTurnAudioBuffer.sampleRate),
      sampleRate: LiveTurnAudioBuffer.sampleRate
    )
  }

  /// **A helper that answers `ready:false` names nothing and is shut down.**
  /// That is the intended cheap exit when nobody is enrolled — ADR 0008 accepts
  /// an empty name column for the whole session rather than guessing, and the
  /// side that knows the store is the side that decides.
  func testAHelperThatDeclinesNamesNothingAndIsShutDown() async {
    let helper = scriptedHelper(
      #"printf '{"type":"ready","protocol":1,"ok":false,"reason":"no enrolled voiceprints"}\n'; cat > /dev/null"#
    )
    helper.start()

    let name = await helper.identify(oneSecondRequest())

    XCTAssertNil(name, "a declined helper may not produce a name")
    XCTAssertFalse(helper.isRunning, "it is written off, not asked again every turn")
    helper.stop()
  }

  /// **A helper that dies mid-session leaves the meeting recording, with no
  /// names from that point on.** The child here answers nothing and exits; the
  /// request in flight resolves nil rather than being abandoned.
  func testAHelperThatDiesMidSessionAnswersNothingMore() async {
    let helper = scriptedHelper(#"printf '{"type":"ready","protocol":1,"ok":true}\n'; exec sleep 0.2"#)
    helper.start()

    let first = await helper.identify(oneSecondRequest())
    XCTAssertNil(first, "a request outstanding when the child died must resolve, not hang")
    XCTAssertFalse(helper.isRunning)

    let second = await helper.identify(oneSecondRequest())
    XCTAssertNil(second, "and the rest of the meeting is simply unnamed")
    helper.stop()
  }

  /// **The happy path, end to end through a real child** — readiness line,
  /// one request written to its stdin, one answer framed back. It is what makes
  /// the three degrade tests mean something: without it they would all pass
  /// against a helper that could never work at all.
  func testARealChildSpeakingTheProtocolProducesAName() async {
    let helper = scriptedHelper(
      #"printf '{"type":"ready","protocol":1,"ok":true}\n'; read -r line; printf '{"id":"1","ok":true,"name":"Kenny Kim","score":0.91}\n'; cat > /dev/null"#
    )
    helper.start()

    let name = await helper.identify(oneSecondRequest())

    XCTAssertEqual(name, "Kenny Kim")
    XCTAssertTrue(helper.isRunning, "one answer does not end the session's helper")
    helper.stop()
    XCTAssertFalse(helper.isRunning)
  }

  /// What is spawned, in preference order. Mirrors `EnrollQueue.spawn`, which
  /// is how everything else in the app reaches the TypeScript side.
  func testTheLaunchPlanPrefersTheOverrideThenTheBuiltCLI() {
    let project = URL(fileURLWithPath: "/tmp/nota-project")

    let overridden = VoiceprintHelperProcess.launchPlan(
      projectDirectory: project,
      environment: [VoiceprintHelperProcess.executableOverrideVariable: "/opt/helper"],
      fileExists: { _ in true }
    )
    XCTAssertEqual(overridden.arguments, ["/opt/helper"])

    let built = VoiceprintHelperProcess.launchPlan(
      projectDirectory: project, environment: [:], fileExists: { $0.hasSuffix("dist/index.js") }
    )
    XCTAssertEqual(
      built.arguments,
      ["node", "/tmp/nota-project/dist/index.js", "voiceprint-serve"]
    )

    let source = VoiceprintHelperProcess.launchPlan(
      projectDirectory: project, environment: [:], fileExists: { _ in false }
    )
    XCTAssertEqual(
      source.arguments,
      ["npx", "tsx", "/tmp/nota-project/src/index.ts", "voiceprint-serve"]
    )
  }
}
