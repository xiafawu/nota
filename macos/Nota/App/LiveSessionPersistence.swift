import Foundation
import os

/// Reasons a live session's result cannot be sealed as a finished record.
/// Only the semantic cases are distinct; every other failure is an underlying
/// file-system error and propagates as-is.
///
/// None of these throws anything away. Since XIA-430 the record and its audio
/// exist from sample zero, so a session that cannot be sealed leaves a
/// `failed(stage:)` record with the audio still in it — the audio is the one
/// artifact that cannot be regenerated, and these are exactly the failures
/// where somebody wants it.
enum LiveSessionPersistenceError: LocalizedError, Equatable {
  /// Nothing was recognized (whitespace-only transcript).
  case emptyTranscript
  /// The session produced text but no audio file was ever created.
  case missingAudio
  /// A write the seal depends on did not land — the record was deleted under
  /// us, or the disk filled up right after a long recording. It is its own
  /// case because the alternative is the one thing a seal may never do:
  /// return a `SavedSession` for content that is not on disk, leaving a
  /// record that says Transcribed, has no `outputPath`, and hands an empty
  /// transcript to whoever summarizes it next.
  case recordUnwritable

  var errorDescription: String? {
    switch self {
    case .emptyTranscript:
      return "No speech was captured"
    case .missingAudio:
      return "Recording failed"
    case .recordUnwritable:
      return "Could not save this session's record"
    }
  }

  // There is deliberately no `stage` on this error any more. An error that
  // names the stage it failed in is a call site deciding what the record's
  // status may become, and it is wrong exactly when it matters: a caller that
  // names the wrong stage writes NOTHING, because `canAdvance` refuses it, and
  // the record is left claiming a live stage forever. `settleAsFailed` reads
  // the stage off the record instead.
}

/// The record-first lifecycle of a live dictation/transcription session
/// (XIA-430).
///
/// The record is created at **sample zero** — `beginRecording` writes
/// `~/.nota/history/<id>.json` with `status: recording` and makes the
/// `<id>.assets/` folder the audio is recorded straight into — and every later
/// step edits that same record in place: `sealTranscript` fills in the
/// transcript, the markdown and the duration, `updateStatus` walks the
/// lifecycle, and `resolveInterrupted` cleans up after a process that went
/// away. There is no build-the-record-at-the-end path left, which is why there
/// is no move-the-audio-afterwards step either: it was already written where it
/// belongs.
///
/// **Nothing here deletes audio.** Not a cancel, not an empty transcript, not
/// a failed summary. Audio is the one artifact that cannot be regenerated;
/// deleting it is an explicit user verb, not a failure path (owner's standing
/// rule). That is still true of every function in this file — and it is now a
/// claim about *this file* rather than about the app: XIA-436 added the verbs,
/// and they live in `RecordingStorage.swift`. The failure-path half is
/// unchanged and pinned by test (`testAFailedSessionStillKeepsItsAudio`);
/// a Discard press deletes, because nobody chose a failure and somebody did
/// choose Discard.
///
/// The record schema stays the one the CLI produces (`src/pipeline/history.ts`),
/// plus `audioPath` / `audioBytes` / `interrupted`. `audioPath` is relative to
/// the record's own assets folder so the whole store can be relocated without
/// rewriting a single record (XIA-428).
///
/// Pure file logic — injectable directories keep it testable without touching
/// the real `~/.nota` or `~/Documents/Nota`. It deliberately does NOT re-run
/// the CLI transcription pipeline: the transcript already exists from the
/// realtime stream.
enum LiveSessionPersistence {
  /// The audio file inside a record's assets folder. One name for every
  /// record: `audioPath` is relative, so the name is the whole value.
  static let audioFileName = "recording.caf"

  /// Every refused or failed write says so here. The record store is the one
  /// place a live session's work becomes durable, so a write that did not land
  /// may never be silent even when its caller has nowhere to show it.
  static let logger = Logger(subsystem: "com.xiafawu.nota", category: "history.record")

