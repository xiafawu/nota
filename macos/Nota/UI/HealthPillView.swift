import SwiftUI

/// The quiet toolbar health pill (XIA-394): green "Ready" / red "N issues"
/// fed by the preflight model. Clicking opens a glass popover with one row per
/// check (pass/fail dots), Retry, and Open Settings. This replaces the
/// `HomeReadyPill` stub (XIA-399).
struct HealthPillView: View {
  let result: PreflightResult?
  let isChecking: Bool
  let onRefresh: () -> Void
  /// Shared with the home cards: a gated card click opens this same popover.
  @Binding var isPresented: Bool

  private var state: HealthPillState {
    HealthPillState.make(result: result)
  }

  var body: some View {
    Button {
      isPresented = true
    } label: {
      pillLabel
    }
    .buttonStyle(.plain)
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      HealthPopoverContent(
        result: result,
        isChecking: isChecking,
        onRefresh: onRefresh
      )
    }
  }

  @ViewBuilder
  private var pillLabel: some View {
    HStack(spacing: Metrics.statusHStackSpacing) {
      if isChecking && result == nil {
        ProgressView()
          .controlSize(.small)
      } else {
        Circle()
          .fill(dotColor)
          .frame(width: 7, height: 7)
      }
      Text(pillText)
        .font(Tokens.statusFont)
    }
    .padding(.horizontal, Metrics.statusPillH)
    .padding(.vertical, Metrics.statusPillV)
    .liquidGlass(.regular, in: .capsule)
    .help(helpText)
  }

  private var pillText: String {
    switch state {
    case .notChecked: return isChecking ? "Checking…" : "Not checked"
    case .ready: return "Ready"
    case .issues(let count, _): return "\(count) issue\(count == 1 ? "" : "s")"
    }
  }

  private var dotColor: Color {
    switch state {
    case .notChecked: return .gray
    case .ready: return .green
    case .issues(_, let hasFail): return hasFail ? .red : .yellow
    }
  }

  private var helpText: String {
    switch state {
    case .ready: return "All systems ready"
    case .notChecked: return "Readiness not checked"
    case .issues: return "Some checks need attention"
    }
  }
}

// MARK: - Popover

private struct HealthPopoverContent: View {
  let result: PreflightResult?
  let isChecking: Bool
  let onRefresh: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Readiness")
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        Button(action: onRefresh) {
          Label("Retry", systemImage: "arrow.clockwise")
            .font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .disabled(isChecking)
      }
      .padding(.bottom, CraftTokens.spacing8)

      if isChecking && result == nil {
        HStack(spacing: 6) {
          ProgressView()
            .controlSize(.small)
          Text("Checking…")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
      } else if let result {
        // Attention first (red/yellow), passing under the fold (green/grey).
        let attention = result.attention
        let passing = result.passing
        ForEach(attention + passing, id: \.id) { check in
          checkRow(check)
        }
      } else {
        Text("Could not run the readiness check.")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }

      Divider()
        .padding(.vertical, CraftTokens.spacing8)

      SettingsLink {
        HStack(spacing: 4) {
          Image(systemName: "gearshape")
            .font(.system(size: 11))
          Text("Open Settings")
            .font(.system(size: 12))
        }
        .foregroundStyle(Color.accentColor)
      }
    }
    .padding(CraftTokens.spacing16)
    .frame(width: 300)
  }

  private func checkRow(_ check: PreflightCheck) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: CraftTokens.spacing8) {
      Circle()
        .fill(statusColor(check.status))
        .frame(width: 7, height: 7)
        .alignmentGuide(.firstTextBaseline) { d in d[.top] + 4 }

      VStack(alignment: .leading, spacing: 2) {
        Text(check.label)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.primary)
        Text(check.detail)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 3)
  }

  private func statusColor(_ status: PreflightStatus) -> Color {
    switch status {
    case .ok: return .green
    case .fail: return .red
    case .unverified: return .yellow
    case .optional: return .gray
    }
  }
}

#if DEBUG
#Preview("ready") {
  HealthPillView(
    result: PreflightResult(
      overall: .ready,
      checks: [
        PreflightCheck(id: "audio-tools", label: "Audio tools", status: .ok, detail: "ffmpeg found", blocking: true, httpStatus: nil),
        PreflightCheck(id: "transcription", label: "Transcription", status: .ok, detail: "key verified", blocking: true, httpStatus: nil)
      ],
      checkedAt: ""
    ),
    isChecking: false,
    onRefresh: {},
    isPresented: .constant(false)
  )
  .padding()
}
#endif
