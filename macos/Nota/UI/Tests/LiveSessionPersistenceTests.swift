import Foundation
import XCTest

@testable import Nota

/// Pure file-writing tests for LiveSessionPersistence — temp directories only,
/// never the real `~/.nota` or `~/Documents/Nota`.
final class LiveSessionPersistenceTests: XCTestCase {
  private var outputDirectory: URL!
  private var historyDirectory: URL!
  private var tempAudioDirectory: URL!

  override func setUp() {
    super.setUp()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("nota-live-persistence-tests-\(UUID().uuidString)", isDirectory: true)
    outputDirectory = root.appendingPathComponent("output", isDirectory: true)
    historyDirectory = root.appendingPathComponent("history", isDirectory: true)
    tempAudioDirectory = root.appendingPathComponent("temp", isDirectory: true)
    for directory in [outputDirectory!, historyDirectory!, tempAudioDirectory!] {
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
  }

  override func tearDown() {
    try? FileManager.default.removeItem(
      at: outputDirectory.deletingLastPathComponent()
    )
    super.tearDown()
  }

  // MARK: - Fixtures

  /// Start a record the way the app does: on disk, `recording`, with its
  /// assets folder made, before any audio exists.
  private func beginRecording(
    kind: HistoryKind = .meeting,
    diarize: Bool = false,
    identify: Bool = false
  ) throws -> LiveSessionPersistence.StartedRecord {
    try LiveSessionPersistence.beginRecording(
      kind: kind,
      diarize: diarize,
      identify: identify,
      historyDirectory: historyDirectory
    )
  }

  /// Stand in for what the microphone would have written.
  @discardableResult
  private func writeAudio(
    _ started: LiveSessionPersistence.StartedRecord,
    bytes: Int = 12
  ) throws -> URL {
    try Data(repeating: 0x41, count: bytes).write(to: started.audioURL)
    return started.audioURL
  }

  private func makeResult(
    segments: [LiveMeetingSession.LiveSegment],
    transcript: String,
    duration: TimeInterval,
    audioURL: URL? = nil
  ) -> LiveMeetingSession.LiveMeetingResult {
    LiveMeetingSession.LiveMeetingResult(
      segments: segments,
      transcriptText: transcript,
      duration: duration,
      audioURL: audioURL
    )
  }

  private func recordJSON(_ id: String) throws -> [String: Any] {
    let url = historyDirectory.appendingPathComponent("\(id).json")
    return try XCTUnwrap(
      JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
    )
  }

  private func status(_ id: String) throws -> HistoryStatus {
    HistoryStatus.normalized(fromRecord: try recordJSON(id))
  }

  private func persistedFileNames(in directory: URL) -> Set<String> {
    let entries = (try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: []
    )) ?? []
    return Set(entries.map(\.lastPathComponent))
  }

  // MARK: - Sample zero: the record exists before the audio does

