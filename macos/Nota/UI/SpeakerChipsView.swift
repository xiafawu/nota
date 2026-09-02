import SwiftUI

// MARK: - Chip indicator state

/// Maps an `EnrollResult` (or in-progress / pending) to a visual indicator.
enum ChipIndicator: Equatable {
  case none          // no name assigned yet
  case pending       // name typed but enroll job queued / not started
  case enrolling     // enroll job in flight
  case enrolled      // success
  case skipped(reason: String)   // amber — sidecar written but no voiceprint
  case failed(stderr: String)    // red — extraction crashed

  var color: Color {
    switch self {
    case .none:                 return .clear
    case .pending, .enrolling:  return .accentColor
    case .enrolled:             return .green
    case .skipped:              return .yellow
    case .failed:               return .red
    }
  }

  var tooltip: String? {
    switch self {
    case .skipped(let reason): return reason
    case .failed(let stderr):  return stderr.isEmpty ? "enroll failed" : stderr
    default:                   return nil
    }
  }
}

// MARK: - Per-chip model

struct SpeakerChip: Identifiable, Equatable {
  /// The original label as parsed from the body (e.g. "Speaker 1").
  let label: String
  /// Current display name (empty = not yet mapped).
  var name: String
  var indicator: ChipIndicator
  /// A pending tentative suggestion for this label ("Speaker 2 → Kenny Kim?
  /// 0.62") — nil when the record has none (or it was decided). Set by
  /// `NotaModel` from the open record's `suggestions`.
  var suggestion: SpeakerSuggestion? = nil

  var id: String { label }

  /// True when the label is a diarizer placeholder ("Speaker 3") rather than
  /// a person's name an identify pass already resolved at run time. A chip
  /// whose label IS a name must not render as unnamed — the body carries
  /// "Freya Wu", not "Speaker 2", and dashing it says "needs a name" about a
  /// speaker who has one (owner report 2026-08-04).
  var hasGenericLabel: Bool { Self.isGenericLabel(label) }

  static func isGenericLabel(_ label: String) -> Bool {
    label.range(of: #"^Speaker \d+$"#, options: .regularExpression) != nil
  }

  var displayText: String {
    if name.isEmpty { return "\(label) → ?" }
    if name == label { return name }
    return "\(label) → \(name)"
  }
}
