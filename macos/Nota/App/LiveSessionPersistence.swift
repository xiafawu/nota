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
