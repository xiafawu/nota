import Foundation

/// Reasons a live session's result cannot be persisted as a meeting record.
/// Only the two semantic cases are distinct; every other failure is an
/// underlying file-system error and propagates as-is.
enum LiveSessionPersistenceError: LocalizedError, Equatable {
  /// Nothing was recognized (whitespace-only transcript). Nothing is written.
  case emptyTranscript
  /// The session produced text but no audio file — cannot build a faithful
  /// record (real records always carry `sourcePath`). Nothing is written.
  case missingAudio

  var errorDescription: String? {
    switch self {
    case .emptyTranscript:
      return "No speech was captured"
    case .missingAudio:
      return "Recording failed; transcript was not saved"
    }
  }
}

/// Persists a completed live dictation/transcription session exactly like a
/// regular meeting: the temp audio is moved into the output directory under
/// the `.nota-input-<epoch>-<uuid>.<ext>` convention (`makeStableInputCopy`),
/// the transcript markdown is written next to it with the CLI's filename and
/// header shape, and a `~/.nota/history/<id>.json` record is written with the
/// schema the CLI produces (`src/pipeline/history.ts`). Pure file logic —
/// injectable directories keep it testable without touching the real
/// `~/.nota` or `~/Documents/Nota`.
///
/// Deliberately does NOT re-run the CLI transcription pipeline: the transcript
/// already exists from the realtime stream.
///
/// Follow-up (out of scope for v1): summary enrichment. Run the CLI's
/// `nota history summarize-history <id>` verb over the new record (or its
/// `setRecordSummary` equivalent) to flip `status` to "completed" and add the
/// `## Summary` sections, mirroring what the regular pipeline does after
/// transcription.
enum LiveSessionPersistence {
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

  // MARK: - Persist

  /// Move `result.audioURL` to the output directory, write the `.summary.md`
  /// and the history record, and return what was written. Throws
  /// `LiveSessionPersistenceError` for the semantic skips; other failures are
  /// file-system errors. The order mirrors the task contract (audio → markdown
  /// → record); if the record write fails, the markdown and audio are rolled
  /// back so no half-persisted output shows up in `refreshHistory()`.
  static func persist(
    result: LiveMeetingSession.LiveMeetingResult,
    displayName: String = "Live Meeting",
    title: String = "Live Meeting",
    capturedAt: Date = Date(),
    kind: HistoryKind = .meeting,
    diarize: Bool = false,
    identify: Bool = false,
    outputDirectory: URL,
    historyDirectory: URL
  ) throws -> SavedSession {
    let transcript = result.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !transcript.isEmpty else {
      throw LiveSessionPersistenceError.emptyTranscript
    }
    guard let tempAudio = result.audioURL else {
      throw LiveSessionPersistenceError.missingAudio
    }

    let fileManager = FileManager.default
    try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    // 1. Stable audio copy — same convention as makeStableInputCopy so the
    //    record's sourcePath matches every other meeting record.
    let audioExtension = tempAudio.pathExtension.isEmpty ? "wav" : tempAudio.pathExtension
    let audioURL = outputDirectory.appendingPathComponent(
      ".nota-input-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).\(audioExtension)"
    )
    try fileManager.moveItem(at: tempAudio, to: audioURL)

    do {
      // 2. Transcript markdown — same filename and header shape as the CLI
      //    (src/pipeline/write.ts buildMarkdown, no-summary variant).
      let createdAt = Date()
      let durationMinutes = Self.durationMinutes(for: result.duration)
      let sourceName = audioURL.lastPathComponent
      let baseName = sanitizedBaseName(URL(fileURLWithPath: displayName))
      let outputURL = outputDirectory.appendingPathComponent(
        "\(baseName)-\(notaTimestamp()).summary.md"
      )
      let markdown = Self.buildMarkdown(
        title: title,
        segments: result.segments,
        transcript: transcript,
        capturedAt: capturedAt,
        createdAt: createdAt,
        durationMinutes: durationMinutes,
        sourceName: sourceName
      )
      try markdown.write(to: outputURL, atomically: true, encoding: .utf8)

      // 3. History record — schema-identical to createHistoryRecord's output
      //    (status "transcribed": a live session skips the summary step).
      let id = makeHistoryID(createdAtISO8601: iso8601(createdAt))
      let recordURL = historyDirectory.appendingPathComponent("\(id).json")
      let record: [String: Any] = [
        "id": id,
        "createdAt": iso8601(createdAt),
        "updatedAt": iso8601(createdAt),
        "capturedAt": iso8601(capturedAt),
        "sourcePath": audioURL.path,
        "sourceName": sourceName,
        "provider": "assemblyai",
        "kind": kind.rawValue,
        "options": [
          "diarize": diarize,
          "identify": identify,
          // Omitting speech_model selects AssemblyAI's default = Universal-3.5
          // Pro Streaming; recorded here for the usage/dashboard surfaces.
          "model": "universal-3.5-pro-streaming"
        ],
        "durationMinutes": durationMinutes,
        "transcriptText": transcript,
        "segments": Self.segmentDictionaries(result.segments),
        "outputPath": outputURL.path,
        "status": "transcribed"
      ]
      let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted])
      try fileManager.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
      try data.write(to: recordURL, options: .atomic)

      return SavedSession(
        historyID: id,
        audioURL: audioURL,
        outputURL: outputURL,
        recordURL: recordURL,
        markdown: markdown
      )
    } catch {
      // Roll back so history never shows an unrecorded (or half-recorded) file.
      try? fileManager.removeItem(at: audioURL)
      throw error
    }
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