  func testRecordExistsWithStatusRecordingBeforeAnyAudioIsWritten() throws {
    let started = try beginRecording()

    // The record is on disk NOW — before the microphone has been asked for a
    // single buffer, and with nothing yet at the audio path it names.
    XCTAssertTrue(FileManager.default.fileExists(atPath: started.recordURL.path))
    XCTAssertEqual(try status(started.historyID), .recording)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: started.audioURL.path),
      "no audio has been recorded yet — the record is what comes first"
    )

    // The assets folder the audio will be written into is already there.
    var isDirectory: ObjCBool = false
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: started.assetsDirectory.path,
        isDirectory: &isDirectory
      )
    )
    XCTAssertTrue(isDirectory.boolValue)
    XCTAssertEqual(started.assetsDirectory.lastPathComponent, "\(started.historyID).assets")
    XCTAssertEqual(started.audioURL.lastPathComponent, "recording.caf")

    let json = try recordJSON(started.historyID)
    XCTAssertEqual(json["id"] as? String, started.historyID)
    XCTAssertEqual(json["kind"] as? String, "meeting")
    XCTAssertNotNil(json["createdAt"] as? String)
    XCTAssertNotNil(json["capturedAt"] as? String)
  }

  func testAudioPathIsRelativeToTheRecordsOwnAssetsFolder() throws {
    let started = try beginRecording()
    let json = try recordJSON(started.historyID)

    // Relative, and nothing but the file name: the store has to be movable
    // wholesale without rewriting a single record (XIA-428).
    XCTAssertEqual(json["audioPath"] as? String, "recording.caf")
    XCTAssertFalse((json["audioPath"] as? String ?? "/").contains("/"))

    XCTAssertEqual(
      LiveSessionPersistence.resolvedAudioURL(
        record: json,
        historyDirectory: historyDirectory
      )?.standardizedFileURL,
      started.audioURL.standardizedFileURL
    )

    // Point the resolver at a DIFFERENT history directory — as moving
    // ~/.nota would — and the same record still resolves, to the new place.
    let moved = URL(fileURLWithPath: "/Volumes/Archive/nota/history", isDirectory: true)
    XCTAssertEqual(
      LiveSessionPersistence.resolvedAudioURL(record: json, historyDirectory: moved)?.path,
      "/Volumes/Archive/nota/history/\(started.historyID).assets/recording.caf"
    )
  }

  func testResolvedAudioFallsBackToSourcePathForALegacyRecord() {
    // No audioPath at all — a record written before record-first recording.
    let legacy: [String: Any] = ["id": "legacy-1", "sourcePath": "/tmp/legacy.m4a"]
    XCTAssertEqual(
      LiveSessionPersistence.resolvedAudioURL(
        record: legacy,
        historyDirectory: historyDirectory
      )?.path,
      "/tmp/legacy.m4a"
    )
    XCTAssertNil(
      LiveSessionPersistence.resolvedAudioURL(record: [:], historyDirectory: historyDirectory)
    )
  }

  // MARK: - Sealing: nothing is moved, the record is filled in

  func testSealFillsTheSameRecordAndLeavesTheAudioWhereItWasRecorded() throws {
    let started = try beginRecording()
    try writeAudio(started, bytes: 4096)
    let result = makeResult(
      segments: [
        LiveMeetingSession.LiveSegment(id: UUID(), text: "Hello world.", endTime: 3),
        LiveMeetingSession.LiveSegment(id: UUID(), text: "Second segment.", endTime: 7)
      ],
      transcript: "Hello world. Second segment.",
      duration: 8,
      audioURL: started.audioURL
    )

    let saved = try LiveSessionPersistence.sealTranscript(
      started: started,
      result: result,
      outputDirectory: outputDirectory,
      historyDirectory: historyDirectory
    )

    // Same record, same id — not a second one built at the end.
    XCTAssertEqual(saved.historyID, started.historyID)
    XCTAssertEqual(saved.recordURL, started.recordURL)
    XCTAssertEqual(
      persistedFileNames(in: historyDirectory).filter { $0.hasSuffix(".json") }.count,
      1
    )

    // The audio never moved: it is still in the assets folder, and there is
    // no `.nota-input-…` copy in the output directory.
    XCTAssertEqual(saved.audioURL, started.audioURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: started.audioURL.path))
    XCTAssertFalse(
      persistedFileNames(in: outputDirectory).contains { $0.hasPrefix(".nota-input-") },
      "record-first recording writes the audio in place; nothing is moved after Stop"
    )

    let json = try recordJSON(started.historyID)
    XCTAssertEqual(HistoryStatus.normalized(fromRecord: json), .transcribed)
    XCTAssertEqual(json["transcriptText"] as? String, "Hello world. Second segment.")
    XCTAssertEqual(json["durationMinutes"] as? Int, 1)
    XCTAssertEqual(json["outputPath"] as? String, saved.outputURL.path)
    XCTAssertEqual(json["audioBytes"] as? Int, 4096)
    XCTAssertEqual(json["audioPath"] as? String, "recording.caf")

    let segments = try XCTUnwrap(json["segments"] as? [[String: Any]])
    XCTAssertEqual(segments.count, 2)
    XCTAssertEqual(segments[1]["start"] as? Int, 3, "second segment starts where the first ended")

    // Markdown follows the existing output naming convention.
    XCTAssertTrue(
      persistedFileNames(in: outputDirectory).contains { name in
        name.range(
          of: #"^Live-Meeting-\d{8}-\d{6}\.summary\.md$"#,
          options: .regularExpression
        ) != nil
      },
      "output names were \(persistedFileNames(in: outputDirectory))"
    )
  }

  func testCustomDisplayNameDrivesFilename() throws {
    let started = try beginRecording()
    try writeAudio(started)
    let saved = try LiveSessionPersistence.sealTranscript(
      started: started,
      result: makeResult(
        segments: [LiveMeetingSession.LiveSegment(id: UUID(), text: "Hello", endTime: 2)],
        transcript: "Hello",
        duration: 2,
        audioURL: started.audioURL
      ),
      displayName: "Client Sync 2026",
      outputDirectory: outputDirectory,
      historyDirectory: historyDirectory
    )
    XCTAssertTrue(saved.outputURL.lastPathComponent.hasPrefix("Client-Sync-2026-"))
  }

  // MARK: - Markdown shape + metadata parse-back

  func testMarkdownMirrorsCLIShapeAndParsesBackViaHistoryEntry() throws {
    let started = try beginRecording()
    try writeAudio(started)
    let saved = try LiveSessionPersistence.sealTranscript(
      started: started,
      result: makeResult(
        segments: [
          LiveMeetingSession.LiveSegment(id: UUID(), text: "First utterance.", endTime: 3),
          LiveMeetingSession.LiveSegment(id: UUID(), text: "Second utterance.", endTime: 7)
        ],
        transcript: "First utterance. Second utterance.",
        duration: 8,
        audioURL: started.audioURL
      ),
      title: "Live Meeting",
      outputDirectory: outputDirectory,
      historyDirectory: historyDirectory
    )

    let markdown = try String(contentsOf: saved.outputURL, encoding: .utf8)
    XCTAssertTrue(markdown.hasPrefix("# Live Meeting\n"))
    XCTAssertTrue(markdown.contains("**Captured:** "))
    XCTAssertTrue(markdown.contains("**Transcribed:** "))
    XCTAssertTrue(markdown.contains("**Duration:** 1 minutes\n"))
    XCTAssertTrue(markdown.contains("**Source:** recording.caf\n"))
    XCTAssertTrue(markdown.contains("## Full Transcript"))
    // CLI-style per-segment lines with `[MM:SS]` timestamps (start-derived).
    XCTAssertTrue(markdown.contains("[00:00] First utterance."))
    XCTAssertTrue(markdown.contains("[00:03] Second utterance."))

    let entry = HistoryEntry.make(url: saved.outputURL, modifiedAt: Date())
    XCTAssertEqual(entry.title, "Live Meeting")
    XCTAssertTrue(entry.tags.isEmpty)
  }

  // MARK: - Record schema (HistoryRecordInfo.find / EnrichmentRecord consumers)

  func testRecordSchemaMatchesMeetingConventions() throws {
    let started = try beginRecording()
    try writeAudio(started)
    let saved = try LiveSessionPersistence.sealTranscript(
      started: started,
      result: makeResult(
        segments: [
          LiveMeetingSession.LiveSegment(id: UUID(), text: "One", endTime: 3),
          LiveMeetingSession.LiveSegment(id: UUID(), text: "Two", endTime: 7)
        ],
        transcript: "One Two",
        duration: 90,
        audioURL: started.audioURL
      ),
      outputDirectory: outputDirectory,
      historyDirectory: historyDirectory
    )

    let json = try recordJSON(started.historyID)
    XCTAssertEqual(json["id"] as? String, saved.historyID)
    XCTAssertNotNil(json["createdAt"] as? String)
    XCTAssertNotNil(json["updatedAt"] as? String)
    XCTAssertNotNil(json["capturedAt"] as? String)
    XCTAssertEqual(json["sourcePath"] as? String, saved.audioURL.path)
    XCTAssertEqual(json["sourceName"] as? String, "recording.caf")
    XCTAssertEqual(json["provider"] as? String, "assemblyai")
    XCTAssertEqual(json["durationMinutes"] as? Int, 2)
    XCTAssertEqual(json["transcriptText"] as? String, "One Two")
    XCTAssertEqual(json["outputPath"] as? String, saved.outputURL.path)
    XCTAssertEqual(json["status"] as? String, "transcribed")

    let options = try XCTUnwrap(json["options"] as? [String: Any])
    XCTAssertEqual(options["diarize"] as? Bool, false)
    XCTAssertEqual(options["identify"] as? Bool, false)
    XCTAssertEqual(options["model"] as? String, "universal-3.5-pro-streaming")

    // The app's own lookup finds it and enrichment decodes it.
    let info = HistoryRecordInfo.find(
      outputPath: saved.outputURL.path,
      historyDir: historyDirectory
    )
    let found = try XCTUnwrap(info)
    XCTAssertEqual(found.historyID, saved.historyID)
    XCTAssertEqual(found.sourcePath, saved.audioURL.path)
    XCTAssertEqual(
      found.recordURL.resolvingSymlinksInPath(),
      saved.recordURL.resolvingSymlinksInPath()
    )

    let enrichment = try XCTUnwrap(EnrichmentRecord.load(from: found.recordURL))
    XCTAssertEqual(enrichment.id, saved.historyID)
    XCTAssertEqual(enrichment.status, "transcribed")
    XCTAssertNil(enrichment.summary)
  }

  // MARK: - Failure keeps the audio

  func testAFailedTranscriptionLeavesTheAudioOnDisk() throws {
    let started = try beginRecording()
    try writeAudio(started, bytes: 2048)

    XCTAssertThrowsError(
      try LiveSessionPersistence.sealTranscript(
        started: started,
        result: makeResult(
          segments: [],
          transcript: "   \n\t ",
          duration: 5,
          audioURL: started.audioURL
        ),
        outputDirectory: outputDirectory,
        historyDirectory: historyDirectory
      )
    ) { error in
      XCTAssertEqual(error as? LiveSessionPersistenceError, .emptyTranscript)
    }

    // The record says what went wrong, in which stage — and the recording is
    // still there. This is exactly the case the old code destroyed audio in.
    XCTAssertEqual(try status(started.historyID), .failed(stage: .transcribing))
    XCTAssertTrue(FileManager.default.fileExists(atPath: started.audioURL.path))
    XCTAssertEqual(
      try Data(contentsOf: started.audioURL).count,
      2048,
      "the audio is not merely present, it is intact"
    )
    XCTAssertTrue(persistedFileNames(in: outputDirectory).isEmpty)
  }

  func testASessionThatRecordedNothingFailsInTheRecordingStage() throws {
    let started = try beginRecording()
    // No audio was ever written.
    XCTAssertThrowsError(
      try LiveSessionPersistence.sealTranscript(
        started: started,
        result: makeResult(
          segments: [LiveMeetingSession.LiveSegment(id: UUID(), text: "Hello", endTime: 2)],
          transcript: "Hello",
          duration: 2,
          audioURL: nil
        ),
        outputDirectory: outputDirectory,
        historyDirectory: historyDirectory
      )
    ) { error in
      XCTAssertEqual(error as? LiveSessionPersistenceError, .missingAudio)
    }
    XCTAssertEqual(try status(started.historyID), .failed(stage: .recording))
  }

  func testAFailedSummaryLeavesAudioAndTranscript() throws {
    let started = try beginRecording(kind: .memo)
    try writeAudio(started, bytes: 999)
    let saved = try LiveSessionPersistence.sealTranscript(
      started: started,
      result: makeResult(
        segments: [LiveMeetingSession.LiveSegment(id: UUID(), text: "A note.", endTime: 2)],
        transcript: "A note.",
        duration: 2,
        audioURL: started.audioURL
      ),
      outputDirectory: outputDirectory,
      historyDirectory: historyDirectory
    )

    // The memo path: summarizing, then the summary fails.
    XCTAssertTrue(LiveSessionPersistence.updateStatus(
      id: started.historyID,
      to: .summarizing,
      historyDirectory: historyDirectory
    ))
    XCTAssertTrue(LiveSessionPersistence.updateStatus(
      id: started.historyID,
      to: .failed(stage: .summarizing),
      historyDirectory: historyDirectory
    ))

    XCTAssertEqual(try status(started.historyID), .failed(stage: .summarizing))
    XCTAssertTrue(FileManager.default.fileExists(atPath: started.audioURL.path))
    XCTAssertEqual(try recordJSON(started.historyID)["transcriptText"] as? String, "A note.")
    XCTAssertTrue(FileManager.default.fileExists(atPath: saved.outputURL.path))
  }

  // MARK: - Status transitions on disk

  func testUpdateStatusWalksTheLifecycleAndRefusesToSkipIt() throws {
    let started = try beginRecording()
    let dir = historyDirectory!

    XCTAssertFalse(
      LiveSessionPersistence.updateStatus(id: started.historyID, to: .done, historyDirectory: dir),
      "a session cannot go straight from recording to done"
    )
    XCTAssertEqual(try status(started.historyID), .recording)

    XCTAssertTrue(
      LiveSessionPersistence.updateStatus(
        id: started.historyID, to: .transcribing, historyDirectory: dir
      )
    )
    XCTAssertTrue(
      LiveSessionPersistence.updateStatus(
        id: started.historyID, to: .transcribed, historyDirectory: dir
      )
    )
    XCTAssertTrue(
      LiveSessionPersistence.updateStatus(
        id: started.historyID, to: .summarizing, historyDirectory: dir
      )
    )
    XCTAssertTrue(
      LiveSessionPersistence.updateStatus(
        id: started.historyID, to: .done, historyDirectory: dir
      )
    )

    XCTAssertFalse(
      LiveSessionPersistence.updateStatus(
        id: started.historyID, to: .summarizing, historyDirectory: dir
      ),
      "done is terminal"
    )
    XCTAssertEqual(try status(started.historyID), .done)
  }

  func testUpdateStatusPreservesEveryOtherFieldOnTheRecord() throws {
    let started = try beginRecording()
    // A field this app does not model, written by the CLI.
    LiveSessionPersistence.mutateRecord(
      id: started.historyID,
      historyDirectory: historyDirectory,
      ["speakerClips": ["Speaker 1": "\(started.historyID).assets/Speaker 1.pcm"]]
    )
    LiveSessionPersistence.updateStatus(
      id: started.historyID,
      to: .transcribing,
      historyDirectory: historyDirectory
    )
    let json = try recordJSON(started.historyID)
    XCTAssertNotNil(json["speakerClips"], "a status write is a merge, never a rebuild")
    XCTAssertEqual(json["audioPath"] as? String, "recording.caf")
  }

  // MARK: - Interrupted recovery

  func testInterruptedSessionResolvesToFailedWithItsAudioIntact() throws {
    // Exactly what a killed app leaves behind: a `recording` record with a
    // playable file in it and no process anywhere.
    let started = try beginRecording()
    try writeAudio(started, bytes: 1234)

    let resolved = LiveSessionPersistence.resolveInterruptedRecords(
      historyDirectory: historyDirectory
    )

    XCTAssertEqual(resolved, [started.historyID])
    XCTAssertEqual(try status(started.historyID), .failed(stage: .recording))
    XCTAssertEqual(try recordJSON(started.historyID)["interrupted"] as? Bool, true)
    // "Interrupted", not "Failed (recording)" — nothing failed, a process left.
    XCTAssertEqual(
      try status(started.historyID).presentation(interrupted: true),
      "Interrupted"
    )
    // And the recording is still there, and still complete.
    XCTAssertEqual(try Data(contentsOf: started.audioURL).count, 1234)
  }

  func testInterruptedRecoveryResolvesEveryLiveStage() throws {
    var expected: [String: HistoryStatus] = [:]
    let cases: [(HistoryStage, HistoryStatus)] = [
      (.recording, .recording),
      (.transcribing, .transcribing),
      (.summarizing, .summarizing)
    ]
    for (stage, live) in cases {
      let started = try beginRecording()
      // Walk it into the live stage under test.
      if live != .recording {
        LiveSessionPersistence.mutateRecord(
          id: started.historyID,
          historyDirectory: historyDirectory,
          ["status": live.rawValue]
        )
      }
      expected[started.historyID] = .failed(stage: stage)
    }

    LiveSessionPersistence.resolveInterruptedRecords(historyDirectory: historyDirectory)

    for (id, wanted) in expected {
      XCTAssertEqual(try status(id), wanted)
    }
  }

  func testInterruptedRecoveryLeavesRestedAndTerminalRecordsAlone() throws {
    for expected in [HistoryStatus.transcribed, .done, .failed(stage: .transcribing)] {
      let started = try beginRecording()
      LiveSessionPersistence.mutateRecord(
        id: started.historyID,
        historyDirectory: historyDirectory,
        ["status": expected.rawValue]
      )
      let resolved = LiveSessionPersistence.resolveInterruptedRecords(
        historyDirectory: historyDirectory
      )
      XCTAssertFalse(
        resolved.contains(started.historyID),
        "\(expected.rawValue) was not interrupted"
      )
      XCTAssertEqual(try status(started.historyID), expected)
    }
  }

  func testInterruptedRecoveryNeverTouchesALegacyRecord() throws {
    // No status field at all, and a "completed" one: the two shapes every
    // record on an existing machine has. Neither may be swept up as live.
    try writeRecord(named: "legacy-none.json", [
      "id": "legacy-none",
      "outputPath": "/tmp/legacy-none.summary.md",
      "sourcePath": "/tmp/legacy-none.m4a"
    ])
    try writeRecord(named: "legacy-completed.json", [
      "id": "legacy-completed",
      "status": "completed",
      "outputPath": "/tmp/legacy-completed.summary.md",
      "sourcePath": "/tmp/legacy-completed.m4a"
    ])

    let resolved = LiveSessionPersistence.resolveInterruptedRecords(
      historyDirectory: historyDirectory
    )
    XCTAssertTrue(resolved.isEmpty, "resolved \(resolved)")
    XCTAssertEqual(try status("legacy-none"), .transcribed)
    XCTAssertEqual(try status("legacy-completed"), .done)
  }

  // MARK: - Pure helpers

  func testHistoryIDMirrorsCLIFormat() {
    let id = LiveSessionPersistence.makeHistoryID(createdAtISO8601: "2026-07-17T00:41:04.089Z")
    XCTAssertNotNil(
      id.range(of: #"^20260717-004104Z-[0-9a-f]{8}$"#, options: .regularExpression),
      "id was \(id)"
    )
  }

  func testDurationMinutesRoundsUpFlooredAtOne() {
    XCTAssertEqual(LiveSessionPersistence.durationMinutes(for: 0), 1)
    XCTAssertEqual(LiveSessionPersistence.durationMinutes(for: 5), 1)
    XCTAssertEqual(LiveSessionPersistence.durationMinutes(for: 45), 1)
    XCTAssertEqual(LiveSessionPersistence.durationMinutes(for: 61), 2)
    XCTAssertEqual(LiveSessionPersistence.durationMinutes(for: 90), 2)
    XCTAssertEqual(LiveSessionPersistence.durationMinutes(for: 120), 2)
    XCTAssertEqual(LiveSessionPersistence.durationMinutes(for: 121), 3)
  }

  func testSegmentDictionariesDeriveStartsFromPreviousEnds() {
    let segments = [
      LiveMeetingSession.LiveSegment(id: UUID(), text: "a", endTime: 3),
      LiveMeetingSession.LiveSegment(id: UUID(), text: "b", endTime: 7),
      LiveMeetingSession.LiveSegment(id: UUID(), text: "c", endTime: 9)
    ]
    let dicts = LiveSessionPersistence.segmentDictionaries(segments)
    XCTAssertEqual(dicts.map { $0["start"] as? Int }, [0, 3, 7])
    XCTAssertEqual(dicts.map { $0["end"] as? Int }, [3, 7, 9])
    XCTAssertEqual(dicts.map { $0["text"] as? String }, ["a", "b", "c"])
  }

  // MARK: - Kind field

  // The kind and the option flags are written at sample zero now, not at the
  // end: the record has to say what it is from the moment it exists.
  func testBeginRecordingDefaultsKindToMeeting() throws {
    let started = try beginRecording()
    let json = try recordJSON(started.historyID)
    XCTAssertEqual(json["kind"] as? String, "meeting")
    let options = try XCTUnwrap(json["options"] as? [String: Any])
    XCTAssertEqual(options["diarize"] as? Bool, false)
    XCTAssertEqual(options["identify"] as? Bool, false)
  }

  func testBeginRecordingWritesMemoKindAndPresetFlags() throws {
    let started = try beginRecording(kind: .memo, diarize: true, identify: true)
    let json = try recordJSON(started.historyID)
    XCTAssertEqual(json["kind"] as? String, "memo")
    let options = try XCTUnwrap(json["options"] as? [String: Any])
    XCTAssertEqual(options["diarize"] as? Bool, true)
    XCTAssertEqual(options["identify"] as? Bool, true)
  }

  // MARK: - Legacy kind inference (HistoryRecordInfo)

  func testKindInferencePrefersExplicitKindField() throws {
    let explicit: [String: Any] = [
      "outputPath": "/tmp/explicit.summary.md",
      "status": "transcribed",
      "kind": "memo",
      "options": ["model": "universal-3.5-pro-streaming", "diarize": false, "identify": false]
    ]
    let legacyLive: [String: Any] = [
      "outputPath": "/tmp/legacy-live.summary.md",
      "status": "transcribed",
      "options": ["model": "universal-3.5-pro-streaming", "diarize": false, "identify": false]
    ]
    let legacyFile: [String: Any] = [
      "outputPath": "/tmp/legacy-file.summary.md",
      "status": "completed",
      "options": ["model": "universal-3-5-pro", "diarize": true, "identify": true]
    ]
    for (name, record) in ["a.json": explicit, "b.json": legacyLive, "c.json": legacyFile] {
      let url = historyDirectory.appendingPathComponent(name)
      try JSONSerialization.data(withJSONObject: record).write(to: url)
    }

    let result = HistoryRecordInfo.kindsAndStatusesByOutputPath(historyDir: historyDirectory)
    XCTAssertEqual(result.statuses["/tmp/explicit.summary.md"], .transcribed)
    // The legacy spelling normalizes on the way in, so the dashboard reads the
    // same vocabulary for a record written years apart from this one.
    XCTAssertEqual(result.statuses["/tmp/legacy-file.summary.md"], .done)
    XCTAssertEqual(result.kinds["/tmp/explicit.summary.md"], .memo, "explicit kind wins")
    XCTAssertEqual(result.kinds["/tmp/legacy-live.summary.md"], .meeting, "legacy streaming-model record infers meeting")
    XCTAssertEqual(result.kinds["/tmp/legacy-file.summary.md"], .file, "legacy CLI record infers file")
  }

  // MARK: - Home stats aggregation

  private func writeRecord(named name: String, _ record: [String: Any]) throws {
    let url = historyDirectory.appendingPathComponent(name)
    try JSONSerialization.data(withJSONObject: record).write(to: url)
  }

  private func recordJSON(
    createdAt: String,
    kind: String? = nil,
    durationMinutes: Int = 5,
    actionItems: [String]? = nil,
    outputPath: String
  ) -> [String: Any] {
    var json: [String: Any] = [
      "id": "record-\(UUID().uuidString.prefix(8))",
      "createdAt": createdAt,
      "sourcePath": "/tmp/source-\(URL(fileURLWithPath: outputPath).lastPathComponent)",
      "durationMinutes": durationMinutes,
      "outputPath": outputPath,
      "options": ["model": "universal-3.5-pro-streaming", "diarize": false, "identify": false]
    ]
    if let kind { json["kind"] = kind }
    if let actionItems { json["summary"] = ["actionItems": actionItems] }
    return json
  }

  func testHomeStatsAggregatesWeekWindowKindsAndActionItems() throws {
    // Monday 2026-08-03 09:00Z = "now" in the test.
    // The default ISO8601DateFormatter rejects fractional seconds — with them
    // this force-unwrap crashed the whole test host, and the crash was
    // invisible in the "Executed N tests" summaries (a dead runner records no
    // failure; only the trailing TEST FAILED shows it).
    let now = ISO8601DateFormatter().date(from: "2026-08-03T09:00:00Z")!
    try writeRecord(named: "a.json", recordJSON(
      createdAt: "2026-08-02T10:00:00.000Z", // this week
      kind: "meeting",
      durationMinutes: 12,
      actionItems: ["[ ] Write the spec"],
      outputPath: "/tmp/a.summary.md"
    ))
    try writeRecord(named: "b.json", recordJSON(
      createdAt: "2026-08-01T10:00:00.000Z", // this week
      kind: "memo",
      durationMinutes: 3,
      outputPath: "/tmp/b.summary.md"
    ))
    try writeRecord(named: "c.json", recordJSON(
      createdAt: "2026-07-20T10:00:00.000Z", // outside the window
      kind: "meeting",
      durationMinutes: 99,
      actionItems: ["[ ] Stale", "[ ] Also stale"],
      outputPath: "/tmp/c.summary.md"
    ))
    try writeRecord(named: "d.json", recordJSON(
      createdAt: "2026-08-03T08:00:00.000Z", // today
      durationMinutes: 7,                    // no kind → legacy inference = meeting
      outputPath: "/tmp/d.summary.md"
    ))

    let stats = HistoryRecordInfo.homeStats(historyDir: historyDirectory, now: now)

    XCTAssertEqual(stats.transcribedMinutes, 12 + 3 + 7)
    XCTAssertEqual(stats.meetings, 2)   // a + d (legacy meeting)
    XCTAssertEqual(stats.memos, 1)      // b
    XCTAssertEqual(stats.actionItems, 1) // only a's in-window summary counts
    XCTAssertFalse(stats.isEmpty)
  }

  func testHomeStatsEmptyWhenNoRecordsInWindow() throws {
    // The default ISO8601DateFormatter rejects fractional seconds — with them
    // this force-unwrap crashed the whole test host, and the crash was
    // invisible in the "Executed N tests" summaries (a dead runner records no
    // failure; only the trailing TEST FAILED shows it).
    let now = ISO8601DateFormatter().date(from: "2026-08-03T09:00:00Z")!
    try writeRecord(named: "a.json", recordJSON(
      createdAt: "2026-07-20T10:00:00.000Z",
      kind: "meeting",
      durationMinutes: 99,
      outputPath: "/tmp/a.summary.md"
    ))

    let stats = HistoryRecordInfo.homeStats(historyDir: historyDirectory, now: now)

    XCTAssertTrue(stats.isEmpty)
    XCTAssertEqual(stats.transcribedMinutes, 0)
  }

  // MARK: - Pinned flag

  func testSetPinnedPersistsAndPreservesOtherKeys() throws {
    try writeRecord(named: "a.json", recordJSON(
      createdAt: "2026-08-02T10:00:00.000Z",
      kind: "meeting",
      durationMinutes: 5,
      outputPath: "/tmp/a.summary.md"
    ))

    // Pin it, then re-scan: the flag round-trips through the details map.
    HistoryRecordInfo.setPinned(true, outputPath: "/tmp/a.summary.md", historyDir: historyDirectory)
    var details = HistoryRecordInfo.detailsByOutputPath(historyDir: historyDirectory)
    XCTAssertEqual(details["/tmp/a.summary.md"]?.pinned, true)

    // Unpin restores, and unrelated keys (kind/status) survive the write.
    HistoryRecordInfo.setPinned(false, outputPath: "/tmp/a.summary.md", historyDir: historyDirectory)
    details = HistoryRecordInfo.detailsByOutputPath(historyDir: historyDirectory)
    XCTAssertEqual(details["/tmp/a.summary.md"]?.pinned, false)
    XCTAssertEqual(details["/tmp/a.summary.md"]?.kind, .meeting)
    // This fixture carries no `status` at all — a record from before the
    // field existed. It reads as `transcribed` (no summary on it), not as
    // nothing: every record that exists resolves to a status.
    XCTAssertEqual(details["/tmp/a.summary.md"]?.status, .transcribed)
  }

  func testSetPinnedIsNoOpWithoutMatchingRecord() throws {
    HistoryRecordInfo.setPinned(true, outputPath: "/tmp/nope.summary.md", historyDir: historyDirectory)
    let details = HistoryRecordInfo.detailsByOutputPath(historyDir: historyDirectory)
    XCTAssertTrue(details.isEmpty)
  }
}
