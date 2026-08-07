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
    /// Per-speaker voice clips (`<label>.pcm`) in the assets folder. They are
    /// raw audio of the same people and `deleteAudio` deliberately keeps them,
    /// so the confirmation has to be able to say so: an owner deleting
    /// recording audio for PRIVACY who is told only "the recording goes" has
    /// been told the wrong thing.
    var speakerClipCount: Int = 0
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
      hasTranscript: !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      speakerClipCount: speakerClipCount(in: assets)
    )
  }

  /// How many per-speaker voice clips a record's assets folder holds. Best
  /// effort: a folder that cannot be read reports none rather than blocking a
  /// dialog.
  static func speakerClipCount(in assets: URL) -> Int {
    let contents = (try? FileManager.default.contentsOfDirectory(
      at: assets,
      includingPropertiesForKeys: nil,
      options: []
    )) ?? []
    return contents.filter { $0.pathExtension == "pcm" }.count
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
  ///
  /// **Assets first, and the result is checked.** A `try?` here was a silent
  /// partial delete: an assets folder that cannot be removed (an immutable
  /// flag, a read-only parent, a file owned by another uid after a Migration
  /// Assistant restore) was swallowed, the record JSON was removed anyway, and
  /// the function reported success. What is left is `<id>.assets/recording.caf`
  /// with **no record naming it** — the forbidden partial delete, and invisible
  /// to every verb, since the store's own accounting walks records. The order
  /// matters for the same reason: failing after the JSON is gone cannot be
  /// undone, while failing before it leaves a record pointing at an
  /// empty-or-partial folder, which the owner can simply delete again.
  @discardableResult
  static func deleteRecord(_ record: LocatedRecord) -> Bool {
    let fileManager = FileManager.default
    do {
      try fileManager.removeItem(at: record.assetsURL)
    } catch {
      if (error as NSError).code != NSFileNoSuchFileError {
        logger.error(
          """
          record \(record.id, privacy: .public) assets delete failed, \
          record kept: \(error.localizedDescription, privacy: .public)
          """
        )
        return false
      }
    }
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

  /// What a Discard press actually did, and therefore what the owner is told.
  enum DiscardOutcome: Equatable {
    /// The record and its audio are gone.
    case deleted
    /// The delete did not land. The record was settled to a terminal status
    /// instead and everything it holds is still on disk.
    case keptAfterFailure
  }
}

extension LiveSessionOwner {
  /// Discard the record a live session owns — and, when the delete does not
  /// land, settle it rather than walking away from it.
  ///
  /// This exists as one function because the two halves cannot be separated
  /// without breaking XIA-430's rule 3, *"nothing is abandoned in an in-flight
  /// status"*. Dropping the delete's result and calling `release` regardless
  /// clears ownership of a record that is still on disk saying `recording`:
  /// `settle` can never run for it, `observeLiveSessionState` cannot rescue it
  /// (`isOwning` is false), the owner is told "Recording discarded" — and at
  /// the next launch the sweep stamps it `failed(recording) + interrupted`,
  /// presenting as **"Interrupted"**, a session that never happened, with the
  /// audio they believed they discarded still there.
  ///
  /// `delete` is injected so the failure branch is drivable without a
  /// read-only filesystem.
  @discardableResult
  func discard(
    _ started: LiveSessionPersistence.StartedRecord,
    delete: (LiveSessionPersistence.StartedRecord) -> Bool = RecordingStore.discardLiveRecording
  ) -> RecordingStore.DiscardOutcome {
    if delete(started) {
      release(started)
      return .deleted
    }
    // The record is still there, so it must come to rest like every other way
    // out of a session: a terminal status, and its audio kept.
    settle(started)
    return .keptAfterFailure
  }
}

// MARK: - The storage summary the CLI computes

/// One record's footprint. Decoded from `nota history storage --json`; the
/// field names are the TS interface's, verbatim.
///
/// Pinned against the CLI's REAL output rather than a hand-written shape:
/// `macos/Nota/UI/Tests/Fixtures/storage-summary.json` is generated by
/// `scripts/storage-summary-fixture.ts` and rebuilt-and-compared by a TS test,
/// so neither side can move without the other failing. The hand-copy that
/// preceded it had already drifted — it was missing the `status` key every
/// real row carries.
struct StoredRecordRow: Codable, Equatable {
  let id: String
  let createdAt: String
  let sourceName: String
  /// The record's lifecycle status, as `HistoryStatus` spells it.
  let status: String
  /// Null for a record that keeps no audio — rendered in words, never "0 B".
  let audioBytes: Int?
  let assetsBytes: Int
  /// The per-speaker voice clips `delete-audio` keeps.
  let speakerClipCount: Int
  let speakerClipBytes: Int
  let recordBytes: Int
  let totalBytes: Int
}

/// Bytes in the store that no readable record names — counted, named, and
/// never removed by Nota.
struct StoredOrphanRow: Codable, Equatable {
  let id: String
  let reason: String
  let bytes: Int
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
  /// Every byte the store holds: the records AND the orphans.
  let totalBytes: Int
  let audioBytes: Int
  let oldestCreatedAt: String?
  let thisMonthBytes: Int
  /// Optional so a summary written by a Nota that predates orphan accounting
  /// still decodes — tolerance per field, as everywhere else in this app.
  var orphans: [StoredOrphanRow]?
  var orphanBytes: Int?
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
}

// `StorageFormat.audio(_:)` used to live here, rendering "audio not kept" for
// a nil. It is gone rather than kept for symmetry: the app has no per-record
// audio COLUMN to render — the Usage sheet shows totals and the drawer row
// shows a title — so nothing but its own test ever called it, and a function
// with only a test for a caller reads as coverage of a surface that does not
// exist. Where the app really has to tell an owner a record keeps no audio is
// the delete-audio confirmation, and `RecordingDeletionCopy.audioMessage` says
// it there in a sentence. The CLI keeps the column and the wording
// (`row.audioBytes === null ? "audio not kept" : …` in src/cli/storage.ts).

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

  /// What `delete-audio` does and — the harder half — what it leaves.
  ///
  /// `speakerClipCount` is not decoration. The per-speaker voice clips are raw
  /// audio of the same people, they live in the same folder as the recording,
  /// and this verb deliberately keeps them. "Only the recording goes" is a
  /// true sentence that misleads exactly the owner most likely to be reading
  /// it: someone deleting audio because they do not want the audio kept.
  static func audioMessage(
    bytes: Int?,
    hasTranscript: Bool,
    speakerClipCount: Int = 0
  ) -> String {
    let goes = bytes.map { "\(StorageFormat.bytes($0)) of audio will be deleted." }
      ?? "This record keeps no audio."
    let stays = hasTranscript
      ? "The transcript, summary and markers stay — only the recording goes."
      : "The record stays — only the recording goes."
    let clips = speakerClipCount > 0
      ? " \(speakerClipCount) per-speaker voice clip\(speakerClipCount == 1 ? "" : "s") "
        + "also stay — they are audio too, and “Delete record…” is what removes them."
      : ""
    return "\(goes) \(stays)\(clips) This cannot be undone."
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

  // MARK: - Discard

  /// Discard, on the failure banner, is the most destructive verb in the app
  /// and the only one that used to confirm nothing.
  ///
  /// It sits between **Save Transcript** and **Try Again**, both harmless, and
  /// it reads as "dismiss this banner". What it does is delete the record and
  /// its recording: the 88 minutes of a 90-minute meeting whose socket dropped
  /// at minute 88, with no undo. The drawer's own verbs name the bytes, what
  /// stays, and that it cannot be undone; the one that destroys the most may
  /// not say less. The message therefore names the length, the size, and the
  /// alternative the banner is already offering.
  static let discardTitle = "Discard this recording?"

  static func discardMessage(
    seconds: TimeInterval,
    bytes: Int?,
    hasTranscript: Bool
  ) -> String {
    let length = discardLength(seconds)
    let size = bytes.map { " (\(StorageFormat.bytes($0)))" } ?? ""
    let recorded = "\(length)\(size) of audio and this session's record will be deleted."
    let alternative = hasTranscript
      ? "Save Transcript keeps what was heard, and the recording with it."
      : "Try Again keeps this recording and starts a new session."
    return "\(recorded) Audio cannot be re-recorded. \(alternative) This cannot be undone."
  }

  /// `2745` → `"45 minutes"`. Minutes once there is a minute, because that is
  /// how long an owner thinks a meeting was.
  static func discardLength(_ seconds: TimeInterval) -> String {
    let whole = max(0, Int(seconds.rounded()))
    if whole < 60 { return "\(whole) second\(whole == 1 ? "" : "s")" }
    let minutes = whole / 60
    return "\(minutes) minute\(minutes == 1 ? "" : "s")"
  }
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
