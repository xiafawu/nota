import Foundation
import UniformTypeIdentifiers

/// Whether Nota may take a file in right now, and what it says when it may
/// not (PT-1, FB-3, PT-2).
///
/// A file reaches `NotaModel.accept(_:)` five ways — a drop on the window, ⌘O,
/// the Dock, Finder's Open With and the share sheet's `nota://import` — and
/// only the drop has a stroke to keep off. Taking one while another file
/// transcribes retitled the running screen to the new file and then never
/// transcribed it (`performTranscribe` returns at `!isRunning`); taking one
/// during a live session started a second paid pipeline behind the pane the
/// live phase pins in front (P-C9). So there is **one** predicate, and the
/// drop target, the ⌘O command and `accept` all ask it.
///
/// A file of a type Nota does not transcribe is refused here too, and said
/// (PT-2): the old refusal wrote "Unsupported file type" to a status line
/// drawn only during a run, so a dropped .pdf lit the target, was taken, and
/// nothing happened at all.
enum FileIntake {
  /// The one predicate. `liveSessionShown` is what the window shows, not what
  /// the session object says: it is `LivePhaseGate.showsLiveSession`, so a
  /// starting session refuses (the press is accepted the instant it is seen)
  /// and a handed-off one does not (Stop brought the window home, and home's
  /// controls are live again).
  static func isOpen(isRunning: Bool, liveSessionShown: Bool) -> Bool {
    !isRunning && !liveSessionShown
  }

  /// Whether Nota transcribes this file, by the one list `supportedExtensions`
  /// (the TS pipeline's `validate.ts` holds the same set). Case-insensitive, so
  /// a voice memo exported as `.QTA` is taken. A folder has no extension and
  /// is not.
  static func isSupported(_ fileURL: URL, extensions: Set<String> = supportedExtensions) -> Bool {
    extensions.contains(fileURL.pathExtension.lowercased())
  }

  /// What `accept` does with one arriving file.
  enum Decision: Equatable {
    /// Take it, through the summary rail's dismissal policy as before. `note`
    /// is said once the file has been taken — the other files of a
    /// multi-file drop that were not.
    case take(note: OwnerAlert?)
    /// Refuse it, and say so in the window's one alert.
    case refuse(OwnerAlert)
    /// Say nothing: this is the file already transcribing, delivered twice.
    case ignore
  }

  /// - Parameters:
  ///   - fileURL: the arriving file, already resolved from `nota://import`.
  ///   - fileName: what the owner calls it (the share sheet forwards the real
  ///     name; a drop's basename already is it).
  ///   - isSupported: `isSupported(fileURL)`, as `accept` asks it.
  ///   - alsoDropped: how many other files arrived with this one. Nota takes
  ///     one file at a time and only the first is ever looked at.
  ///   - canTake: `NotaModel.canTakeFile` — the predicate above, passed in so
  ///     that `accept` and ⌘O read the same value rather than two copies of it.
  ///   - isRunning: which of the two busy refusals to say.
  ///   - runningURL / runningName: the file a running transcription is on.
  static func decide(
    fileURL: URL,
    fileName: String,
    isSupported: Bool,
    alsoDropped: Int = 0,
    canTake: Bool,
    isRunning: Bool,
    runningURL: URL?,
    runningName: String
  ) -> Decision {
    // The type first: "this will never open" is the answer worth giving, and
    // "open it again when that one is done" would only send the owner back to
    // hear it.
    guard isSupported else {
      return .refuse(unsupportedRefusal(fileName: fileName, alsoDropped: alsoDropped))
    }
    if canTake {
      return .take(note: onlyFirstNote(fileName: fileName, alsoDropped: alsoDropped))
    }
    // A Finder or Dock open can arrive twice — through `.onOpenURL` and
    // through `application(_:open:)` → `.notaOpenURLs` — and the second copy
    // finds the first one already running. That is the file on screen, not a
    // file being turned away, and an alert saying it was would be false.
    if isRunning,
       let runningURL,
       runningURL.standardizedFileURL == fileURL.standardizedFileURL {
      return .ignore
    }
    return .refuse(busyRefusal(
      fileName: fileName, isRunning: isRunning, runningName: runningName, alsoDropped: alsoDropped
    ))
  }

