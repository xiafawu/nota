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
  /// Compute the HUD visual state from the current controller snapshot.
  ///
  /// Warning precedence:
  ///   1. `lastPolishWarning` (stale until next session clears it)
  ///   2. `lastSecureFieldNotice` (stale until next injection)
  ///   3. `lastProcessedText` → success snippet (auto-hide after ~1s)
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