  /// A record that exists on disk with `status: recording`, before a single
  /// audio buffer has been written.
  struct StartedRecord: Equatable {
    let historyID: String
    let recordURL: URL
    let assetsDirectory: URL
    /// Where the session must write its audio: `<assets>/recording.caf`.
    let audioURL: URL
    let createdAt: Date
    let capturedAt: Date
  }

  struct SavedSession {
    let historyID: String
    let audioURL: URL
    let outputURL: URL
    let recordURL: URL
    let markdown: String
  }

  // MARK: - History id (mirror of src/pipeline/history.ts makeHistoryId)

  /// `"2026-07-17T00:41:04.089Z"` → `"20260717-004104Z-<8 hex>"`.
  /// The CLI derives the id from the ISO timestamp the same way, so ids stay
  /// format-compatible with records written by the pipeline.
  static func makeHistoryID(createdAtISO8601: String) -> String {
    var stamp = createdAtISO8601
      .replacingOccurrences(of: "-", with: "")
      .replacingOccurrences(of: ":", with: "")
    stamp = stamp.replacingOccurrences(
      of: #"\.\d{3}Z$"#,
      with: "Z",
      options: .regularExpression
    )
    stamp = stamp.replacingOccurrences(of: "T", with: "-")
    // UUID hex is uppercase; the CLI's randomUUID().slice(0, 8) is lowercase.
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
    return "\(stamp)-\(suffix)"
  }

  // MARK: - Paths

  /// A record's own asset folder: `<historyDir>/<id>.assets`. Same convention
  /// the CLI already uses for per-speaker clips (`speakerClipPath`).
  static func assetsDirectory(for id: String, historyDirectory: URL) -> URL {
    historyDirectory.appendingPathComponent("\(id).assets", isDirectory: true)
  }

  /// Resolve a record's audio. Prefers the RELATIVE `audioPath` — which is
  /// what survives `~/.nota` being moved wholesale — and falls back to the
  /// absolute `sourcePath` for records written before record-first recording.
  /// Mirrors `recordAudioPath` in src/pipeline/history.ts.
  static func resolvedAudioURL(
    record: [String: Any],
    historyDirectory: URL
  ) -> URL? {
    if let id = record["id"] as? String,
       let relative = record["audioPath"] as? String,
       !relative.isEmpty {
      return assetsDirectory(for: id, historyDirectory: historyDirectory)
        .appendingPathComponent(relative)
    }
    if let source = record["sourcePath"] as? String, !source.isEmpty {
      return URL(fileURLWithPath: source)
    }
    return nil
  }

  // MARK: - Sample zero

  /// Create the record BEFORE the microphone opens: id, timestamps, kind,
  /// `status: recording`, and the `<id>.assets/` folder the audio is written
  /// straight into. Returns where the session must record.
  ///
  /// This is the inversion XIA-430 is about. Building the record at the end
  /// meant that every failure before the end — a crash, a dead socket, a
  /// process killed mid-sentence — left the audio somewhere temporary with
  /// nothing pointing at it. Now the pointer exists first and the audio is
  /// written inside it.
  static func beginRecording(
    kind: HistoryKind = .meeting,
    diarize: Bool = false,
    identify: Bool = false,
    createdAt: Date = Date(),
    capturedAt: Date = Date(),
    historyDirectory: URL
  ) throws -> StartedRecord {
    let fileManager = FileManager.default
    let id = makeHistoryID(createdAtISO8601: iso8601(createdAt))
    let assets = assetsDirectory(for: id, historyDirectory: historyDirectory)
    try fileManager.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: assets, withIntermediateDirectories: true)

