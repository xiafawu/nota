import Foundation

/// The half of a record's lifecycle a process can be working on.
enum HistoryStage: String, CaseIterable, Equatable {
  case recording
  case transcribing
  case summarizing
}

/// Where a record got to, as the single string persisted in
/// `~/.nota/history/<id>.json` (XIA-430).
///
/// The record is created at sample zero and this is what says how far it has
/// come. The vocabulary is the CONTRACT with the CLI: `src/pipeline/history-status.ts`
/// mirrors it exactly — same raw strings, same legacy mapping, same legal
/// transitions — so `nota history show <id>` reports the status the app is
/// displaying. Neither half may add a value the other cannot name.
///
///     recording → transcribing → transcribed → summarizing → done
///                     ↓              ↓             ↓
///                            failed(stage:)
///
/// `transcribed` is the rest state between the two halves and the terminal
/// state of a transcript-only live meeting. Deliberately not `done`:
/// `nota history summarize` refuses a finished record without `--force`, and
/// calling a never-summarized transcript finished would put every live
/// meeting behind that flag.
enum HistoryStatus: Equatable, Hashable {
  case recording
  case transcribing
  case transcribed
  case summarizing
  case done
  case failed(stage: HistoryStage)

  /// Every status, in lifecycle order. Mirrors `HISTORY_STATUSES` in TS.
  static let allCases: [HistoryStatus] =
    [.recording, .transcribing, .transcribed, .summarizing, .done]
    + HistoryStage.allCases.map { .failed(stage: $0) }

  // MARK: - Wire form

  private static let failedPrefix = "failed:"

  /// What goes in the record's `status` field.
  var rawValue: String {
    switch self {
    case .recording: return "recording"
    case .transcribing: return "transcribing"
    case .transcribed: return "transcribed"
    case .summarizing: return "summarizing"
    case .done: return "done"
    case .failed(let stage): return "\(Self.failedPrefix)\(stage.rawValue)"
    }
  }

  init?(rawValue: String) {
    if rawValue.hasPrefix(Self.failedPrefix) {
      let raw = String(rawValue.dropFirst(Self.failedPrefix.count))
      guard let stage = HistoryStage(rawValue: raw) else { return nil }
      self = .failed(stage: stage)
      return
    }
    switch rawValue {
    case "recording": self = .recording
    case "transcribing": self = .transcribing
    case "transcribed": self = .transcribed
    case "summarizing": self = .summarizing
    case "done": self = .done
    default: return nil
    }
  }

  // MARK: - Reading a record

  /// Read a status off a record that may predate this vocabulary.
  ///
  /// Tolerant per the repo's decoding convention (see `DictationSettings.init(from:)`
  /// and `sanitizeCatalog`): a record on disk is never refused for the
  /// vocabulary it was written in. Legacy `"completed"` is `.done`; legacy
  /// `"transcribed"` keeps its name, because it means what it always meant. An
  /// absent or unrecognized value resolves by what the record actually HAS — a
  /// summary means the work finished, no summary means it stopped after
  /// transcription — and never to a live stage, which would make every old
  /// record look interrupted at the next launch.
  static func normalized(_ raw: String?, hasSummary: Bool) -> HistoryStatus {
    if let raw {
      if let known = HistoryStatus(rawValue: raw) { return known }
      if raw == "completed" { return .done }
    }
    return hasSummary ? .done : .transcribed
  }

  /// Read a status straight off a decoded record dictionary.
  static func normalized(fromRecord json: [String: Any]) -> HistoryStatus {
    normalized(json["status"] as? String, hasSummary: json["summary"] != nil)
  }

  // MARK: - The machine

  /// True while a process is supposed to be working on this record. A record
  /// found in one of these at launch with nothing behind it was interrupted.
  var isInFlight: Bool {
    switch self {
    case .recording, .transcribing, .summarizing: return true
    case .transcribed, .done, .failed: return false
    }
  }

  /// True when nothing more will happen to this record on its own.
  var isTerminal: Bool {
    switch self {
    case .done, .failed: return true
    case .recording, .transcribing, .transcribed, .summarizing: return false
    }
  }

  /// The stage a failure happened in; nil for every non-failure status.
  var failureStage: HistoryStage? {
    if case .failed(let stage) = self { return stage }
    return nil
  }

  /// The status an interrupted record resolves to: the failure of whatever
  /// stage it was in the middle of. A record that had already come to rest was
  /// not interrupted by the process going away, so it resolves to nothing.
  var interruptedResolution: HistoryStatus? {
    switch self {
    case .recording: return .failed(stage: .recording)
    case .transcribing: return .failed(stage: .transcribing)
    case .summarizing: return .failed(stage: .summarizing)
    case .transcribed, .done, .failed: return nil
    }
  }

  /// Whether `next` is a legal successor. Terminal statuses accept nothing;
  /// every working status may fail, but only in the stage it is in.
  func canAdvance(to next: HistoryStatus) -> Bool {
    if isTerminal { return false }
    if self == next { return false }
    if let stage = next.failureStage {
      // The rest state fails as the summary it was waiting for.
      if self == .transcribed { return stage == .summarizing }
      switch self {
      case .recording: return stage == .recording
      case .transcribing: return stage == .transcribing
      case .summarizing: return stage == .summarizing
      default: return false
      }
    }
    switch self {
    case .recording: return next == .transcribing
    case .transcribing: return next == .transcribed || next == .summarizing
    case .transcribed: return next == .summarizing
    case .summarizing: return next == .done
    default: return false
    }
  }

  // MARK: - Presentation

  /// The one place a lifecycle status becomes words on screen. `interrupted`
  /// is the record's own flag, written by the launch sweep: a failure that
  /// happened because the process went away reads as "Interrupted" rather
  /// than naming a stage that never got the chance to fail on its own.
  func presentation(interrupted: Bool = false) -> String {
    if let stage = failureStage {
      if interrupted { return "Interrupted" }
      return "Failed (\(stage.rawValue))"
    }
    switch self {
    case .recording: return "Recording"
    case .transcribing: return "Transcribing"
    case .transcribed: return "Transcribed"
    case .summarizing: return "Summarizing"
    case .done: return "Done"
    case .failed: return "Failed"
    }
  }
}
