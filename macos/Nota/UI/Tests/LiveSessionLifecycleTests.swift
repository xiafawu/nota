import Foundation
import XCTest

@testable import Nota

/// The live session's record ownership (XIA-430): who may start one, who may
/// clear one, and the rule that no way out leaves a record in an in-flight
/// status. Temp directories only, never the real `~/.nota`.
///
/// These drive `LiveSessionOwner` rather than `NotaModel` because building a
/// NotaModel sweeps the owner's real history directory and runs preflight —
/// the reason the rules were extracted in the first place.
@MainActor
final class LiveSessionLifecycleTests: XCTestCase {
  private var historyDirectory: URL!
  private var outputDirectory: URL!
  private var owner: LiveSessionOwner!

  override func setUp() {
    super.setUp()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("nota-live-lifecycle-tests-\(UUID().uuidString)", isDirectory: true)
    historyDirectory = root.appendingPathComponent("history", isDirectory: true)
    outputDirectory = root.appendingPathComponent("output", isDirectory: true)
    for directory in [historyDirectory!, outputDirectory!] {
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let directory = historyDirectory!
    owner = LiveSessionOwner(historyDirectory: { directory })
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: historyDirectory.deletingLastPathComponent())
    owner = nil
    super.tearDown()
  }

  // MARK: - Fixtures

  private func press(sessionIsLive: Bool = false) -> LiveSessionOwner.StartDecision {
    owner.start(kind: .meeting, diarize: false, identify: false, sessionIsLive: sessionIsLive)
  }

  private func startedRecord(
    _ decision: LiveSessionOwner.StartDecision,
    _ message: String = "expected a started record"
  ) throws -> LiveSessionPersistence.StartedRecord {
    guard case .started(let record) = decision else {
      XCTFail("\(message), got \(decision)")
      throw XCTSkip(message)
    }
    return record
  }

