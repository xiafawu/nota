import Foundation

// MARK: - HUDState

/// Pure view-model mapping `DictationController` state to HUD display state.
/// Unit-testable without AppKit.
enum HUDState: Equatable {
  case hidden
  /// Microphone active with live RMS level (0…1 normalized).
  case listening(level: Float)
  /// Post-capture processing step.
  case processing(step: String)
  /// Injection succeeded; show the injected snippet briefly.
  case success(snippet: String)
  /// Non-fatal warning (polish failure, secure-field refusal).
  case warning(message: String)
  /// Fatal error message.
  case error(message: String)
}

extension HUDState {
  /// Seconds the HUD stays visible before auto-hiding, or nil to persist.
  /// Success lingers long enough to read the snippet; fatal errors outlast
  /// warnings so the user can act on them.
  var autoHideDelay: TimeInterval? {
    switch self {
    case .success: return 2.0
    case .warning: return 3.0
    case .error: return 6.0
    case .hidden, .listening, .processing: return nil
    }
  }

  /// Compute the HUD visual state from the current controller snapshot.
  ///
  /// Warning precedence:
  ///   1. `lastPolishWarning`
  ///   2. `lastSecureFieldNotice`
  ///   3. `lastProcessedText` → success snippet
  ///
  /// The controller fields stay set while idle; `DictationHUDController`
  /// marks the shown state consumed when its auto-hide fires so a later
  /// unrelated update cannot resurrect a stale notice.
  static func compute(
    controllerState: DictationState,
    isPolishInProgress: Bool,
    lastPolishWarning: String?,
    lastSecureFieldNotice: String?,
    lastProcessedText: String?,
    rmsLevel: Float
  ) -> HUDState {
    switch controllerState {
    case .disabled:
      return .hidden

    case .idle:
      // Warning precedence: polish warning > secure-field notice > processed text snippet
      if let warning = lastPolishWarning, !warning.isEmpty {
        return .warning(message: warning)
      }
      if let notice = lastSecureFieldNotice, !notice.isEmpty {
        return .warning(message: notice)
      }
      if let snippet = lastProcessedText, !snippet.isEmpty {
        return .success(snippet: snippet)
      }
      return .hidden

    case .listening:
      return .listening(level: rmsLevel)

    case .finalizing:
      if isPolishInProgress {
        return .processing(step: "Polishing…")
      }
      return .processing(step: "Transcribing…")

    case .injecting:
      return .processing(step: "Injecting…")

    case .failed(let message):
      return .error(message: message)
    }
  }
}
