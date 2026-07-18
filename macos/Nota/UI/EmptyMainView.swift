import SwiftUI

/// The pipeline's ordered stages as shown by the running view. Phase labels
/// must match `NotaModel.phaseLabel` — the model only hands the view the label
/// string, so the mapping back to a stage index lives here.
enum RunStages {
  static let names = ["Validate", "Transcribe", "Summarize", "Write"]
  static let phaseLabels = ["Validating…", "Transcribing…", "Summarizing…", "Writing…"]

  /// Index of the active stage for a phase label; nil while preparing (before
  /// the first stage marker) or when the label is unknown.
  static func index(forPhase phase: String) -> Int? {
    phaseLabels.firstIndex(of: phase)
  }
}

struct EmptyMainView: View {
  let state: EmptyMainState
  let isDropTargeted: Bool

  private var stageIndex: Int? {
    RunStages.index(forPhase: state.phase)
  }

  var body: some View {
    VStack(spacing: Metrics.emptyMainSpacing) {
      Spacer()

      Image(systemName: state.isRunning ? "waveform" : "tray.and.arrow.down")
        .font(Tokens.emptyMainIconFont)
        .foregroundStyle(isDropTargeted ? Tokens.dropAccent : Tokens.emptyIconColor)
        .symbolEffect(.pulse, isActive: state.isRunning)

      VStack(spacing: Metrics.emptyTextSpacing) {
        Text(state.displayName)
          .font(Tokens.emptyMainTitleFont)
          .fontWeight(.bold)
          .foregroundStyle(.primary)
          .multilineTextAlignment(.center)

        if state.isRunning {
          // Staged progress replaces the indeterminate bar; the toolbar pill
          // carries the live phase text, so it is not repeated here. The raw
          // file path (a synthetic staging path for shared files) is never shown.
          stageRow
            .padding(.top, Metrics.emptyTextSpacing)
        } else {
          Text(state.displayPath)
            .font(Tokens.emptyMainPathFont)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Metrics.emptySubtextHorizontalPadding)
        }
      }

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(Metrics.emptyMainOuterPadding)
  }

  // MARK: - Staged progress

  private var stageRow: some View {
    HStack(spacing: Metrics.stageRowSpacing) {
      ForEach(RunStages.names.indices, id: \.self) { index in
        HStack(spacing: Metrics.stageItemSpacing) {
          stageIndicator(for: index)
          Text(RunStages.names[index])
            .font(.caption)
            .fontWeight(index == stageIndex ? .medium : .regular)
            .foregroundStyle(stageTextStyle(for: index))
        }
      }
    }
    .animation(Tokens.animFast, value: stageIndex)
  }

  @ViewBuilder
  private func stageIndicator(for index: Int) -> some View {
    if let current = stageIndex, index < current {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: Metrics.stageIndicatorSize - 1))
        .foregroundStyle(Color.accentColor)
        .transition(.opacity.combined(with: .scale))
    } else if index == stageIndex {
      ProgressView()
        .controlSize(.mini)
        .frame(width: Metrics.stageIndicatorSize, height: Metrics.stageIndicatorSize)
        .transition(.opacity)
    } else {
      Image(systemName: "circle")
        .font(.system(size: Metrics.stageIndicatorSize - 1))
        .foregroundStyle(.tertiary)
        .transition(.opacity)
    }
  }

  private func stageTextStyle(for index: Int) -> HierarchicalShapeStyle {
    guard let current = stageIndex else { return .tertiary }
    if index == current { return .primary }
    return index < current ? .secondary : .tertiary
  }
}

#if DEBUG
#Preview("idle") {
  EmptyMainView(state: PreviewMocks.emptyMainIdle, isDropTargeted: false)
    .frame(width: 720, height: 540)
}

#Preview("targeted") {
  EmptyMainView(state: PreviewMocks.emptyMainIdle, isDropTargeted: true)
    .frame(width: 720, height: 540)
}

#Preview("running") {
  EmptyMainView(state: PreviewMocks.emptyMainRunning, isDropTargeted: false)
    .frame(width: 720, height: 540)
}
#endif
