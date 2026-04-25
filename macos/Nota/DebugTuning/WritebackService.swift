#if DEBUG
import Foundation

struct WritebackService {
  let projectDirectory: URL

  static func defaultProjectDirectory() -> URL {
    URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["NOTA_PROJECT_DIR"]
        ?? "/Users/xiafawu/Developer/Nota"
    )
  }

  @MainActor
  func apply(store: TuningStore) throws -> [URL] {
    let metricsURL = projectDirectory.appendingPathComponent("macos/Nota/Tokens/Metrics.swift")
    let tokensURL = projectDirectory.appendingPathComponent("macos/Nota/Tokens/Tokens.swift")

    let metricsUpdates: [(String, Double)] = [
      ("statusPillH", Double(store.statusPillH)),
      ("statusPillV", Double(store.statusPillV)),
      ("statusHStackSpacing", Double(store.statusHStackSpacing)),
      ("newButtonH", Double(store.newButtonH)),
      ("newButtonV", Double(store.newButtonV)),
      ("newButtonStackSpacing", Double(store.newButtonStackSpacing)),
      ("primaryActionCornerRadius", Double(store.primaryActionCornerRadius)),
      ("dropCornerRadius", Double(store.dropCornerRadius)),
      ("dropTargetStrokeWidth", Double(store.dropTargetStrokeWidth)),
      ("dropStrokeIdle", Double(store.dropStrokeIdle)),
      ("dropStrokeActive", Double(store.dropStrokeActive)),
      ("emptyMainSpacing", Double(store.emptyMainSpacing)),
      ("emptyMainOuterPadding", Double(store.emptyMainOuterPadding)),
      ("emptyTextSpacing", Double(store.emptyTextSpacing)),
      ("emptySubtextHorizontalPadding", Double(store.emptySubtextHorizontalPadding))
    ]

    let tokensUpdates: [(String, Double)] = [
      ("toolbarStatusTintOpacity", store.toolbarStatusTintOpacity),
      ("primaryActionTintOpacity", store.primaryActionTintOpacity)
    ]

    var updated: [URL] = []
    if try writeUpdates(at: metricsURL, type: "CGFloat", updates: metricsUpdates) {
      updated.append(metricsURL)
    }
    if try writeUpdates(at: tokensURL, type: "Double", updates: tokensUpdates) {
      updated.append(tokensURL)
    }
    return updated
  }

  private func writeUpdates(at url: URL, type: String, updates: [(String, Double)]) throws -> Bool {
    let original = try String(contentsOf: url, encoding: .utf8)
    var modified = original

    for (name, value) in updates {
      modified = replaceConstant(in: modified, name: name, type: type, value: value)
    }

    guard modified != original else {
      return false
    }
    try modified.write(to: url, atomically: true, encoding: .utf8)
    return true
  }

  private func replaceConstant(in source: String, name: String, type: String, value: Double) -> String {
    let escapedName = NSRegularExpression.escapedPattern(for: name)
    let escapedType = NSRegularExpression.escapedPattern(for: type)
    let pattern = "(static let \(escapedName)\\s*:\\s*\(escapedType)\\s*=\\s*)([^\\s\\n]+)"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else {
      return source
    }
    let formatted = formatValue(value)
    let range = NSRange(source.startIndex..., in: source)
    return regex.stringByReplacingMatches(in: source, range: range, withTemplate: "$1\(formatted)")
  }

  private func formatValue(_ value: Double) -> String {
    if value.truncatingRemainder(dividingBy: 1) == 0 {
      return String(Int(value))
    }
    let formatter = NumberFormatter()
    formatter.minimumFractionDigits = 1
    formatter.maximumFractionDigits = 4
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.usesGroupingSeparator = false
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
  }
}
#endif
