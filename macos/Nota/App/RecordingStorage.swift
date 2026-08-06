import Foundation
import os

/// What a recording costs on disk, and the only two things the app does that
/// make it cost less (XIA-436).
///
/// **Nothing in this file runs on a timer.** There is no sweep, no scheduled
/// cleanup, no "reclaim space" path and no deletion on failure. Every function
/// here is downstream of a menu item the owner picked and a confirmation they
/// accepted. The visible figure IS the retention policy: the owner is asked to
/// accept unbounded audio growth, and the deal is that they can always see the
/// number and always delete by hand.
///
/// **The containment rule.** Deleting the transcript deletes the audio;
/// deleting the audio never touches the transcript. One direction, and it is
/// structural here rather than a convention: `deleteAudio` unlinks one file and
/// clears two fields, `deleteRecord` removes the assets folder wholesale.
///
/// **The exported `.md` is never deleted.** It lives outside `~/.nota` — often
/// beside the owner's own source audio — and Nota does not own it.
///
/// The semantics mirror `src/pipeline/storage.ts` exactly (same fields, same
/// legacy rule, same traversal refusal). The *totals* are not recomputed here:
/// `StoredStorageSummary` decodes what `nota history storage --json` produced,
/// so the Usage sheet and the CLI cannot disagree about how big the store is.
enum RecordingStore {
  static let logger = Logger(subsystem: "com.xiafawu.nota", category: "history.storage")

  // MARK: - Locating a record behind a drawer row

  /// A record the app can act on: where it is, and what of it is deletable.
  struct LocatedRecord: Equatable {
    let id: String
    let recordURL: URL
    let assetsURL: URL
    /// The kept recording, or nil when this record keeps no audio — a legacy
    /// record (only a `sourcePath`, pointing at the owner's OWN file outside
    /// the store) or one whose audio was already deleted. Reads "audio not
    /// kept": quietly, once, never as an error.
    let audioURL: URL?
    let audioBytes: Int?
    /// The exported markdown. Reported so the confirmation can promise it
    /// stays; never passed to a remove.
    let outputPath: String?
    /// True when the record carries transcript text — what "the transcript
    /// stays" is a promise about.
    let hasTranscript: Bool
  }

  /// Find the record behind a history row (rows are keyed by the exported
  /// `.md` path, which is the only handle the drawer has).
  static func locate(outputPath: URL, historyDirectory: URL) -> LocatedRecord? {
    let target = outputPath.standardizedFileURL.path
    let fileManager = FileManager.default
    guard let entries = try? fileManager.contentsOfDirectory(
      at: historyDirectory,
      includingPropertiesForKeys: nil,
      options: []
    ) else {
      return nil
    }
    for entry in entries where entry.pathExtension == "json" {
      guard
        let data = try? Data(contentsOf: entry),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let recordOutput = json["outputPath"] as? String,
        URL(fileURLWithPath: recordOutput).standardizedFileURL.path == target
      else {
        continue
      }
      return located(json: json, historyDirectory: historyDirectory)
    }
    return nil
  }

  /// Build a `LocatedRecord` from a decoded record.
  static func located(json: [String: Any], historyDirectory: URL) -> LocatedRecord? {
    guard let id = json["id"] as? String else { return nil }
    let assets = historyDirectory.appendingPathComponent("\(id).assets", isDirectory: true)
    let audio = keptAudioURL(json: json, historyDirectory: historyDirectory)
    var bytes: Int?
    if let audio,
       let attributes = try? FileManager.default.attributesOfItem(atPath: audio.path),
       let size = (attributes[.size] as? NSNumber)?.intValue,
       size > 0 {
      bytes = size
    }
    let transcript = (json["transcriptText"] as? String) ?? ""
    return LocatedRecord(
      id: id,
      recordURL: historyDirectory.appendingPathComponent("\(id).json"),
      assetsURL: assets,
      // A record naming an audio file that is no longer there keeps no audio.
      audioURL: bytes == nil ? nil : audio,
      audioBytes: bytes,
      outputPath: json["outputPath"] as? String,
      hasTranscript: !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    )
  }

