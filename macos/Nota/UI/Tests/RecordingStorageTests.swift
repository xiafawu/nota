import XCTest
@testable import Nota

/// Deletion verbs and storage visibility (XIA-436).
///
/// Deletion is the one irreversible thing this app does, so every case pins
/// what it did NOT delete as well as what it did. `RecordingStore` is a plain
/// enum over injectable directories precisely so these run without a
/// `NotaModel` (whose init sweeps the real `~/.nota`).
final class RecordingStorageTests: XCTestCase {
  private var historyDir: URL!
  private var fileManager: FileManager { .default }

  override func setUpWithError() throws {
    historyDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("nota-storage-tests-\(UUID().uuidString)")
    try fileManager.createDirectory(at: historyDir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? fileManager.removeItem(at: historyDir)
  }

  // MARK: - Fixtures

  @discardableResult
  private func seedRecord(
    id: String,
    audioBytes: Int? = 2048,
    clipBytes: Int? = nil,
    outputPath: String? = nil,
    sourcePath: String = "/tmp/original.m4a"
  ) throws -> URL {
    let assets = historyDir.appendingPathComponent("\(id).assets", isDirectory: true)
    try fileManager.createDirectory(at: assets, withIntermediateDirectories: true)
    if let audioBytes {
      try Data(count: audioBytes).write(to: assets.appendingPathComponent("recording.caf"))
    }
    if let clipBytes {
      try Data(count: clipBytes).write(to: assets.appendingPathComponent("Speaker 1.pcm"))
    }

    var record: [String: Any] = [
      "id": id,
      "createdAt": "2026-01-01T00:00:00.000Z",
      "updatedAt": "2026-01-01T00:00:00.000Z",
      "sourcePath": sourcePath,
      "sourceName": "recording.caf",
      "provider": "assemblyai",
      "options": ["diarize": true, "identify": false, "model": "gpt-5-mini"],
      "durationMinutes": 5,
      "transcriptText": "the transcript survives",
      "segments": [["start": 0, "end": 1, "text": "the transcript survives"]],
      "summary": ["title": "A meeting", "tags": ["q1"], "narrative": "n",
                  "keyTopics": [], "decisions": [], "actionItems": []],
      "status": "done"
    ]
    if audioBytes != nil {
      record["audioPath"] = "recording.caf"
      record["audioBytes"] = audioBytes!
    }
    if clipBytes != nil {
      record["speakerClips"] = ["Speaker 1": "\(id).assets/Speaker 1.pcm"]
    }
    if let outputPath { record["outputPath"] = outputPath }

    let url = historyDir.appendingPathComponent("\(id).json")
    try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted]).write(to: url)
    return url
  }

  private func loadJSON(_ id: String) throws -> [String: Any] {
    let data = try Data(contentsOf: historyDir.appendingPathComponent("\(id).json"))
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  // MARK: - Locating

  func testLocateFindsTheRecordBehindARowAndItsAudio() throws {
    let output = historyDir.appendingPathComponent("notes.summary.md")
    try "# notes".write(to: output, atomically: true, encoding: .utf8)
    try seedRecord(id: "rec", audioBytes: 4096, outputPath: output.path)

    let located = try XCTUnwrap(
      RecordingStore.locate(outputPath: output, historyDirectory: historyDir)
    )

    XCTAssertEqual(located.id, "rec")
    XCTAssertEqual(located.audioBytes, 4096)
    XCTAssertTrue(located.hasTranscript)
    XCTAssertEqual(located.outputPath, output.path)
  }

  func testLocateReturnsNilForAPathNoRecordNames() throws {
    try seedRecord(id: "rec", outputPath: "/tmp/somewhere-else.md")

    XCTAssertNil(
      RecordingStore.locate(
        outputPath: URL(fileURLWithPath: "/tmp/unrelated.md"),
        historyDirectory: historyDir
      )
    )
  }

  func testALegacyRecordKeepsNoAudioAndNeverResolvesToItsSourcePath() throws {
    // `sourcePath` is the OWNER's own file, outside the store. It is not ours
    // to count and not ours to delete.
    let ownersFile = historyDir.appendingPathComponent("owners-own.m4a")
    try Data(count: 9999).write(to: ownersFile)
    let output = historyDir.appendingPathComponent("legacy.summary.md")
    try "# legacy".write(to: output, atomically: true, encoding: .utf8)
    try seedRecord(id: "legacy", audioBytes: nil, outputPath: output.path,
                   sourcePath: ownersFile.path)

    let located = try XCTUnwrap(
      RecordingStore.locate(outputPath: output, historyDirectory: historyDir)
    )

    XCTAssertNil(located.audioURL)
    XCTAssertNil(located.audioBytes)
    XCTAssertEqual(StorageFormat.audio(located.audioBytes), "audio not kept")
  }

  func testAnAudioPathThatClimbsOutOfTheAssetsFolderIsRefused() {
    // The value is read off a JSON file and handed to a remove. A record must
    // not be able to aim a deletion at an arbitrary file.
    let json: [String: Any] = ["id": "evil", "audioPath": "../../../../etc/hosts"]

    XCTAssertNil(RecordingStore.keptAudioURL(json: json, historyDirectory: historyDir))
  }

  // MARK: - deleteAudio

  func testDeleteAudioRemovesTheAudioAndKeepsEverythingElse() throws {
    let output = historyDir.appendingPathComponent("notes.summary.md")
    try "# owner's notes".write(to: output, atomically: true, encoding: .utf8)
    try seedRecord(id: "rec", audioBytes: 2048, clipBytes: 300, outputPath: output.path)
    let located = try XCTUnwrap(
      RecordingStore.locate(outputPath: output, historyDirectory: historyDir)
    )

    XCTAssertTrue(RecordingStore.deleteAudio(located, historyDirectory: historyDir))

    let assets = historyDir.appendingPathComponent("rec.assets", isDirectory: true)
    XCTAssertFalse(fileManager.fileExists(atPath: assets.appendingPathComponent("recording.caf").path))
    // Everything the containment rule promises survives.
    XCTAssertTrue(fileManager.fileExists(atPath: assets.appendingPathComponent("Speaker 1.pcm").path))
    XCTAssertTrue(fileManager.fileExists(atPath: located.recordURL.path))
    XCTAssertTrue(fileManager.fileExists(atPath: output.path))
    XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "# owner's notes")

    let json = try loadJSON("rec")
    XCTAssertEqual(json["transcriptText"] as? String, "the transcript survives")
    XCTAssertNotNil(json["summary"])
    XCTAssertNotNil(json["speakerClips"])
    XCTAssertEqual(json["status"] as? String, "done")
    // And the record now reads "audio not kept".
    XCTAssertNil(json["audioPath"])
    XCTAssertNil(json["audioBytes"])
  }

  func testDeleteAudioIsANoOpWhenTheRecordKeepsNone() throws {
    let ownersFile = historyDir.appendingPathComponent("owners-own.m4a")
    try Data(count: 1234).write(to: ownersFile)
    let output = historyDir.appendingPathComponent("legacy.summary.md")
    try "# legacy".write(to: output, atomically: true, encoding: .utf8)
    try seedRecord(id: "legacy", audioBytes: nil, outputPath: output.path,
                   sourcePath: ownersFile.path)
    let located = try XCTUnwrap(
      RecordingStore.locate(outputPath: output, historyDirectory: historyDir)
    )

    XCTAssertTrue(RecordingStore.deleteAudio(located, historyDirectory: historyDir))

    // The owner's own file is untouched, and so is the record.
    XCTAssertTrue(fileManager.fileExists(atPath: ownersFile.path))
    XCTAssertTrue(fileManager.fileExists(atPath: located.recordURL.path))
  }

  func testDeleteAudioNeverCascadesUpwardToTheRecord() throws {
    let output = historyDir.appendingPathComponent("notes.summary.md")
    try "# n".write(to: output, atomically: true, encoding: .utf8)
    try seedRecord(id: "rec", audioBytes: 1024, outputPath: output.path)
    let located = try XCTUnwrap(
      RecordingStore.locate(outputPath: output, historyDirectory: historyDir)
    )

    RecordingStore.deleteAudio(located, historyDirectory: historyDir)

    // The row is still there to be found — the drawer must not lose it.
    XCTAssertNotNil(RecordingStore.locate(outputPath: output, historyDirectory: historyDir))
  }

  // MARK: - deleteRecord

  func testDeleteRecordLeavesNoAssetsFolderAndKeepsTheExportedMarkdown() throws {
    let output = historyDir.appendingPathComponent("notes.summary.md")
    try "# owner's notes".write(to: output, atomically: true, encoding: .utf8)
    try seedRecord(id: "rec", audioBytes: 2048, clipBytes: 200, outputPath: output.path)
    let located = try XCTUnwrap(
      RecordingStore.locate(outputPath: output, historyDirectory: historyDir)
    )

    XCTAssertTrue(RecordingStore.deleteRecord(located))

    XCTAssertFalse(fileManager.fileExists(atPath: located.recordURL.path))
    XCTAssertFalse(fileManager.fileExists(atPath: located.assetsURL.path))
    // The .md lives outside ~/.nota and is NEVER deleted by Nota.
    XCTAssertTrue(fileManager.fileExists(atPath: output.path))
    XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "# owner's notes")
  }

  func testDeleteRecordTouchesOnlyTheNamedRecord() throws {
    let outputA = historyDir.appendingPathComponent("a.summary.md")
    let outputB = historyDir.appendingPathComponent("b.summary.md")
    try "# a".write(to: outputA, atomically: true, encoding: .utf8)
    try "# b".write(to: outputB, atomically: true, encoding: .utf8)
    try seedRecord(id: "a", outputPath: outputA.path)
    try seedRecord(id: "b", outputPath: outputB.path)
    let located = try XCTUnwrap(
      RecordingStore.locate(outputPath: outputA, historyDirectory: historyDir)
    )

    RecordingStore.deleteRecord(located)

    XCTAssertNotNil(RecordingStore.locate(outputPath: outputB, historyDirectory: historyDir))
    XCTAssertTrue(
      fileManager.fileExists(
        atPath: historyDir.appendingPathComponent("b.assets").path
      )
    )
  }

  // MARK: - Discard

  func testDiscardDeletesTheWholeRecordIncludingItsAudio() throws {
    // Scope item 2: Discard is an explicit verb, so it takes everything —
    // unlike a session that FAILED, which settles and keeps its audio.
    let started = try LiveSessionPersistence.beginRecording(historyDirectory: historyDir)
    try Data(count: 4096).write(to: started.audioURL)

    XCTAssertTrue(RecordingStore.discardLiveRecording(started))

    XCTAssertFalse(fileManager.fileExists(atPath: started.recordURL.path))
    XCTAssertFalse(fileManager.fileExists(atPath: started.assetsDirectory.path))
    XCTAssertFalse(fileManager.fileExists(atPath: started.audioURL.path))
  }

  func testAFailedSessionStillKeepsItsAudio() throws {
    // The other half of the same rule, pinned so a later change to discard
    // cannot quietly take the failure path with it.
    let started = try LiveSessionPersistence.beginRecording(historyDirectory: historyDir)
    try Data(count: 4096).write(to: started.audioURL)

    XCTAssertTrue(
      LiveSessionPersistence.settleAsFailed(
        id: started.historyID,
        historyDirectory: historyDir
      )
    )

    XCTAssertTrue(fileManager.fileExists(atPath: started.audioURL.path))
    XCTAssertTrue(fileManager.fileExists(atPath: started.recordURL.path))
  }

  // MARK: - Formatting + copy

  func testByteFormattingMatchesTheCLIsSpelling() {
    XCTAssertEqual(StorageFormat.bytes(512), "512 B")
    XCTAssertEqual(StorageFormat.bytes(1536), "1.5 KB")
    XCTAssertEqual(StorageFormat.bytes(5 * 1024 * 1024), "5.0 MB")
  }

  func testAudioColumnSaysNotKeptRatherThanZero() {
    // "0 B" would read as a recording that exists and is empty.
    XCTAssertEqual(StorageFormat.audio(nil), "audio not kept")
    XCTAssertEqual(StorageFormat.audio(0), "0 B")
  }

  func testAudioConfirmationNamesBytesWhatStaysAndThatItIsFinal() {
    let message = RecordingDeletionCopy.audioMessage(bytes: 2048, hasTranscript: true)

    XCTAssertTrue(message.contains("2.0 KB"))
    XCTAssertTrue(message.contains("transcript"))
    XCTAssertTrue(message.contains("cannot be undone"))
  }

  func testAudioConfirmationSaysSoWhenThereIsNoAudio() {
    let message = RecordingDeletionCopy.audioMessage(bytes: nil, hasTranscript: true)

    XCTAssertTrue(message.contains("keeps no audio"))
    XCTAssertFalse(message.contains("0 B"))
  }

  func testRecordConfirmationPromisesTheExportedFileSurvives() {
    let message = RecordingDeletionCopy.recordMessage(bytes: 3072, keepsMarkdown: true)

    XCTAssertTrue(message.contains("3.0 KB"))
    XCTAssertTrue(message.contains("transcript"))
    XCTAssertTrue(message.contains(".md"))
    XCTAssertTrue(message.contains("not deleted"))
    XCTAssertTrue(message.contains("cannot be undone"))
  }

  // MARK: - The CLI's summary decodes

  func testStorageSummaryDecodesWhatTheCLIEmits() throws {
    // Field-for-field the shape `nota history storage --json` writes. The app
    // decodes this rather than recomputing it, so the sheet and the terminal
    // cannot disagree about the figure.
    let json = """
    {
      "records": [
        {"id":"a","createdAt":"2026-01-01T00:00:00.000Z","sourceName":"recording.caf",
         "audioBytes":null,"assetsBytes":0,"recordBytes":400,"totalBytes":400},
        {"id":"b","createdAt":"2026-02-01T00:00:00.000Z","sourceName":"recording.caf",
         "audioBytes":2048,"assetsBytes":2048,"recordBytes":400,"totalBytes":2448}
      ],
      "count": 2,
      "totalBytes": 2848,
      "audioBytes": 2048,
      "oldestCreatedAt": "2026-01-01T00:00:00.000Z",
      "thisMonthBytes": 2448
    }
    """
    let summary = try JSONDecoder().decode(
      StoredStorageSummary.self,
      from: XCTUnwrap(json.data(using: .utf8))
    )

    XCTAssertEqual(summary.count, 2)
    XCTAssertEqual(summary.totalBytes, 2848)
    XCTAssertNil(summary.records[0].audioBytes)
    XCTAssertEqual(summary.records[1].audioBytes, 2048)
    XCTAssertEqual(summary.oldestCreatedAt, "2026-01-01T00:00:00.000Z")
  }
}