  private func status(_ id: String) throws -> HistoryStatus {
    let url = historyDirectory.appendingPathComponent("\(id).json")
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
    )
    return HistoryStatus.normalized(fromRecord: json)
  }

  private func recordJSON(_ id: String) throws -> [String: Any] {
    let url = historyDirectory.appendingPathComponent("\(id).json")
    return try XCTUnwrap(
      JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
    )
  }

  /// Seal a session's transcript exactly as `NotaModel` does at Stop.
  @discardableResult
  private func seal(
    _ started: LiveSessionPersistence.StartedRecord,
    transcript: String
  ) throws -> LiveSessionPersistence.SavedSession {
    try Data(repeating: 0x41, count: 32).write(to: started.audioURL)
    return try LiveSessionPersistence.sealTranscript(
      started: started,
      result: LiveMeetingSession.LiveMeetingResult(
        segments: [LiveMeetingSession.LiveSegment(id: UUID(), text: transcript, endTime: 12)],
        transcriptText: transcript,
        duration: 12,
        audioURL: started.audioURL
      ),
      outputDirectory: outputDirectory,
      historyDirectory: historyDirectory
    )
  }

  // MARK: - Two Start presses in flight

  func testASecondStartPressWhileTheFirstIsStillStartingIsIgnored() throws {
    // The session is `.idle` for BOTH presses: it stays idle across the mic
    // prompt and the whole realtime open + Begin round trip, which is exactly
    // the window a user presses again in when nothing on screen changes.
    let first = try startedRecord(press())
    XCTAssertTrue(owner.isStarting)

    let second = press()
    XCTAssertEqual(second, .ignored, "the second press must not open a second record")

    // No second record was written — the first attempt's orphan (a record and
    // an assets folder nothing points at, with no deletion verb to clean it
    // up) does not exist.
    let jsons = (try? FileManager.default.contentsOfDirectory(
      at: historyDirectory,
      includingPropertiesForKeys: nil
    ))?.filter { $0.pathExtension == "json" } ?? []
    XCTAssertEqual(jsons.count, 1)
    XCTAssertEqual(owner.record?.historyID, first.historyID)
  }

  func testTwoStartPressesInFlightCannotLoseTheTranscript() throws {
    // Press one: the record the meeting is actually recorded into. Press two
    // lands during the start window — under the bug it wrote a second record,
    // took ownership, cancelled task one, and task one's unconditional cleanup
    // then cleared the NEW owner. Stop found no record, never sealed, and the
    // whole meeting's transcript was lost while the record kept saying
    // `recording`.
    let live = try startedRecord(press())
    XCTAssertEqual(press(), .ignored)

    // The session goes live and its start task finishes.
    owner.finishedStarting()

    // Whatever cleanup a task that is not the owner runs, ownership survives.
    let foreign = LiveSessionPersistence.StartedRecord(
      historyID: "20260101-000000Z-deadbeef",
      recordURL: historyDirectory.appendingPathComponent("20260101-000000Z-deadbeef.json"),
      assetsDirectory: historyDirectory,
      audioURL: historyDirectory.appendingPathComponent("nope.caf"),
      createdAt: Date(),
      capturedAt: Date()
    )
    XCTAssertFalse(owner.release(foreign), "a foreign record may not disown the live session")
    XCTAssertEqual(owner.record?.historyID, live.historyID)

    // Stop: the surviving session's transcript is sealed into its own record.
    let stopping = try XCTUnwrap(owner.beginStop())
    XCTAssertEqual(stopping.historyID, live.historyID)
    let saved = try seal(stopping, transcript: "the whole meeting")
    owner.release(stopping)
    owner.finishedStopping()

    XCTAssertEqual(try status(live.historyID), .transcribed)
    let json = try recordJSON(live.historyID)
    XCTAssertEqual(json["transcriptText"] as? String, "the whole meeting")
    XCTAssertEqual(json["outputPath"] as? String, saved.outputURL.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: saved.outputURL.path))
    XCTAssertFalse(owner.isOwning)
  }

  func testACancelledStartTaskMayOnlyCleanUpAfterItself() throws {
    let first = try startedRecord(press())
    owner.finishedStarting()

    // A record that is no longer the owned one settles nothing and releases
    // nothing — the cancelled task's `activeRecord = nil` is what disowned a
    // live session and dropped its meeting on the floor.
    owner.release(first)
    let second = try startedRecord(press())
    XCTAssertFalse(owner.release(first))
    XCTAssertFalse(owner.settle(first))
    XCTAssertEqual(owner.record?.historyID, second.historyID)
  }

  func testAStartPressIsRefusedWhileASessionIsLive() throws {
    let first = try startedRecord(press())
    owner.finishedStarting()
    XCTAssertEqual(press(sessionIsLive: true), .ignored)
    XCTAssertEqual(owner.record?.historyID, first.historyID)
  }

  // MARK: - Every exit reaches a terminal status

  func testSettleFailsARecordInTheStageItIsActuallyIn() throws {
    let started = try startedRecord(press())
    XCTAssertEqual(try status(started.historyID), .recording)

    XCTAssertTrue(owner.settle(started))

    // `.recording`, so `failed(recording)` — NOT `failed(transcribing)`, which
    // `canAdvance` refuses and `updateStatus` therefore never writes, leaving
    // the record live forever.
    XCTAssertEqual(try status(started.historyID), .failed(stage: .recording))
    XCTAssertFalse(try status(started.historyID).isInFlight)
    XCTAssertFalse(owner.isOwning)
  }

  func testSettleAfterTheTranscribingAdvanceFailsInTranscribing() throws {
    let started = try startedRecord(press())
    owner.finishedStarting()
    XCTAssertTrue(LiveSessionPersistence.updateStatus(
      id: started.historyID,
      to: .transcribing,
      historyDirectory: historyDirectory
    ))

    XCTAssertTrue(owner.settle(started))
    XCTAssertEqual(try status(started.historyID), .failed(stage: .transcribing))
  }

  func testSettlingASealedRecordLeavesItAtRest() throws {
    let started = try startedRecord(press())
    owner.finishedStarting()
    try seal(started, transcript: "sealed")
    XCTAssertEqual(try status(started.historyID), .transcribed)

    // `transcribed` is a rest state: nothing is owed, and nothing is written.
    XCTAssertTrue(LiveSessionPersistence.settleAsFailed(
      id: started.historyID,
      historyDirectory: historyDirectory
    ))
    XCTAssertEqual(try status(started.historyID), .transcribed)
  }

  func testAStartPressSettlesARecordLeftOverFromAnEndedSession() throws {
    // A session that failed mid-meeting leaves its record owned while the
    // banner is up; Try Again is a Start press, and it may not abandon the old
    // record in a live status.
    let failed = try startedRecord(press())
    owner.finishedStarting()

    let retried = try startedRecord(press())
    XCTAssertNotEqual(retried.historyID, failed.historyID)
    XCTAssertEqual(try status(failed.historyID), .failed(stage: .recording))
    XCTAssertEqual(owner.record?.historyID, retried.historyID)

    // And the abandoned record kept everything it had: nothing on any failure
    // path deletes audio.
    let json = try recordJSON(failed.historyID)
    XCTAssertEqual(json["audioPath"] as? String, "recording.caf")
  }

  func testBeginStopEndsTheStartingWindow() throws {
    let started = try startedRecord(press())
    XCTAssertTrue(owner.isStarting)

    // Stop pressed during the start round trip is a stop of that session.
    XCTAssertEqual(owner.beginStop()?.historyID, started.historyID)
    XCTAssertFalse(owner.isStarting)
    XCTAssertTrue(owner.isStopping)
    owner.finishedStopping()
    XCTAssertFalse(owner.isStopping)
  }

  func testBeginStopWithNoRecordDoesNothing() {
    XCTAssertNil(owner.beginStop())
    XCTAssertFalse(owner.isStopping)
  }

  func testAnUnwritableStoreIsAHardStopRatherThanASessionRecordingIntoNowhere() {
    // A directory that cannot be created (a FILE where the history dir goes).
    let file = historyDirectory
      .deletingLastPathComponent()
      .appendingPathComponent("not-a-directory")
    FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
    let blocked = LiveSessionOwner(historyDirectory: { file })

    let decision = blocked.start(
      kind: .meeting,
      diarize: false,
      identify: false,
      sessionIsLive: false
    )
    guard case .unwritable = decision else {
      return XCTFail("a store that cannot be written to must refuse the session, got \(decision)")
    }
    XCTAssertFalse(blocked.isOwning)
    XCTAssertFalse(blocked.isStarting)
  }
}