    let audioURL = assets.appendingPathComponent(audioFileName)
    let record: [String: Any] = [
      "id": id,
      "createdAt": iso8601(createdAt),
      "updatedAt": iso8601(createdAt),
      "capturedAt": iso8601(capturedAt),
      // Absolute, for every consumer that still reads sourcePath. `audioPath`
      // is the authority; this is the convenience copy and may go stale if the
      // store moves, which is exactly why the relative one exists.
      "sourcePath": audioURL.path,
      "sourceName": audioFileName,
      "audioPath": audioFileName,
      // True at sample zero, and corrected at every exit: `sealTranscript`
      // stamps the final size, and `settleAsFailed` / the launch sweep stamp
      // whatever was captured before things went wrong. The field is never
      // absent, so no consumer has to distinguish "zero" from "not written".
      "audioBytes": 0,
      "provider": "assemblyai",
      "kind": kind.rawValue,
      "options": [
        "diarize": diarize,
        "identify": identify,
        // Omitting speech_model selects AssemblyAI's default = Universal-3.5
        // Pro Streaming; recorded here for the usage/dashboard surfaces.
        "model": "universal-3.5-pro-streaming"
      ],
      "durationMinutes": 0,
      "transcriptText": "",
      "segments": [],
      "status": HistoryStatus.recording.rawValue
    ]
    let recordURL = historyDirectory.appendingPathComponent("\(id).json")
    let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted])
    try data.write(to: recordURL, options: .atomic)

    return StartedRecord(
      historyID: id,
      recordURL: recordURL,
      assetsDirectory: assets,
      audioURL: audioURL,
      createdAt: createdAt,
      capturedAt: capturedAt
    )
  }

  // MARK: - Editing a record in place

  /// Read one record's JSON, or nil when it is missing or unreadable.
  static func loadRecord(id: String, historyDirectory: URL) -> [String: Any]? {
    let url = historyDirectory.appendingPathComponent("\(id).json")
    guard
      let data = try? Data(contentsOf: url),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    return json
  }

  /// Apply `changes` to a record and rewrite it atomically. Every key not
  /// named survives — this is a merge, never a rebuild, because the CLI writes
  /// fields (usage, suggestions, speakerClips) this app does not model.
  ///
  /// Returns whether the write landed, and it is deliberately NOT
  /// `@discardableResult`: a false here is a record that does not say what
  /// the caller believes it says, and every one of the failures it reports
  /// (record deleted, disk full, encoder refusal) is one a caller must either
  /// surface or log. Ignoring it is how a full disk became a "Transcribed"
  /// record with no transcript in it.
  static func mutateRecord(
    id: String,
    historyDirectory: URL,
    _ changes: [String: Any]
  ) -> Bool {
    guard var record = loadRecord(id: id, historyDirectory: historyDirectory) else {
      logger.error("record \(id, privacy: .public) could not be read for update")
      return false
    }
    for (key, value) in changes { record[key] = value }
    record["updatedAt"] = iso8601(Date())
    guard
      let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted])
    else {
      logger.error("record \(id, privacy: .public) could not be encoded")
      return false
    }
    let url = historyDirectory.appendingPathComponent("\(id).json")
    do {
      try data.write(to: url, options: .atomic)
      return true
    } catch {
      logger.error(
        "record \(id, privacy: .public) write failed: \(error.localizedDescription, privacy: .public)"
      )
      return false
    }
  }

  /// Move a record to `status`. Refuses an illegal transition rather than
  /// writing it: the machine in `HistoryStatus` is the whole point of typing
  /// this field, and a record that jumped from `recording` to `done` would
  /// describe a session nobody ran.
  ///
  /// Returns whether the record now says `status`. Not `@discardableResult`
  /// for the reason `mutateRecord` is not: a refused transition writes
  /// NOTHING, so a discarded false is a record left claiming the stage it was
  /// already in. Callers that cannot act on it must at least say so.
  static func updateStatus(
    id: String,
    to status: HistoryStatus,
    interrupted: Bool = false,
    historyDirectory: URL
  ) -> Bool {
    guard let record = loadRecord(id: id, historyDirectory: historyDirectory) else {
      logger.error("record \(id, privacy: .public) could not be read for a status change")
      return false
    }
    let current = HistoryStatus.normalized(fromRecord: record)
    guard current.canAdvance(to: status) else {
      logger.error(
        """
        record \(id, privacy: .public) refused \
        \(current.rawValue, privacy: .public) → \(status.rawValue, privacy: .public)
        """
      )
      return false
    }
    var changes: [String: Any] = ["status": status.rawValue]
    if interrupted { changes["interrupted"] = true }
    // **A record that has left `recording` is not paused** (XIA-447). The flag
    // is written at press time and only Resume clears it, so without this a
    // session stopped *from* a pause seals as `{"status": "done", …,
    // "paused": true}` — forever, on the surface `nota history show` calls
    // scriptable. It is masked today only because both `describeHistoryStatus`
    // and `presentation` gate the word on `recording`; a record that is wrong
    // while its display happens to hide it is exactly the shape the
    // flag-not-a-status design was chosen to avoid. Cleared here rather than at
    // each call site because *every* way out of a live stage — the seal,
    // `settleAsFailed`, the launch sweep — comes through this one function.
    if status != .recording { changes["paused"] = false }
    return mutateRecord(id: id, historyDirectory: historyDirectory, changes)
  }

  /// Take a record out of the in-flight zone by failing it in the stage it is
  /// actually IN.
  ///
  /// The stage is read off the record instead of being named by the caller,
  /// and that is the whole point: `canAdvance` refuses a failure in any other
  /// stage, `updateStatus` then writes nothing, and a discarded false leaves
  /// the record claiming a live stage forever. That is exactly what the stop
  /// path used to do — it asked for `failed(stage: .transcribing)` on a record
  /// still at `recording`, which is illegal, so a failed live session stayed
  /// `recording` until the next launch swept it up as "Interrupted", a
  /// different fact from "the socket dropped".
  ///
  /// A record already at rest (`transcribed`) or already terminal is left
  /// exactly as it is and reported as settled: nothing is owed there.
  /// Returns whether the record is now out of the in-flight zone.
  static func settleAsFailed(id: String, historyDirectory: URL) -> Bool {
    guard let record = loadRecord(id: id, historyDirectory: historyDirectory) else {
      logger.error("record \(id, privacy: .public) could not be read to settle it")
      return false
    }
    let current = HistoryStatus.normalized(fromRecord: record)
    guard let resolution = current.interruptedResolution else { return true }
    stampAudioBytes(record: record, historyDirectory: historyDirectory)
    return updateStatus(id: id, to: resolution, historyDirectory: historyDirectory)
  }

  /// Write the audio's real size onto a record that is leaving the in-flight
  /// zone without a seal.
  ///
  /// `beginRecording` writes `audioBytes: 0`, which is true at sample zero and
  /// a lie from the first buffer onward — only `sealTranscript` used to
  /// correct it, so every interrupted record described a playable recording as
  /// empty. Nothing was misled by it yet, and that is exactly why it is
  /// stamped here rather than left to the first consumer that starts trusting
  /// the field. Best effort: a record whose audio cannot be measured keeps
  /// whatever it had, because the status change matters more than the size.
  private static func stampAudioBytes(record: [String: Any], historyDirectory: URL) {
    guard
      let id = record["id"] as? String,
      let audio = resolvedAudioURL(record: record, historyDirectory: historyDirectory),
      let attributes = try? FileManager.default.attributesOfItem(atPath: audio.path),
      let size = (attributes[.size] as? NSNumber)?.intValue
    else {
      return
    }
    if (record["audioBytes"] as? NSNumber)?.intValue == size { return }
    _ = mutateRecord(id: id, historyDirectory: historyDirectory, ["audioBytes": size])
  }

  // MARK: - Interrupted recovery

  /// Resolve every record left in a live stage by a process that is no longer
  /// there. Called once at launch: nothing else is running, so anything that
  /// still says `recording`/`transcribing`/`summarizing` was interrupted.
  /// Each becomes `failed(stage:)` with `interrupted: true`, which presents as
  /// "Interrupted" — and keeps its audio, which is the whole reason to notice.
  /// Returns the ids it resolved.
  @discardableResult
  static func resolveInterruptedRecords(historyDirectory: URL) -> [String] {
    let fileManager = FileManager.default
    guard let entries = try? fileManager.contentsOfDirectory(
      at: historyDirectory,
      includingPropertiesForKeys: nil,
      options: []
    ) else {
      return []
    }

    var resolved: [String] = []
    for entry in entries where entry.pathExtension == "json" {
      guard
        let data = try? Data(contentsOf: entry),
        let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let id = record["id"] as? String
      else {
        continue
      }
      let status = HistoryStatus.normalized(fromRecord: record)
      guard let resolution = status.interruptedResolution else { continue }
      // An interrupted record's audio is playable, so it may not go on
      // reporting the zero bytes `beginRecording` wrote at sample zero.
      stampAudioBytes(record: record, historyDirectory: historyDirectory)
      if updateStatus(
        id: id,
        to: resolution,
        interrupted: true,
        historyDirectory: historyDirectory
      ) {
        resolved.append(id)
      }
    }
    return resolved.sorted()
  }

  // MARK: - Sealing a finished session

  /// Fill in the record the session has been recording into: the transcript,
  /// the segments, the duration, the audio's final size, and the `.summary.md`
  /// written next to the other outputs. The record moves to `transcribed`.
  ///
  /// Throws `LiveSessionPersistenceError` for the two semantic failures, and
  /// marks the record `failed(stage:)` on the way out so no caller can forget
  /// to. Nothing is deleted in either case — the audio the session captured is
  /// still in the record's assets folder, which is the point.
  static func sealTranscript(
    started: StartedRecord,
    result: LiveMeetingSession.LiveMeetingResult,
    displayName: String = "Live Meeting",
    title: String = "Live Meeting",
    outputDirectory: URL,
    historyDirectory: URL
  ) throws -> SavedSession {
    func fail(_ error: LiveSessionPersistenceError) -> LiveSessionPersistenceError {
      // The stage comes off the record, not off the error: a failure may only
      // be written in the stage the record is in, and the record has moved by
      // the time some of these are raised. `settleAsFailed` is the one that
      // knows, and its own false is already logged.
      _ = settleAsFailed(id: started.historyID, historyDirectory: historyDirectory)
      return error
    }

    let transcript = result.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
    let fileManager = FileManager.default

    // Order matters, and it is the state machine that dictates it: no audio is
    // a RECORDING failure, so it has to be judged while the record still says
    // `recording`. Finalizing the stream is the transcribing stage, and an
    // empty transcript is that stage failing.
    guard fileManager.fileExists(atPath: started.audioURL.path) else {
      throw fail(.missingAudio)
    }
    guard updateStatus(
      id: started.historyID,
      to: .transcribing,
      historyDirectory: historyDirectory
    ) else {
      throw fail(.recordUnwritable)
    }
    guard !transcript.isEmpty else { throw fail(.emptyTranscript) }

    try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    // Transcript markdown — same filename and header shape as the CLI
    // (src/pipeline/write.ts buildMarkdown, no-summary variant).
    let sealedAt = Date()
    let durationMinutes = Self.durationMinutes(for: result.duration)
    let baseName = sanitizedBaseName(URL(fileURLWithPath: displayName))
    let outputURL = outputDirectory.appendingPathComponent(
      "\(baseName)-\(notaTimestamp()).summary.md"
    )
    let markdown = Self.buildMarkdown(
      title: title,
      segments: result.segments,
      transcript: transcript,
      capturedAt: started.capturedAt,
      createdAt: sealedAt,
      durationMinutes: durationMinutes,
      sourceName: audioFileName
    )
    try markdown.write(to: outputURL, atomically: true, encoding: .utf8)

    let attributes = try? fileManager.attributesOfItem(atPath: started.audioURL.path)
    let audioBytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0

    // CONTENT FIRST, STATUS LAST — and both writes are checked.
    //
    // These are two atomic writes and a crash can land between them, so the
    // order decides what the launch sweep finds. Flipping the status first
    // leaves `transcribed`, which is neither in flight nor terminal: the sweep
    // will NEVER resolve it, and it reads as a finished transcript with no
    // transcript and no `outputPath` in it. Writing the content first leaves
    // `transcribing`, which the sweep does rescue. The worst case is a record
    // that says less than it holds, never one that says more.
    guard mutateRecord(id: started.historyID, historyDirectory: historyDirectory, [
      "durationMinutes": durationMinutes,
      // The session's real length, to the second (XIA-429). `durationMinutes`
      // is the CLI's schema field and rounds UP to whole minutes, which is the
      // right shape for a header line and the wrong one for a clock: the
      // receipt that rises at Stop draws the same glyph run the live timer
      // ended on, and re-rendering 18:42 as 19:00 would flicker the one number
      // on screen that did not change. Written *alongside*, never instead — the
      // CLI's field keeps its meaning, and a legacy record with no seconds
      // falls back to it.
      "durationSeconds": result.duration,
      "transcriptText": transcript,
      "segments": Self.segmentDictionaries(result.segments),
      "outputPath": outputURL.path,
      "audioBytes": audioBytes
    ]) else {
      throw fail(.recordUnwritable)
    }
    guard updateStatus(
      id: started.historyID,
      to: .transcribed,
      historyDirectory: historyDirectory
    ) else {
      throw fail(.recordUnwritable)
    }

    return SavedSession(
      historyID: started.historyID,
      audioURL: started.audioURL,
      outputURL: outputURL,
      recordURL: started.recordURL,
      markdown: markdown
    )
  }

  // MARK: - Markdown (mirror of src/pipeline/write.ts buildMarkdown)

  /// The `.summary.md` body: CLI header block (`# Title`, Captured/Transcribed/
  /// Duration/Source, no Tags line without a summary) followed by
  /// `## Full Transcript` with one `[MM:SS]`-prefixed line per segment.
  /// `parseSummaryMetadata` reads title + tags from the header above the first
  /// `## ` section, so this shape round-trips through HistoryEntry.make.
  static func buildMarkdown(
    title: String,
    segments: [LiveMeetingSession.LiveSegment],
    transcript: String,
    capturedAt: Date,
    createdAt: Date,
    durationMinutes: Int,
    sourceName: String
  ) -> String {
    let effectiveSegments = segments.isEmpty
      ? [LiveMeetingSession.LiveSegment(id: UUID(), text: transcript, endTime: 0)]
      : segments

    // CLI semantics: the timestamp on a line is the segment's START (the CLI
    // renders `formatTimestamp(seg.start)`). LiveSegment carries only an end
    // time, so each start is the previous segment's end.
    var previousEnd: TimeInterval = 0
    let transcriptLines = effectiveSegments
      .map { segment in
        let start = previousEnd
        previousEnd = segment.endTime
        return "\(Self.formatTimestamp(start)) \(segment.text)"
      }
      .joined(separator: "\n")

    return """
    # \(title)

    **Captured:** \(Self.dayDate(capturedAt))
    **Transcribed:** \(Self.dayDate(createdAt))
    **Duration:** \(durationMinutes) minutes
    **Source:** \(sourceName)

    ---

    ## Full Transcript

    \(transcriptLines)
    """
  }

  /// Round a session length up to whole minutes, floor at 1 (the CLI's
  /// `durationMinutes` is an Int and the schema has no sub-minute unit).
  static func durationMinutes(for duration: TimeInterval) -> Int {
    max(1, Int((duration / 60).rounded(.up)))
  }

  // MARK: - Moment markers (XIA-433)

  /// The record's `markers` array: `{ id, atSeconds, createdAt }`, oldest
  /// first, with `label` present only when there is one.
  ///
  /// **Oldest first, whatever order the caller holds them in.** The in-memory
  /// log is newest-first because the owner is looking for the moment they just
  /// flagged; the record is a document, and a document's moments run with the
  /// recording. Sorting here rather than asking the caller to is what makes
  /// that a property of the file rather than of whoever last wrote to it.
  ///
  /// A nil `label` is **omitted**, never stored as null: this dictionary goes
  /// through `JSONSerialization`, and the TypeScript side reads an absent key
  /// as `undefined` where a null would be a value it has to special-case.
  ///
  /// **A marker whose `at` is not finite is dropped, not carried.** The whole
  /// array is written on every press and `JSONSerialization` refuses a
  /// non-finite Double, so one infinity would not cost one bad marker — it
  /// would fail the write for the rest of the session, taking every moment
  /// already safely on disk with it, since each later press re-serializes the
  /// same poisoned array. `SessionMarkerLog.mark` already clamps on the way in;
  /// this is the backstop for a caller that did not come through it, and it
  /// costs the one value that cannot be a time anyway.
  static func markerDictionaries(_ markers: [SessionMarker]) -> [[String: Any]] {
    markers
      .filter { $0.at.isFinite }
      .sorted { $0.at < $1.at }
      .map { marker in
        var dictionary: [String: Any] = [
          "id": marker.id.uuidString,
          "atSeconds": marker.at,
          "createdAt": iso8601(marker.createdAt)
        ]
        if let label = marker.label, !label.isEmpty {
          dictionary["label"] = label
        }
        return dictionary
      }
  }

  /// Write the session's markers onto its record — **at press time**, not at
  /// Stop, so a session that crashes, is killed or never reaches the seal keeps
  /// every moment the owner flagged.
  ///
  /// The whole array goes every time, because `mutateRecord` sets a key rather
  /// than appending to one. That is not a cost worth optimising away: it makes
  /// the record's list exactly the log's list after every press, so there is no
  /// state in which the two have diverged and no repair path to get wrong.
  /// Everything else on the record survives — `mutateRecord` merges — so a
  /// press cannot clobber a field the CLI owns.
  ///
  /// Not `@discardableResult`, for the reason `mutateRecord` is not: a false
  /// here is a moment the owner believes they flagged and the record does not
  /// hold.
  static func recordMarkers(
    id: String,
    markers: [SessionMarker],
    historyDirectory: URL
  ) -> Bool {
    mutateRecord(
      id: id,
      historyDirectory: historyDirectory,
      ["markers": markerDictionaries(markers)]
    )
  }

  /// Write whether the live session is paused (XIA-447).
  ///
  /// **A flag beside `status`, never a new status**, and both halves of the
  /// contract agree on that. `status` stays `recording`, because to every
  /// consumer a paused session *is* recording: it owns a record, it holds the
  /// audio file open, and nothing about the lifecycle machine has changed.
  ///
  /// A `"paused"` status would have needed a new value in both vocabularies and
  /// in every total function over them — and, worse, it would have been unsafe
  /// in the one direction the decoders cannot defend. `normalizeHistoryStatus`
  /// resolves an unrecognized value by what the record HAS, so an older build
  /// (or the shipped `dist/index.js` the app shells out to) would read
  /// `"paused"` as `transcribed` — a *rest* state, which `isInFlight` refuses
  /// and the launch sweep therefore skips forever. A paused session whose
  /// process went away would have become a finished transcript with no
  /// transcript in it, which is exactly what XIA-430's tolerant decoding exists
  /// to prevent.
  ///
  /// With a flag the sweep is untouched: the record still says `recording`, so
  /// an interrupted paused session still resolves to `failed(recording)` +
  /// `interrupted` and still presents as "Interrupted" — the correct fact,
  /// because nobody chose that outcome. An older reader ignores the key and
  /// says "Recording": under-informative, never wrong, never terminal.
  ///
  /// It rides through `mutateRecord`, which merges rather than rebuilds, so it
  /// cannot clobber a field the CLI owns. Not `@discardableResult`, for the
  /// reason nothing else here is.
  static func recordPaused(
    id: String,
    paused: Bool,
    historyDirectory: URL
  ) -> Bool {
    mutateRecord(id: id, historyDirectory: historyDirectory, ["paused": paused])
  }

  /// CLI's TranscriptSegment shape: `{ start, end, text }`. Live segments
  /// carry only an end time, so each segment's start is the previous end
  /// (first segment starts at 0).
  static func segmentDictionaries(_ segments: [LiveMeetingSession.LiveSegment]) -> [[String: Any]] {
    var previousEnd: TimeInterval = 0
    return segments.map { segment in
      let start = previousEnd
      previousEnd = segment.endTime
      return [
        "start": Int(start),
        "end": Int(segment.endTime),
        "text": segment.text
      ]
    }
  }

  // MARK: - Formatting helpers

  /// `[MM:SS]` — mirrors `formatTimestamp` in src/pipeline/transcribe.ts
  /// (minutes pad to 2 but may grow past 99; seconds always 2).
  private static func formatTimestamp(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    return String(format: "[%02d:%02d]", total / 60, total % 60)
  }

  private static let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  private static func iso8601(_ date: Date) -> String {
    isoFormatter.string(from: date)
  }

  private static func dayDate(_ date: Date) -> String {
    dayFormatter.string(from: date)
  }
}