  /// The refusal for a file that arrived while Nota could not take one.
  static func busyRefusal(
    fileName: String, isRunning: Bool, runningName: String, alsoDropped: Int = 0
  ) -> OwnerAlert {
    let title = "“\(fileName)” was not opened"
    if isRunning {
      return OwnerAlert(
        title: title,
        message: "Nota is transcribing “\(runningName)” and takes one file at a time. "
          + "Open this file again when that one is done." + othersNotOpened(alsoDropped)
      )
    }
    return OwnerAlert(
      title: title,
      message: "A recording session is open, and Nota takes no file while one is. "
        + "Open this file again once the session has ended." + othersNotOpened(alsoDropped)
    )
  }

  /// The refusal for a file Nota does not transcribe: names the file, and
  /// every type it would have taken, from the one list.
  static func unsupportedRefusal(fileName: String, alsoDropped: Int = 0) -> OwnerAlert {
    OwnerAlert(
      title: "Nota can't transcribe “\(fileName)”",
      message: "Nota transcribes audio and video files: \(supportedTypesList())."
        + othersNotOpened(alsoDropped)
    )
  }

  /// Said after the first of several files has been taken, because the rest
  /// went nowhere and the drop gave no sign of it. Nil for a single file.
  static func onlyFirstNote(fileName: String, alsoDropped: Int) -> OwnerAlert? {
    guard alsoDropped > 0 else { return nil }
    let rest = alsoDropped == 1
      ? "the other file was not opened. Open it on its own"
      : "the other \(alsoDropped) files were not opened. Open them one at a time"
    return OwnerAlert(
      title: "Only “\(fileName)” was opened",
      message: "Nota transcribes one file at a time, so \(rest) once this one is done."
    )
  }

  /// "AAC, AIF, AIFF, … , WAV and WEBM" — the list the refusal names, built
  /// from `supportedExtensions` so it cannot drift from what is accepted.
  static func supportedTypesList(_ extensions: Set<String> = supportedExtensions) -> String {
    let names = extensions.map { $0.uppercased() }.sorted()
    guard let last = names.last else { return "" }
    guard names.count > 1 else { return last }
    return names.dropLast().joined(separator: ", ") + " and " + last
  }

  /// The open panel's types, one per supported extension, built from the same
  /// list `accept` checks — it used to offer `.audio` and `.movie` whole, so
  /// .avi and .m4v were offered and then refused.
  ///
  /// `.qta` has to stay openable whatever the system declares. Today it is
  /// `com.apple.quicktime-audio`, and an extension nobody declares gets a
  /// *dynamic* type matched by extension rather than nil; `.data` is the last
  /// resort for a resolver that answers nothing, and it would admit every
  /// file — which is safe only because `accept` checks the extension itself
  /// and says so when it refuses.
  static func openPanelTypes(
    extensions: Set<String> = supportedExtensions,
    resolve: (String) -> UTType? = { UTType(filenameExtension: $0) }
  ) -> [UTType] {
    var types: [UTType] = []
    for ext in extensions.sorted() {
      let type = resolve(ext) ?? .data
      if !types.contains(type) { types.append(type) }
    }
    return types
  }

  /// Whether ⌘O's panel lets the owner pick this item: the panel's second
  /// gate, asking the same extension check `accept` asks.
  ///
  /// The types alone are wider than the list. A type admits everything that
  /// conforms to it, and measured on macOS 26: `public.mpeg-4` (for .mp4)
  /// admits .m4v, and `org.xiph.ogg-audio` (for .ogg) admits .opus and .oga —
  /// each offered and then refused. A folder stays enabled, or the panel could
  /// not be navigated at all; `isDirectory` is asked only for an item the
  /// extension check turned down, since this runs once per listed item.
  static func enablesInOpenPanel(
    _ url: URL,
    isDirectory: @autoclosure () -> Bool,
    extensions: Set<String> = supportedExtensions
  ) -> Bool {
    isSupported(url, extensions: extensions) || isDirectory()
  }

  private static func othersNotOpened(_ count: Int) -> String {
    switch count {
    case ..<1: return ""
    case 1: return " The other file was not opened either."
    default: return " The other \(count) files were not opened either."
    }
  }
}
