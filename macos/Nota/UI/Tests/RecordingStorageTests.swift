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
    // A test that made a folder unremovable has to hand back the permission,
    // or the temp directory outlives the run.
    if let contents = try? fileManager.contentsOfDirectory(
      at: historyDir,
      includingPropertiesForKeys: nil
    ) {
      for url in contents where url.hasDirectoryPath {
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
      }
    }
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
    // And the app says so where an owner actually reads it — the confirmation.
    // (`StorageFormat.audio` is gone: the app has no per-record audio column,
    // so nothing but a test ever called it. The CLI keeps the column.)
    XCTAssertTrue(
      RecordingDeletionCopy
        .audioMessage(bytes: located.audioBytes, hasTranscript: true)
        .contains("keeps no audio")
    )
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

  func testAnAssetsFolderThatCannotBeRemovedKeepsTheRecordAndFails() throws {
    // The forbidden partial delete: assets left behind with no record naming
    // them is invisible to `nota history storage` (which walks records) and
    // untargetable by `nota history delete`, so the bytes can never be found
    // again. Assets first, checked — and the JSON stays put when it fails.
    let output = historyDir.appendingPathComponent("stuck.summary.md")
    try "# n".write(to: output, atomically: true, encoding: .utf8)
    try seedRecord(id: "stuck", audioBytes: 1024, outputPath: output.path)
    let located = try XCTUnwrap(
      RecordingStore.locate(outputPath: output, historyDirectory: historyDir)
    )
    // r-x on the folder: its child cannot be unlinked, so the recursive remove
    // fails — while the history dir itself stays writable, so removing the
    // record JSON *would* have succeeded.
    try fileManager.setAttributes(
      [.posixPermissions: 0o500],
      ofItemAtPath: located.assetsURL.path
    )

    XCTAssertFalse(RecordingStore.deleteRecord(located))

    XCTAssertTrue(fileManager.fileExists(atPath: located.recordURL.path))
    XCTAssertTrue(fileManager.fileExists(atPath: located.assetsURL.path))
    // Still reachable: the row can be found and the verb tried again.
    XCTAssertNotNil(RecordingStore.locate(outputPath: output, historyDirectory: historyDir))

    try fileManager.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: located.assetsURL.path
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

  // MARK: - Discard's effect on ownership (XIA-430 rule 3)

  @MainActor
  func testASuccessfulDiscardReleasesTheRecord() throws {
    let owner = LiveSessionOwner(historyDirectory: { self.historyDir })
    let started = try XCTUnwrap(startedRecord(owner))

    XCTAssertEqual(owner.discard(started), .deleted)

    XCTAssertFalse(owner.isOwning)
    XCTAssertFalse(fileManager.fileExists(atPath: started.recordURL.path))
  }

  @MainActor
  func testADiscardThatDidNotDeleteSettlesTheRecordInsteadOfAbandoningIt() throws {
    // Rule 3: nothing is abandoned in an in-flight status. Releasing on a
    // failed delete leaves a record on disk saying `recording` that nobody
    // owns — `settle` can never run for it, the state observer cannot rescue
    // it, and the next launch's sweep presents it as "Interrupted": a session
    // that never happened, with the audio the owner believed they discarded
    // still on disk.
    let owner = LiveSessionOwner(historyDirectory: { self.historyDir })
    let started = try XCTUnwrap(startedRecord(owner))
    try Data(count: 2048).write(to: started.audioURL)

    XCTAssertEqual(owner.discard(started, delete: { _ in false }), .keptAfterFailure)

    XCTAssertFalse(owner.isOwning)
    let json = try XCTUnwrap(
      LiveSessionPersistence.loadRecord(id: started.historyID, historyDirectory: historyDir)
    )
    // A terminal status, not an in-flight one — and the audio is kept.
    XCTAssertEqual(json["status"] as? String, "failed:recording")
    XCTAssertTrue(fileManager.fileExists(atPath: started.audioURL.path))
  }

  @MainActor
  private func startedRecord(
    _ owner: LiveSessionOwner
  ) -> LiveSessionPersistence.StartedRecord? {
    guard case .started(let started) = owner.start(
      kind: .meeting,
      diarize: false,
      identify: false,
      sessionIsLive: false
    ) else {
      return nil
    }
    return started
  }

  // MARK: - Discard's confirmation

  func testDiscardConfirmationNamesTheLengthTheSizeAndTheWayOut() {
    // The one verb that destroys the most used to confirm nothing.
    let message = RecordingDeletionCopy.discardMessage(
      seconds: 5_280,
      bytes: 88 * 1024 * 1024,
      hasTranscript: true
    )

    XCTAssertTrue(message.contains("88 minutes"))
    XCTAssertTrue(message.contains("88.0 MB"))
    XCTAssertTrue(message.contains("cannot be re-recorded"))
    XCTAssertTrue(message.contains("Save Transcript"))
    XCTAssertTrue(message.contains("cannot be undone"))
  }

  func testDiscardConfirmationOffersTryAgainWhenNothingWasHeard() {
    let message = RecordingDeletionCopy.discardMessage(
      seconds: 12,
      bytes: nil,
      hasTranscript: false
    )

    XCTAssertTrue(message.contains("12 seconds"))
    XCTAssertTrue(message.contains("Try Again"))
    // No size is invented when the file cannot be read.
    XCTAssertFalse(message.contains("("))
  }

  // MARK: - Formatting + copy

  func testByteFormattingMatchesTheCLIsSpelling() {
    XCTAssertEqual(StorageFormat.bytes(512), "512 B")
    XCTAssertEqual(StorageFormat.bytes(1536), "1.5 KB")
    XCTAssertEqual(StorageFormat.bytes(5 * 1024 * 1024), "5.0 MB")
  }

  func testAudioConfirmationNamesTheVoiceClipsThatStay() {
    // The clips are raw audio of the same people and this verb keeps them.
    // "only the recording goes" is true and misleads exactly the owner who is
    // deleting audio because they do not want audio kept.
    let message = RecordingDeletionCopy.audioMessage(
      bytes: 2048,
      hasTranscript: true,
      speakerClipCount: 2
    )

    XCTAssertTrue(message.contains("2 per-speaker voice clips"))
    XCTAssertTrue(message.contains("Delete record…"))
    // And nothing is claimed when there are none.
    XCTAssertFalse(
      RecordingDeletionCopy
        .audioMessage(bytes: 2048, hasTranscript: true, speakerClipCount: 0)
        .contains("voice clip")
    )
  }

  func testALocatedRecordCountsItsVoiceClips() throws {
    let output = historyDir.appendingPathComponent("notes.summary.md")
    try "# n".write(to: output, atomically: true, encoding: .utf8)
    try seedRecord(id: "rec", audioBytes: 1024, clipBytes: 200, outputPath: output.path)

    let located = try XCTUnwrap(
      RecordingStore.locate(outputPath: output, historyDirectory: historyDir)
    )

    XCTAssertEqual(located.speakerClipCount, 1)
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
    // NOT a hand-written shape. `Fixtures/storage-summary.json` is the literal
    // output of `nota history storage --json`, produced by
    // `scripts/storage-summary-fixture.ts` and rebuilt-and-compared by a
    // vitest, so neither side can move without the other going red. The
    // hand-copy this replaced claimed to be "field-for-field" what the CLI
    // writes and was not — it was missing the `status` key every real row
    // carries, which is exactly the drift a fixture written by hand invites.
    let summary = try JSONDecoder().decode(
      StoredStorageSummary.self,
      from: try Data(contentsOf: Self.fixtureURL)
    )

    XCTAssertEqual(summary.count, 2)
    XCTAssertEqual(summary.oldestCreatedAt, "2026-01-05T10:00:00.000Z")
    // A legacy record: no audio of ours, and the row still decodes.
    XCTAssertEqual(summary.records[0].id, "legacy-no-audio")
    XCTAssertNil(summary.records[0].audioBytes)
    XCTAssertEqual(summary.records[0].status, "done")
    // A record-first one, with a voice clip that `delete-audio` would keep.
    XCTAssertEqual(summary.records[1].audioBytes, 2048)
    XCTAssertEqual(summary.records[1].speakerClipCount, 1)
    XCTAssertEqual(summary.records[1].speakerClipBytes, 512)
    // Bytes no record names are counted, named, and part of the total.
    XCTAssertEqual(summary.orphanBytes, 4096)
    XCTAssertEqual(summary.orphans?.first?.id, "orphaned")
    XCTAssertEqual(summary.orphans?.first?.reason, "no-record")
    XCTAssertEqual(
      summary.totalBytes,
      summary.records.reduce(0) { $0 + $1.totalBytes } + 4096
    )
  }

  func testStorageSummaryStillDecodesASummaryWithNoOrphanFields() throws {
    // Tolerance per field: a payload written by a Nota that predates orphan
    // accounting must not blank the whole sheet.
    let json = """
    {"records":[],"count":0,"totalBytes":0,"audioBytes":0,
     "oldestCreatedAt":null,"thisMonthBytes":0}
    """

    let summary = try JSONDecoder().decode(
      StoredStorageSummary.self,
      from: XCTUnwrap(json.data(using: .utf8))
    )

    XCTAssertNil(summary.orphans)
    XCTAssertNil(summary.orphanBytes)
  }

  // MARK: - The record survives its audio (XIA-436 follow-up)

  func testARecordTheAppDeletedTheAudioOfIsStillFound() throws {
    // The blocker. `HistoryRecordInfo.find` gated its whole result on the
    // audio resolving, and `delete-audio` clears both names for the file it
    // unlinked — so the app lost the record entirely: blank summary slot and
    // tag chips, every speaker chip stuck amber, enrollment a no-op. Which is
    // the one thing this verb may not break, since its own confirmation
    // promises the speaker clips are kept SO THAT enrollment still works.
    let output = historyDir.appendingPathComponent("notes.summary.md")
    try "# notes".write(to: output, atomically: true, encoding: .utf8)
    let assets = historyDir.appendingPathComponent("rec.assets", isDirectory: true)
    try seedRecord(
      id: "rec",
      audioBytes: 2048,
      clipBytes: 300,
      outputPath: output.path,
      sourcePath: assets.appendingPathComponent("recording.caf").path
    )
    let located = try XCTUnwrap(
      RecordingStore.locate(outputPath: output, historyDirectory: historyDir)
    )
    XCTAssertTrue(RecordingStore.deleteAudio(located, historyDirectory: historyDir))

    let info = try XCTUnwrap(
      HistoryRecordInfo.find(outputPath: output.path, historyDir: historyDir)
    )

    XCTAssertEqual(info.historyID, "rec")
    // The audio really is gone — that is the verb working, not a lookup
    // failure — and the record is still there to enroll from.
    XCTAssertNil(info.audioURL)
    XCTAssertTrue(fileManager.fileExists(atPath: assets.appendingPathComponent("Speaker 1.pcm").path))
  }

  func testARecordTheCLIDeletedTheAudioOfIsStillFound() throws {
    // The same record shape `nota history delete-audio` leaves: no
    // `audioPath`, and a `sourcePath` blanked because it named the file that
    // went. The app must read the CLI's output the same way it reads its own.
    let output = historyDir.appendingPathComponent("cli.summary.md")
    try "# cli".write(to: output, atomically: true, encoding: .utf8)
    try seedRecord(id: "cli", audioBytes: nil, outputPath: output.path, sourcePath: "")

    let info = try XCTUnwrap(
      HistoryRecordInfo.find(outputPath: output.path, historyDir: historyDir)
    )

    XCTAssertEqual(info.historyID, "cli")
    XCTAssertNil(info.audioURL)
  }

  func testPinningStillLandsOnARecordThatKeepsNoAudio() throws {
    // `setPinned` goes through `find`, so the pin button was one of the
    // silent no-ops. Nothing about a pin is about audio.
    let output = historyDir.appendingPathComponent("pin.summary.md")
    try "# pin".write(to: output, atomically: true, encoding: .utf8)
    try seedRecord(id: "pin", audioBytes: nil, outputPath: output.path, sourcePath: "")

    HistoryRecordInfo.setPinned(true, outputPath: output.path, historyDir: historyDir)

    XCTAssertEqual(try loadJSON("pin")["pinned"] as? Bool, true)
  }

  func testFindStillReturnsNilForAPathNoRecordNames() throws {
    // The guard that was removed was the wrong one, not the only one: an
    // imported `.md` still has no record, and `find` still says so.
    try seedRecord(id: "rec", outputPath: "/tmp/somewhere-else.md")

    XCTAssertNil(
      HistoryRecordInfo.find(outputPath: "/tmp/unrelated.md", historyDir: historyDir)
    )
  }

  // MARK: - The app and the CLI leave the same record behind

  func testDeleteAudioBlanksTheSourcePathThatNamedTheDeletedFile() throws {
    // `deleteRecordAudio` in src/pipeline/storage.ts has always done this and
    // the app did not, so the same verb through the two front doors left
    // records that differed by one field — under a header claiming they mirror
    // each other exactly. A `sourcePath` naming a file that is gone is worse
    // than none: every reader that falls back to it resolves a dead path.
    let output = historyDir.appendingPathComponent("notes.summary.md")
    try "# n".write(to: output, atomically: true, encoding: .utf8)
    let assets = historyDir.appendingPathComponent("rec.assets", isDirectory: true)
    try seedRecord(
      id: "rec",
      audioBytes: 2048,
      outputPath: output.path,
      sourcePath: assets.appendingPathComponent("recording.caf").path
    )
    let located = try XCTUnwrap(
      RecordingStore.locate(outputPath: output, historyDirectory: historyDir)
    )

    XCTAssertTrue(RecordingStore.deleteAudio(located, historyDirectory: historyDir))

    let json = try loadJSON("rec")
    XCTAssertEqual(json["sourcePath"] as? String, "")
    // Blanked, not removed: the TS record type requires the key.
    XCTAssertNotNil(json["sourcePath"])
    XCTAssertNil(
      LiveSessionPersistence.resolvedAudioURL(record: json, historyDirectory: historyDir)
    )
  }

  func testDeleteAudioNeverBlanksALegacySourcePath() throws {
    // On a legacy record `sourcePath` is the owner's OWN file outside the
    // store. Nothing was unlinked, so nothing may be rewritten — the record
    // goes on naming the audio it always named.
    let ownersFile = historyDir.appendingPathComponent("owners-own.m4a")
    try Data(count: 4096).write(to: ownersFile)
    let output = historyDir.appendingPathComponent("legacy.summary.md")
    try "# legacy".write(to: output, atomically: true, encoding: .utf8)
    try seedRecord(id: "legacy", audioBytes: nil, outputPath: output.path,
                   sourcePath: ownersFile.path)
    let located = try XCTUnwrap(
      RecordingStore.locate(outputPath: output, historyDirectory: historyDir)
    )

    XCTAssertTrue(RecordingStore.deleteAudio(located, historyDirectory: historyDir))

    XCTAssertTrue(fileManager.fileExists(atPath: ownersFile.path))
    XCTAssertEqual(try loadJSON("legacy")["sourcePath"] as? String, ownersFile.path)
  }

  /// The committed CLI output, found relative to this source file. Deliberately
  /// not a bundle resource: the test target copies no resources, and a fixture
  /// that silently resolved to nil would be a test that cannot fail.
  private static var fixtureURL: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/storage-summary.json")
  }
}
