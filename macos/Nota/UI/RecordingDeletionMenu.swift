import SwiftUI

/// The drawer row's two deletion verbs (XIA-436).
///
/// They are **two** verbs, not one with a checkbox, because they are the two
/// directions of the containment rule and only one of them is reversible in
/// any practical sense:
///
///   - **Delete recording audio…** — reclaims almost all of the record's size
///     and costs almost none of its value once a transcript exists. The
///     transcript, summary and markers stay.
///   - **Delete record…** — takes the transcript AND its audio. The exported
///     `.md` on disk is never touched; it lives outside `~/.nota`.
///
/// Both confirm, and both confirmations name what goes, what stays, the size
/// in bytes, and that it cannot be undone (`RecordingDeletionCopy`). Nothing
/// here is ever invoked on a timer — deletion is only ever an explicit verb.
///
/// Attached with a single modifier call at the row's call site so this lane
/// and the stage/progress lane touch `HistoryDrawerView` in as few lines as
/// possible.
struct RecordingDeletionMenu: ViewModifier {
  let entry: HistoryEntry
  /// The record behind the row, resolved lazily when the menu opens: the
  /// drawer holds hundreds of rows and this is a directory scan.
  let locate: () -> RecordingStore.LocatedRecord?
  let onDeleteAudio: (RecordingStore.LocatedRecord) -> Void
  let onDeleteRecord: (RecordingStore.LocatedRecord) -> Void

  @State private var pendingAudio: RecordingStore.LocatedRecord?
  @State private var pendingRecord: RecordingStore.LocatedRecord?
  /// Set when the menu was opened on a row whose record could not be found —
  /// a deletion that cannot name its target is refused rather than guessed at.
  @State private var unresolved = false

  func body(content: Content) -> some View {
    content
      .contextMenu {
        // Reveal is here because the row's trash button is not (XIA-436): that
        // button deleted the exported `.md`, which Nota never does. Removing
        // the owner's own file stays the owner's own business, and this is the
        // route to it — non-destructive, and it opens on the file itself.
        Button("Reveal in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        }
        Divider()
        Button("Delete recording audio…") {
          if let record = locate() { pendingAudio = record } else { unresolved = true }
        }
        // Disabled would be silent about WHY. The dialog says "keeps no
        // audio", which is the answer, and is also what a legacy record needs
        // to hear — once, quietly, never as an error.
        Divider()
        Button("Delete record…", role: .destructive) {
          if let record = locate() { pendingRecord = record } else { unresolved = true }
        }
      }
      .confirmationDialog(
        RecordingDeletionCopy.audioTitle(entry.title),
        isPresented: Binding(
          get: { pendingAudio != nil },
          set: { if !$0 { pendingAudio = nil } }
        ),
        titleVisibility: .visible,
        presenting: pendingAudio
      ) { record in
        // A record with no audio gets an acknowledgement, not a delete button:
        // there is nothing to confirm.
        if record.audioBytes != nil {
          Button("Delete Audio", role: .destructive) { onDeleteAudio(record) }
        }
        Button("Cancel", role: .cancel) {}
      } message: { record in
        Text(
          RecordingDeletionCopy.audioMessage(
            bytes: record.audioBytes,
            hasTranscript: record.hasTranscript,
            speakerClipCount: record.speakerClipCount
          )
        )
      }
      .confirmationDialog(
        RecordingDeletionCopy.recordTitle(entry.title),
        isPresented: Binding(
          get: { pendingRecord != nil },
          set: { if !$0 { pendingRecord = nil } }
        ),
        titleVisibility: .visible,
        presenting: pendingRecord
      ) { record in
        Button("Delete Record", role: .destructive) { onDeleteRecord(record) }
        Button("Cancel", role: .cancel) {}
      } message: { record in
        Text(
          RecordingDeletionCopy.recordMessage(
            bytes: (record.audioBytes ?? 0) + estimatedRecordBytes(record),
            keepsMarkdown: record.outputPath != nil
          )
        )
      }
      .alert("Nota could not find this record", isPresented: $unresolved) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(
          "Its transcript file is still on disk and nothing was deleted. "
            + "Reopen the drawer and try again."
        )
      }
  }

  /// The record JSON's own size, so the confirmation's figure is the whole
  /// footprint rather than the audio alone. Best effort — a size that cannot
  /// be read contributes zero rather than blocking the dialog.
  private func estimatedRecordBytes(_ record: RecordingStore.LocatedRecord) -> Int {
    let fileManager = FileManager.default
    var total = 0
    if let attributes = try? fileManager.attributesOfItem(atPath: record.recordURL.path),
       let size = (attributes[.size] as? NSNumber)?.intValue {
      total += size
    }
    // Speaker clips live in the assets folder and go with the record.
    if let contents = try? fileManager.contentsOfDirectory(
      at: record.assetsURL,
      includingPropertiesForKeys: [.fileSizeKey],
      options: []
    ) {
      for file in contents where file != record.audioURL {
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
          total += size
        }
      }
    }
    return total
  }
}

extension View {
  /// Attach the row's two deletion verbs. One call, so the row's call site in
  /// `HistoryDrawerView` stays a single line for this lane.
  func recordingDeletionMenu(
    entry: HistoryEntry,
    locate: @escaping () -> RecordingStore.LocatedRecord?,
    onDeleteAudio: @escaping (RecordingStore.LocatedRecord) -> Void,
    onDeleteRecord: @escaping (RecordingStore.LocatedRecord) -> Void
  ) -> some View {
    modifier(
      RecordingDeletionMenu(
        entry: entry,
        locate: locate,
        onDeleteAudio: onDeleteAudio,
        onDeleteRecord: onDeleteRecord
      )
    )
  }
}
