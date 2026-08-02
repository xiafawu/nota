import SwiftUI

/// Semantic health colors — the macOS traffic-light hues repurposed as a status
/// signal (distinct from the window controls). Each maps to one check status.
private enum HealthColor {
  static let green = Color(red: 0.157, green: 0.784, blue: 0.251)  // #28C840
  static let red   = Color(red: 1.0, green: 0.373, blue: 0.341)    // #FF5F57
  static let amber = Color(red: 0.996, green: 0.737, blue: 0.180)  // #FEBC2E
  static let grey  = Color.secondary.opacity(0.55)

  static func of(_ status: PreflightStatus) -> Color {
    switch status {
    case .ok: return green
    case .fail: return red
    case .unverified: return amber
    case .optional: return grey
    }
  }
}

/// The Nota home when no document is open: a preflight health dashboard. One
/// hero dot gives the verdict; the hero itself is the record entry — clicking
/// it starts a live meeting whenever the verdict allows recording. Checks that
/// need attention are shown (expandable), and passing checks fold under a
/// single line. Replaces the bare drop target.
struct PreflightHomeView: View {
  let result: PreflightResult?
  let isChecking: Bool
  let onRefresh: () -> Void
  /// Starts a live meeting. The hero is the single record entry (ADR 0004);
  /// it is inert unless the verdict is `.ready` or `.unverified`.
  var onStartRecording: () -> Void = {}
  /// True when hosted inside another scroll container (the dashboard home).
  /// Nesting two vertical ScrollViews clips the inner content under the
  /// window toolbar, so embedded mode renders the bare section and leaves
  /// scrolling and padding to the host.
  var embedded: Bool = false

  @State private var passingExpanded = false

  var body: some View {
    if embedded {
      sections
    } else {
      ScrollView {
        sections
          .padding(24)
          .frame(maxWidth: 620, alignment: .leading)
          .frame(maxWidth: .infinity)
      }
    }
  }

