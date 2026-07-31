import CoreGraphics
import ScreenCaptureKit
import Vision

// MARK: - ScreenContextCapture

/// One-shot, opt-in visual context for dictation cleanup.
///
/// Accessibility text is preferred because it is narrower and does not require
/// Screen Recording. This fallback is called only after a user-initiated
/// dictation has finished and only captures the one window belonging to the
/// session's target process. The image is held in memory for OCR and is never
/// written to disk, added to history, or logged.
enum ScreenContextCapture {
  static let maxOCRTextLength = 2_000
  static let minimumFocusedTextLength = 24

  /// A short AX result may be a label or a single control value rather than the
  /// surrounding editor text. In that case the user may explicitly opt into a
  /// window screenshot fallback.
  static func shouldUseVisualFallback(focusedText: String?) -> Bool {
    guard let text = ContextSnapshot.boundedFocusedText(focusedText),
          text.count >= minimumFocusedTextLength
    else { return true }
    return false
  }

  /// Capture and OCR one on-screen window. Every failure, including missing
  /// Screen Recording permission, returns nil so normal cleanup continues.
  static func captureVisibleText(
    processID: pid_t?,
    windowTitle: String? = nil
  ) async -> String? {
    guard let processID else { return nil }

    // Do not prompt merely because the setting is present. This method is only
    // reached when the user enabled the fallback and focused AX text was absent
    // or too short, so this is the first point at which permission is needed.
    let hasPermission = await MainActor.run {
      CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    }
    guard hasPermission else { return nil }

    do {
      let content = try await SCShareableContent.excludingDesktopWindows(
        true,
        onScreenWindowsOnly: true
      )
      let candidates = content.windows.filter {
        $0.owningApplication?.processID == processID &&
          $0.isOnScreen &&
          $0.frame.width > 1 &&
          $0.frame.height > 1
      }
      guard let window = candidates.sorted(by: { lhs, rhs in
        windowScore(lhs, title: windowTitle) > windowScore(rhs, title: windowTitle)
      }).first else { return nil }

      let filter = SCContentFilter(desktopIndependentWindow: window)
      let configuration = SCStreamConfiguration()
      let scale: CGFloat = 2
      let width = max(1, min(2_400, Int(window.frame.width * scale)))
      let height = max(1, min(1_600, Int(window.frame.height * scale)))
      configuration.width = width
      configuration.height = height
      configuration.scalesToFit = true
      configuration.showsCursor = false

      let image = try await SCScreenshotManager.captureImage(
        contentFilter: filter,
        configuration: configuration
      )
      return recognizeText(in: image)
    } catch {
      // TCC denials, protected windows, and apps that disappear during the
      // handoff are all ordinary no-context cases.
      return nil
    }
  }

  private static func windowScore(_ window: SCWindow, title: String?) -> Int {
    let titleMatch = title != nil && window.title == title
    return (titleMatch ? 4 : 0) + (window.isActive ? 2 : 0)
  }

  /// Pure OCR-result assembly, kept internal for boundedness/redaction tests.
  static func boundedOCRText(_ lines: [String]) -> String? {
    let safeLines = lines.compactMap { line -> String? in
      let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalized.isEmpty, !looksSensitive(normalized) else { return nil }
      return normalized
    }
    guard !safeLines.isEmpty else { return nil }

    let joined = safeLines.joined(separator: "\n")
    guard joined.count > maxOCRTextLength else { return joined }
    return String(joined.prefix(maxOCRTextLength - 1)) + "…"
  }

  private static func recognizeText(in image: CGImage) -> String? {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.automaticallyDetectsLanguage = true
    request.minimumTextHeight = 0.01

    do {
      let handler = VNImageRequestHandler(cgImage: image, options: [:])
      try handler.perform([request])
    } catch {
      return nil
    }

    let lines = request.results?.compactMap { observation in
      observation.topCandidates(1).first?.string
    } ?? []
    return boundedOCRText(lines)
  }

  private static func looksSensitive(_ line: String) -> Bool {
    let lowercased = line.lowercased()
    let markers = [
      "password", "passcode", "secret", "private key", "api key", "access token",
      "auth token", "security code", "credit card", "cvv", "credential",
    ]
    return markers.contains { lowercased.contains($0) }
  }
}