  /// Where a record's KEPT audio is, or nil when it keeps none.
  ///
  /// Deliberately not `LiveSessionPersistence.resolvedAudioURL`. That helper
  /// falls back to the absolute `sourcePath` so a legacy record can still be
  /// PLAYED, and that path is the owner's own file somewhere outside
  /// `~/.nota`. Counting it would inflate the store with bytes it does not
  /// hold; deleting it would hand a remove the owner's original recording.
  static func keptAudioURL(json: [String: Any], historyDirectory: URL) -> URL? {
    guard
      let id = json["id"] as? String,
      let relative = json["audioPath"] as? String,
      !relative.isEmpty
    else {
      return nil
    }
    let assets = historyDirectory
      .appendingPathComponent("\(id).assets", isDirectory: true)
      .standardizedFileURL
    let resolved = assets.appendingPathComponent(relative).standardizedFileURL
    // `audioPath` is read off a JSON file on disk. A value that climbs out of
    // the assets folder is refused rather than followed: this URL is handed to
    // a remove, and the one irreversible thing this app does may not be
    // aimable at an arbitrary file by editing a record.
    guard resolved.path.hasPrefix(assets.path + "/") else { return nil }
    return resolved
  }

  // MARK: - Deleting the audio only

  /// Remove a record's recording and nothing else.
  ///
  /// The record survives in full — transcript, segments, summary, speaker
  /// clips and the exported markdown are all untouched, and it goes on reading
  /// exactly as it did in both the app and the CLI. Only `audioPath` and
  /// `audioBytes` are cleared, which is how every reader learns the audio is
  /// no longer kept.
  ///
  /// Returns whether the record now keeps no audio. Idempotent: a record that
  /// already keeps none is a success, not a failure.
  @discardableResult
  static func deleteAudio(_ record: LocatedRecord, historyDirectory: URL) -> Bool {
    guard let audio = record.audioURL else { return true }
    do {
      try FileManager.default.removeItem(at: audio)
    } catch {
      let code = (error as NSError).code
      // Already gone is the state we wanted.
      if code != NSFileNoSuchFileError {
        logger.error(
          """
          record \(record.id, privacy: .public) audio delete failed: \
          \(error.localizedDescription, privacy: .public)
          """
        )
        return false
      }
    }
    // A merge, never a rebuild: the CLI writes fields the app does not model
    // (usage, suggestions, speakerClips) and a delete verb may not drop them.
    // `mutateRecord` cannot express a REMOVAL, so the read-modify-write is
    // done here — with every other key carried across verbatim.
    guard
      var json = LiveSessionPersistence.loadRecord(
        id: record.id,
        historyDirectory: historyDirectory
      )
    else {
      logger.error("record \(record.id, privacy: .public) unreadable after audio delete")
      return false
    }
    json.removeValue(forKey: "audioPath")
    json.removeValue(forKey: "audioBytes")
    json["updatedAt"] = ISO8601DateFormatter.notaRecord.string(from: Date())
    guard
      let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]),
      (try? data.write(to: record.recordURL, options: .atomic)) != nil
    else {
      logger.error("record \(record.id, privacy: .public) could not be rewritten after audio delete")
      return false
    }
    return true
  }

  // MARK: - Deleting the whole record

  /// Remove a record: its JSON and its whole `<id>.assets/` folder, audio
  /// included. The containment rule's one downward direction.
  ///
  /// The assets folder goes wholesale rather than file by file, so no partial
  /// delete can leave an orphaned folder behind — a per-file loop would fail
  /// that the first time a future asset type appeared.
  ///
  /// The exported `.md` is NEVER removed here. It lives outside `~/.nota` and
  /// Nota does not own it.
  @discardableResult
  static func deleteRecord(_ record: LocatedRecord) -> Bool {
    let fileManager = FileManager.default
    // Assets first: a crash between the two leaves a record pointing at an
    // empty folder (recoverable) rather than an orphaned folder no record
    // names (invisible, and exactly what "leaves no assets folder behind" is
    // about).
    try? fileManager.removeItem(at: record.assetsURL)
    do {
      try fileManager.removeItem(at: record.recordURL)
    } catch {
      if (error as NSError).code != NSFileNoSuchFileError {
        logger.error(
          """
          record \(record.id, privacy: .public) delete failed: \
          \(error.localizedDescription, privacy: .public)
          """
        )
        return false
      }
    }
    return true
  }

  // MARK: - Discard

  /// Throw away a live session the owner discarded: the record and its whole
  /// assets folder, audio included (XIA-436, scope item 2).
  ///
  /// This REPLACES the settle-and-keep behaviour XIA-430 shipped, and the
  /// difference is worth being explicit about, because the standing rule
  /// ("nothing deletes audio automatically, ever") is not being bent here — it
  /// is being honoured. That rule is about *automatic* deletion: sweeps,
  /// scheduled cleanups, failure paths. Discard is none of those. It is an
  /// explicit verb the owner pressed, on a session they are saying they do not
  /// want, and leaving a `failed(recording)` record with audio behind every
  /// press of it made Discard the one button that did not do what it said.
  ///
  /// The distinction that keeps both rules true: a session that *fails* still
  /// settles and keeps everything (`LiveSessionOwner.settle`), because nobody
  /// chose that outcome. Only a press of Discard reaches this function.
  @discardableResult
  static func discardLiveRecording(
    _ started: LiveSessionPersistence.StartedRecord
  ) -> Bool {
    deleteRecord(
      LocatedRecord(
        id: started.historyID,
        recordURL: started.recordURL,
        assetsURL: started.assetsDirectory,
        audioURL: started.audioURL,
        audioBytes: nil,
        outputPath: nil,
        hasTranscript: false
      )
    )
  }
}