  private var sections: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      if let result {
        ForEach(result.attention) { check in
          AttentionRow(check: check)
        }
        if !result.passing.isEmpty {
          passingFold(result.passing)
        }
      } else {
        placeholder
      }
    }
  }

  // MARK: hero

  private var header: some View {
    HStack(spacing: 14) {
      Button(action: onStartRecording) {
        HStack(spacing: 14) {
          heroDot
          VStack(alignment: .leading, spacing: 2) {
            Text(verdictTitle)
              .font(.title3.weight(.bold))
            Text(verdictSubtitle)
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!canStartRecording)
      .help(recordHelp)

      Spacer(minLength: 8)
      Button(action: onRefresh) {
        if isChecking {
          ProgressView().controlSize(.small)
        } else {
          Label("Re-check", systemImage: "arrow.clockwise")
            .labelStyle(.iconOnly)
        }
      }
      .liquidGlassButton()
      .disabled(isChecking)
      .help("Run the checks again")
    }
    .padding(16)
    .liquidGlass(.regular, in: RoundedRectangle(cornerRadius: 12))
  }

  /// The hero starts a recording only when the preflight verdict allows one:
  /// `.ready` and `.unverified` ("you can record, but a run may fail"); a
  /// `.blocked` verdict renders the hero inert and points at the failing
  /// check below instead (ADR 0004).
  static func canStartRecording(_ overall: PreflightOverall?) -> Bool {
    guard let overall else { return false }
    return overall == .ready || overall == .unverified
  }

  private var canStartRecording: Bool {
    Self.canStartRecording(result?.overall)
  }

  private var recordHelp: String {
    switch result?.overall {
    case .ready: return "Start a live recording"
    case .unverified: return "Start a live recording — one check could not be verified"
    case .blocked: return "Fix the failing check below before recording"
    case .none: return ""
    }
  }

  @ViewBuilder private var heroDot: some View {
    let color = heroColor
    Circle()
      .fill(color)
      .frame(width: 20, height: 20)
      .overlay(Circle().fill(color.opacity(0.22)).frame(width: 32, height: 32))
  }

  private var heroColor: Color {
    switch result?.overall {
    case .ready: return HealthColor.green
    case .blocked: return HealthColor.red
    case .unverified: return HealthColor.amber
    case .none: return HealthColor.grey
    }
  }

  private var verdictTitle: String {
    switch result?.overall {
    case .ready: return "Ready to record"
    case .blocked:
      let n = result?.attention.filter { $0.status == .fail }.count ?? 0
      return n == 1 ? "1 issue to fix" : "\(n) issues to fix"
    case .unverified: return "Couldn't verify everything"
    case .none: return isChecking ? "Checking…" : "Not checked yet"
    }
  }

  private var verdictSubtitle: String {
    switch result?.overall {
    case .ready: return "All checks passed. Drop an audio file or start recording."
    case .blocked: return "Fix the failing check below before recording."
    case .unverified: return "You can record, but a run may fail."
    case .none: return isChecking ? "Running readiness checks." : "Run the checks to see readiness."
    }
  }

  // MARK: passing fold

  private func passingFold(_ passing: [PreflightCheck]) -> some View {
    VStack(spacing: 0) {
      Button {
        withAnimation(.easeInOut(duration: 0.2)) { passingExpanded.toggle() }
      } label: {
        HStack(spacing: 12) {
          Circle().fill(HealthColor.green).frame(width: 11, height: 11)
          Text("\(passing.count) \(passing.count == 1 ? "check" : "checks") passing")
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
          Spacer()
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(passingExpanded ? 90 : 0))
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
      }
      .buttonStyle(.plain)

      if passingExpanded {
        ForEach(passing) { check in
          Divider().padding(.leading, 15)
          HStack(spacing: 12) {
            Circle().fill(HealthColor.of(check.status)).frame(width: 11, height: 11)
            Text(check.label).font(.callout)
            Spacer()
            Text(check.status == .optional ? "Optional" : "Ready")
              .font(.caption).foregroundStyle(.secondary)
          }
          .padding(.horizontal, 15)
          .padding(.vertical, 11)
        }
      }
    }
    .liquidGlass(.regular, in: RoundedRectangle(cornerRadius: 11))
  }

  private var placeholder: some View {
    HStack {
      Spacer()
      VStack(spacing: 10) {
        Image(systemName: "checklist")
          .font(.system(size: 34))
          .foregroundStyle(.secondary)
        Text("Run a readiness check")
          .font(.callout).foregroundStyle(.secondary)
      }
      .padding(.vertical, 30)
      Spacer()
    }
  }
}

/// A red/yellow check shown above the fold: dot, label, expandable detail.
private struct AttentionRow: View {
  let check: PreflightCheck
  @State private var expanded = true

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
      } label: {
        HStack(spacing: 12) {
          Circle().fill(HealthColor.of(check.status)).frame(width: 11, height: 11)
          Text(check.label).font(.callout.weight(.medium))
          Spacer()
          Text(check.status == .fail ? "Needs fixing" : "Couldn't verify")
            .font(.caption.weight(.semibold))
            .foregroundStyle(check.status == .fail ? HealthColor.red : HealthColor.amber)
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
      }
      .buttonStyle(.plain)

      if expanded {
        Text(check.detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 15)
          .padding(.leading, 23)
          .padding(.bottom, 14)
      }
    }
    .liquidGlass(.regular, in: RoundedRectangle(cornerRadius: 11))
  }
}

#if DEBUG
#Preview("issue") {
  PreflightHomeView(
    result: PreflightResult(
      overall: .blocked,
      checks: [
        PreflightCheck(id: "audio-tools", label: "Audio tools", status: .ok, detail: "ffmpeg and ffprobe found on PATH", blocking: true, httpStatus: nil),
        PreflightCheck(id: "transcription", label: "Transcription — AssemblyAI", status: .ok, detail: "API key verified — no charge", blocking: true, httpStatus: nil),
        PreflightCheck(id: "summary", label: "Summary — GPT-5 mini", status: .fail, detail: "400 · Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.", blocking: true, httpStatus: 400),
        PreflightCheck(id: "identity", label: "Speaker identity", status: .optional, detail: "Optional — voice model not downloaded", blocking: false, httpStatus: nil),
      ],
      checkedAt: "2026-07-14T18:24:00Z"
    ),
    isChecking: false,
    onRefresh: {}
  )
  .frame(width: 720, height: 540)
}

#Preview("ready") {
  PreflightHomeView(
    result: PreflightResult(
      overall: .ready,
      checks: [
        PreflightCheck(id: "audio-tools", label: "Audio tools", status: .ok, detail: "ok", blocking: true, httpStatus: nil),
        PreflightCheck(id: "transcription", label: "Transcription — AssemblyAI", status: .ok, detail: "ok", blocking: true, httpStatus: nil),
        PreflightCheck(id: "summary", label: "Summary — GPT-5 mini", status: .ok, detail: "ok", blocking: true, httpStatus: nil),
        PreflightCheck(id: "identity", label: "Speaker identity", status: .ok, detail: "on", blocking: false, httpStatus: nil),
      ],
      checkedAt: "2026-07-14T18:24:00Z"
    ),
    isChecking: false,
    onRefresh: {}
  )
  .frame(width: 720, height: 540)
}
#endif
