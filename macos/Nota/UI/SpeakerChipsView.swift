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

  var displayText: String {
    if name.isEmpty { return "\(label) → ?" }
    if name == label { return name }
    return "\(label) → \(name)"
  }
}

// MARK: - View

/// A horizontal (wrapping) strip of chips, one per speaker label discovered
/// in the document body. Each chip shows `<label> → <name>` (or `?` when
/// unmapped). Clicking a chip reveals an inline text field for renaming.
///
/// Injected into `DocumentHeaderView` between the subtitle and tags.
struct SpeakerChipsView: View {
  /// Current chips — caller maintains and drives this binding.
  @Binding var chips: [SpeakerChip]
  /// Called when the user commits a name (may be empty = clear mapping).
  let onRename: (_ label: String, _ newName: String) -> Void

  var body: some View {
    FlowLayout(spacing: Metrics.tagSpacing, lineSpacing: Metrics.tagSpacing) {
      ForEach($chips) { $chip in
        ChipView(chip: $chip, onRename: onRename)
      }
    }
  }
}

// MARK: - Individual chip

private struct ChipView: View {
  @Binding var chip: SpeakerChip
  let onRename: (_ label: String, _ newName: String) -> Void

  @State private var isEditing = false
  @State private var draft = ""
  @FocusState private var fieldFocused: Bool

  var body: some View {
    Group {
      if isEditing {
        editingChip
      } else {
        idleChip
      }
    }
    .animation(Tokens.animSnap, value: isEditing)
  }

  // MARK: Idle state

  private var idleChip: some View {
    Button {
      draft = chip.name
      isEditing = true
      fieldFocused = true
    } label: {
      HStack(spacing: 4) {
        indicatorDot
        Text(chip.displayText)
          .font(Tokens.historyTagFont)
          .foregroundStyle(chip.name.isEmpty ? .tertiary : .secondary)
          .lineLimit(1)
        if chip.indicator == .enrolling {
          ProgressView().controlSize(.mini).scaleEffect(0.7)
        }
      }
      .padding(.horizontal, Metrics.tagPillH)
      .padding(.vertical, Metrics.tagPillV)
    }
    .buttonStyle(.plain)
    .background(Tokens.tagPillFill, in: Capsule())
    .help(chip.indicator.tooltip ?? (chip.name.isEmpty ? "Click to name this speaker" : "Click to rename"))
  }

  @ViewBuilder
  private var indicatorDot: some View {
    switch chip.indicator {
    case .none, .pending:
      EmptyView()
    case .enrolling:
      EmptyView() // spinner shown separately
    case .enrolled:
      Circle().fill(Color.green).frame(width: 6, height: 6)
    case .skipped:
      Circle().fill(Color.yellow).frame(width: 6, height: 6)
    case .failed:
      Circle().fill(Color.red).frame(width: 6, height: 6)
    }
  }

  // MARK: Editing state

  private var editingChip: some View {
    HStack(spacing: 4) {
      Text("\(chip.label) →")
        .font(Tokens.historyTagFont)
        .foregroundStyle(.secondary)

      TextField("Name", text: $draft)
        .font(Tokens.historyTagFont)
        .textFieldStyle(.plain)
        .frame(minWidth: 60, maxWidth: 120)
        .focused($fieldFocused)
        .onSubmit { commitEdit() }
        .onExitCommand { cancelEdit() }
        .onChange(of: fieldFocused) { _, focused in
          if !focused { cancelEdit() }
        }
    }
    .padding(.horizontal, Metrics.tagPillH)
    .padding(.vertical, Metrics.tagPillV)
    .background(
      Capsule().strokeBorder(.secondary.opacity(0.4), lineWidth: 1)
    )
    .onAppear { fieldFocused = true }
  }

  private func commitEdit() {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    isEditing = false
    fieldFocused = false
    // Always call onRename even for empty (= clear mapping)
    onRename(chip.label, trimmed)
  }

  private func cancelEdit() {
    isEditing = false
    fieldFocused = false
  }
}

#if DEBUG
#Preview("chip strip") {
  @Previewable @State var chips: [SpeakerChip] = [
    SpeakerChip(label: "Speaker 1", name: "", indicator: .none),
    SpeakerChip(label: "Speaker 2", name: "Alice", indicator: .enrolled),
    SpeakerChip(label: "Speaker 3", name: "Bob", indicator: .skipped(reason: "audio missing")),
    SpeakerChip(label: "Speaker 4", name: "Carol", indicator: .enrolling),
  ]
  SpeakerChipsView(chips: $chips, onRename: { _, _ in })
    .padding()
    .frame(width: 500)
}
#endif