// MARK: - The storage summary the CLI computes

/// One record's footprint. Decoded from `nota history storage --json`; the
/// field names are the TS interface's, verbatim.
struct StoredRecordRow: Codable, Equatable {
  let id: String
  let createdAt: String
  let sourceName: String
  /// Null for a record that keeps no audio — rendered "audio not kept".
  let audioBytes: Int?
  let assetsBytes: Int
  let recordBytes: Int
  let totalBytes: Int
}

/// The store's totals, as the CLI computed them.
///
/// The app deliberately does NOT recompute these. `nota history storage` and
/// the Usage sheet are one implementation with two presentations, so the
/// figure the owner is asked to accept cannot differ depending on where they
/// read it.
struct StoredStorageSummary: Codable, Equatable {
  let records: [StoredRecordRow]
  let count: Int
  let totalBytes: Int
  let audioBytes: Int
  let oldestCreatedAt: String?
  let thisMonthBytes: Int
}

// MARK: - Formatting

enum StorageFormat {
  /// `1536` → `"1.5 KB"`. Binary units, one decimal above KB — the same
  /// rendering `formatBytes` in src/pipeline/storage.ts produces, so a figure
  /// does not change its spelling between the sheet and the terminal.
  static func bytes(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    let units = ["KB", "MB", "GB", "TB"]
    var value = Double(bytes) / 1024
    var unit = 0
    while value >= 1024 && unit < units.count - 1 {
      value /= 1024
      unit += 1
    }
    return String(format: "%.1f %@", value, units[unit])
  }

  /// What a record's audio column reads. A record keeping no audio says so in
  /// words: "0 B" would read as a recording that exists and is empty.
  static func audio(_ bytes: Int?) -> String {
    guard let bytes else { return "audio not kept" }
    return self.bytes(bytes)
  }
}

// MARK: - Confirmation copy

/// What the two confirmations say.
///
/// Pure strings so the promises are testable: each one names what GOES, what
/// STAYS, the size in bytes, and that it cannot be undone. A destructive
/// dialog that does not say what survives is how an owner learns the
/// containment rule the expensive way.
enum RecordingDeletionCopy {
  static func audioTitle(_ title: String) -> String {
    "Delete the audio for “\(title)”?"
  }

  static func audioMessage(bytes: Int?, hasTranscript: Bool) -> String {
    let size = bytes.map { StorageFormat.bytes($0) } ?? "The recording"
    let goes = bytes == nil
      ? "This record keeps no audio."
      : "\(size) of audio will be deleted."
    let stays = hasTranscript
      ? "The transcript, summary and markers stay — only the recording goes."
      : "The record stays — only the recording goes."
    return "\(goes) \(stays) This cannot be undone."
  }

  static func recordTitle(_ title: String) -> String {
    "Delete “\(title)”?"
  }

  static func recordMessage(bytes: Int, keepsMarkdown: Bool) -> String {
    let base =
      "\(StorageFormat.bytes(bytes)) will be deleted: the transcript, the summary and the recording."
    let stays = keepsMarkdown
      ? "The exported .md file on disk is not deleted."
      : "Nota never deletes an exported .md file."
    return "\(base) \(stays) This cannot be undone."
  }

  /// The line the Usage sheet carries under the figure. The retention policy
  /// in one sentence.
  static let neverDeletesOnItsOwn = "Nota never deletes recordings on its own."
}

extension ISO8601DateFormatter {
  /// The record schema's timestamp format (fractional seconds), matching what
  /// `LiveSessionPersistence` writes.
  static let notaRecord: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
}
