import Foundation

/// Whether Nota may take a file in right now, and what it says when it may
/// not (PT-1, FB-3).
///
/// A file reaches `NotaModel.accept(_:)` five ways — a drop on the window, ⌘O,
/// the Dock, Finder's Open With and the share sheet's `nota://import` — and
/// only the drop has a stroke to keep off. Taking one while another file
/// transcribes retitled the running screen to the new file and then never
/// transcribed it (`performTranscribe` returns at `!isRunning`); taking one
/// during a live session started a second paid pipeline behind the pane the
/// live phase pins in front (P-C9). So there is **one** predicate, and the
/// drop target, the ⌘O command and `accept` all ask it.
enum FileIntake {
  /// The one predicate. `liveSessionShown` is what the window shows, not what
  /// the session object says: it is `LivePhaseGate.showsLiveSession`, so a
  /// starting session refuses (the press is accepted the instant it is seen)
  /// and a handed-off one does not (Stop brought the window home, and home's
  /// controls are live again).
  static func isOpen(isRunning: Bool, liveSessionShown: Bool) -> Bool {
    !isRunning && !liveSessionShown
  }

  /// What `accept` does with one arriving file.
  enum Decision: Equatable {
    /// Take it, through the summary rail's dismissal policy as before.
    case take
    /// Refuse it, and say so in the window's one alert.
    case refuse(OwnerAlert)
    /// Say nothing: this is the file already transcribing, delivered twice.
    case ignore
  }

  /// - Parameters:
  ///   - fileURL: the arriving file, already resolved from `nota://import`.
  ///   - fileName: what the owner calls it (the share sheet forwards the real
  ///     name; a drop's basename already is it).
  ///   - canTake: `NotaModel.canTakeFile` — the predicate above, passed in so
  ///     that `accept` and ⌘O read the same value rather than two copies of it.
  ///   - isRunning: which of the two refusals to say.
  ///   - runningURL / runningName: the file a running transcription is on.
  static func decide(
    fileURL: URL,
    fileName: String,
    canTake: Bool,
    isRunning: Bool,
    runningURL: URL?,
    runningName: String
  ) -> Decision {
    if canTake { return .take }
    // A Finder or Dock open can arrive twice — through `.onOpenURL` and
    // through `application(_:open:)` → `.notaOpenURLs` — and the second copy
    // finds the first one already running. That is the file on screen, not a
    // file being turned away, and an alert saying it was would be false.
    if isRunning,
       let runningURL,
       runningURL.standardizedFileURL == fileURL.standardizedFileURL {
      return .ignore
    }
    return .refuse(busyRefusal(fileName: fileName, isRunning: isRunning, runningName: runningName))
  }

  /// The refusal for a file that arrived while Nota could not take one.
  static func busyRefusal(fileName: String, isRunning: Bool, runningName: String) -> OwnerAlert {
    let title = "“\(fileName)” was not opened"
    if isRunning {
      return OwnerAlert(
        title: title,
        message: "Nota is transcribing “\(runningName)” and takes one file at a time. "
          + "Open this file again when that one is done."
      )
    }
    return OwnerAlert(
      title: title,
      message: "A recording session is open, and Nota takes no file while one is. "
        + "Open this file again once the session has ended."
    )
  }
}
