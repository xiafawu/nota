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

  private func makeTempAudio(named name: String = "session-\(UUID().uuidString).wav") throws -> URL {
    let url = tempAudioDirectory.appendingPathComponent(name)
    // Arbitrary bytes — persistence never inspects audio content.
    try Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45])
      .write(to: url)
    return url
  }

  private func makeResult(
    segments: [LiveMeetingSession.LiveSegment],
    transcript: String,
    duration: TimeInterval,
    audioURL: URL? = nil
  ) throws -> LiveMeetingSession.LiveMeetingResult {
    LiveMeetingSession.LiveMeetingResult(
      segments: segments,
      transcriptText: transcript,
      duration: duration,
      audioURL: try audioURL ?? makeTempAudio()
    )
  }

  private func persistedFileNames(in directory: URL) -> Set<String> {
    let entries = (try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: []
    )) ?? []
    return Set(entries.map(\.lastPathComponent))
  }

  // MARK: - Naming + file placement

  func testPersistWritesMarkdownAudioAndRecordWithConventions() throws {
    let audio = try makeTempAudio()
    let result = try makeResult(
      segments: [
        LiveMeetingSession.LiveSegment(id: UUID(), text: "Hello world.", endTime: 3),
        LiveMeetingSession.LiveSegment(id: UUID(), text: "Second segment.", endTime: 7)
      ],
      transcript: "Hello world. Second segment.",
      duration: 8,
      audioURL: audio
    )

    let saved = try LiveSessionPersistence.persist(
      result: result,
      outputDirectory: outputDirectory,
      historyDirectory: historyDirectory
    )

    let outputNames = persistedFileNames(in: outputDirectory)
    let historyNames = persistedFileNames(in: historyDirectory)

    // Markdown follows the existing output naming convention
    // `<DisplayName>-<yyyyMMdd-HHmmss>.summary.md`.
    XCTAssertTrue(
      outputNames.contains { name in
        name.range(of: #"^Live-Meeting-\d{8}-\d{6}\.summary\.md$"#, options: .regularExpression) != nil
      },
      "output names were \(outputNames)"
    )
    XCTAssertEqual(saved.outputURL.deletingPathExtension().pathExtension, "summary")
    XCTAssertEqual(saved.outputURL.pathExtension, "md")

    // Audio follows the stable-input convention and was moved (not copied).
    XCTAssertTrue(
      outputNames.contains { name in
        name.range(of: #"^\.nota-input-\d+-[0-9A-F-]+\.wav$"#, options: [.regularExpression, .caseInsensitive]) != nil
      },
      "output names were \(outputNames)"
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path), "temp audio should be moved")
    XCTAssertTrue(FileManager.default.fileExists(atPath: saved.audioURL.path))

    // Record: one `<id>.json` whose id matches its filename.
    XCTAssertEqual(historyNames.count, 1, "history names were \(historyNames)")
    XCTAssertTrue(historyNames.contains("\(saved.historyID).json"))
    XCTAssertEqual(saved.recordURL.lastPathComponent, "\(saved.historyID).json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: saved.recordURL.path))
  }

  func testCustomDisplayNameDrivesFilename() throws {
    let result = try makeResult(
      segments: [LiveMeetingSession.LiveSegment(id: UUID(), text: "Hello", endTime: 2)],
      transcript: "Hello",
      duration: 2
    )
    let saved = try LiveSessionPersistence.persist(
      result: result,
      displayName: "Client Sync 2026",
      outputDirectory: outputDirectory,
      historyDirectory: historyDirectory
    )
    XCTAssertTrue(saved.outputURL.lastPathComponent.hasPrefix("Client-Sync-2026-"))
  }

  // MARK: - Markdown shape + metadata parse-back

  func testMarkdownMirrorsCLIShapeAndParsesBackViaHistoryEntry() throws {
    let result = try makeResult(
      segments: [
        LiveMeetingSession.LiveSegment(id: UUID(), text: "First utterance.", endTime: 3),
        LiveMeetingSession.LiveSegment(id: UUID(), text: "Second utterance.", endTime: 7)
      ],
      transcript: "First utterance. Second utterance.",
      duration: 8
    )
    let saved = try LiveSessionPersistence.persist(
      result: result,
      title: "Live Meeting",
      outputDirectory: outputDirectory,
      historyDirectory: historyDirectory
    )

    let markdown = try String(contentsOf: saved.outputURL, encoding: .utf8)
    XCTAssertTrue(markdown.hasPrefix("# Live Meeting\n"))
    XCTAssertTrue(markdown.contains("**Captured:** "))
    XCTAssertTrue(markdown.contains("**Transcribed:** "))
    XCTAssertTrue(markdown.contains("**Duration:** 1 minutes\n"))
    XCTAssertTrue(markdown.contains("**Source:** \(saved.audioURL.lastPathComponent)\n"))
    XCTAssertTrue(markdown.contains("## Full Transcript"))
    // CLI-style per-segment lines with `[MM:SS]` timestamps (start-derived).
    XCTAssertTrue(markdown.contains("[00:00] First utterance."))
    XCTAssertTrue(markdown.contains("[00:03] Second utterance."))

    // parseSummaryMetadata round-trip via the public HistoryEntry path: the
    // title comes from the `# ` heading, tags from the `**Tags:**` line
    // (absent here → empty).
    let entry = HistoryEntry.make(url: saved.outputURL, modifiedAt: Date())
    XCTAssertEqual(entry.title, "Live Meeting")
    XCTAssertTrue(entry.tags.isEmpty)
  }

  // MARK: - Record schema (HistoryRecordInfo.find / EnrichmentRecord consumers)

  func testRecordSchemaMatchesMeetingConventions() throws {
    let audio = try makeTempAudio()
    let result = try makeResult(
      segments: [
        LiveMeetingSession.LiveSegment(id: UUID(), text: "One", endTime: 3),
        LiveMeetingSession.LiveSegment(id: UUID(), text: "Two", endTime: 7)
      ],
      transcript: "One Two",
      duration: 90,
      audioURL: audio
    )
    let saved = try LiveSessionPersistence.persist(
      result: result,
      outputDirectory: outputDirectory,
      historyDirectory: historyDirectory
    )

    let data = try Data(contentsOf: saved.recordURL)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    XCTAssertEqual(json["id"] as? String, saved.historyID)
    XCTAssertNotNil(json["createdAt"] as? String)
    XCTAssertNotNil(json["updatedAt"] as? String)
    XCTAssertNotNil(json["capturedAt"] as? String)
    XCTAssertEqual(json["sourcePath"] as? String, saved.audioURL.path)
    XCTAssertEqual(json["sourceName"] as? String, saved.audioURL.lastPathComponent)
    XCTAssertEqual(json["provider"] as? String, "assemblyai")
    XCTAssertEqual(json["durationMinutes"] as? Int, 2)
    XCTAssertEqual(json["transcriptText"] as? String, "One Two")
    XCTAssertEqual(json["outputPath"] as? String, saved.outputURL.path)
    XCTAssertEqual(json["status"] as? String, "transcribed")

    let options = try XCTUnwrap(json["options"] as? [String: Any])
    XCTAssertEqual(options["diarize"] as? Bool, false)
    XCTAssertEqual(options["identify"] as? Bool, false)
    XCTAssertEqual(options["model"] as? String, "universal-3.5-pro-streaming")

    let segments = try XCTUnwrap(json["segments"] as? [[String: Any]])
    XCTAssertEqual(segments.count, 2)
    XCTAssertEqual(segments[0]["start"] as? Int, 0)
    XCTAssertEqual(segments[0]["end"] as? Int, 3)
    XCTAssertEqual(segments[0]["text"] as? String, "One")
    XCTAssertEqual(segments[1]["start"] as? Int, 3, "second segment starts where the first ended")
    XCTAssertEqual(segments[1]["end"] as? Int, 7)
    XCTAssertEqual(segments[1]["text"] as? String, "Two")

    // The app's own lookup finds it and enrichment decodes it (no summary →
    // placeholder-ready "transcribed" record).
    let info = HistoryRecordInfo.find(
      outputPath: saved.outputURL.path,
      historyDir: historyDirectory
    )
    let found = try XCTUnwrap(info)
    XCTAssertEqual(found.historyID, saved.historyID)
    XCTAssertEqual(found.sourcePath, saved.audioURL.path)
    // contentsOfDirectory resolves /var → /private/var; persist's URL does
    // not — compare on the resolved form.
    XCTAssertEqual(
      found.recordURL.resolvingSymlinksInPath(),
      saved.recordURL.resolvingSymlinksInPath()
    )

    let enrichment = try XCTUnwrap(EnrichmentRecord.load(from: found.recordURL))
    XCTAssertEqual(enrichment.id, saved.historyID)
    XCTAssertEqual(enrichment.status, "transcribed")
    XCTAssertNil(enrichment.summary)
  }

  // MARK: - Skip / error handling

  func testEmptyTranscriptSkipsPersistenceEntirely() throws {
    let audio = try makeTempAudio()
    let result = try makeResult(
      segments: [],
      transcript: "   \n\t ",
      duration: 5,
      audioURL: audio
    )

    XCTAssertThrowsError(
      try LiveSessionPersistence.persist(
        result: result,
        outputDirectory: outputDirectory,
        historyDirectory: historyDirectory
      )
    ) { error in
      XCTAssertEqual(error as? LiveSessionPersistenceError, .emptyTranscript)
    }

    XCTAssertTrue(persistedFileNames(in: outputDirectory).isEmpty)
    XCTAssertTrue(persistedFileNames(in: historyDirectory).isEmpty)
    // The temp audio is untouched — nothing was moved.
    XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
  }

  func testMissingAudioThrows() throws {
    // Construct directly: makeResult substitutes a temp file for nil audio.
    let result = LiveMeetingSession.LiveMeetingResult(
      segments: [LiveMeetingSession.LiveSegment(id: UUID(), text: "Hello", endTime: 2)],
      transcriptText: "Hello",
      duration: 2,
      audioURL: nil
    )

    XCTAssertThrowsError(
      try LiveSessionPersistence.persist(
        result: result,
        outputDirectory: outputDirectory,
        historyDirectory: historyDirectory
      )
    ) { error in
      XCTAssertEqual(error as? LiveSessionPersistenceError, .missingAudio)
    }
    XCTAssertTrue(persistedFileNames(in: outputDirectory).isEmpty)
    XCTAssertTrue(persistedFileNames(in: historyDirectory).isEmpty)
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

  func testPersistDefaultsKindToMeeting() throws {
    let result = try makeResult(
      segments: [LiveMeetingSession.LiveSegment(id: UUID(), text: "Hello", endTime: 2)],
      transcript: "Hello",
      duration: 2
    )
    let saved = try LiveSessionPersistence.persist(
      result: result,
      outputDirectory: outputDirectory,
      historyDirectory: historyDirectory
    )

    let data = try Data(contentsOf: saved.recordURL)
    let json = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    XCTAssertEqual(json["kind"] as? String, "meeting")
    let options = try XCTUnwrap(json["options"] as? [String: Any])
    XCTAssertEqual(options["diarize"] as? Bool, false)
    XCTAssertEqual(options["identify"] as? Bool, false)
  }

  func testPersistWritesMemoKindAndPresetFlags() throws {
    let result = try makeResult(
      segments: [LiveMeetingSession.LiveSegment(id: UUID(), text: "Quick note", endTime: 3)],
      transcript: "Quick note",
      duration: 3
    )
    let saved = try LiveSessionPersistence.persist(
      result: result,
      kind: .memo,
      diarize: true,
      identify: true,
      outputDirectory: outputDirectory,
      historyDirectory: historyDirectory
    )

    let data = try Data(contentsOf: saved.recordURL)
    let json = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
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
    XCTAssertEqual(result.statuses["/tmp/explicit.summary.md"], "transcribed")
    XCTAssertEqual(result.kinds["/tmp/explicit.summary.md"], .memo, "explicit kind wins")
    XCTAssertEqual(result.kinds["/tmp/legacy-live.summary.md"], .meeting, "legacy streaming-model record infers meeting")
    XCTAssertEqual(result.kinds["/tmp/legacy-file.summary.md"], .file, "legacy CLI record infers file")
  }
}
