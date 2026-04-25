import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let supportedExtensions: Set<String> = [
  "mp3", "wav", "m4a", "aac", "caf", "aif", "aiff", "ogg", "webm", "flac", "qta", "mov", "mp4"
]

@main
struct NotaApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model = NotaModel()

  init() {
    if let exitCode = runHeadlessSmokeTestIfRequested(arguments: Array(ProcessInfo.processInfo.arguments.dropFirst())) {
      exit(exitCode)
    }
  }

  var body: some Scene {
    WindowGroup {
      ContentView(model: model)
        .frame(minWidth: Metrics.windowMinWidth, minHeight: Metrics.windowMinHeight)
        .onOpenURL { url in
          model.accept(url)
        }
        .environmentObject(model)
    }
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("Open Audio...") {
          model.chooseFile()
        }
        .keyboardShortcut("o")

        Button("Transcribe") {
          model.transcribe()
        }
        .keyboardShortcut("t")
        .disabled(model.selectedURL == nil || model.isRunning)
      }
    }

    Settings {
      SettingsView(model: model)
    }
  }
}

struct SettingsView: View {
  @ObservedObject var model: NotaModel

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $model.identifySpeakers) {
          VStack(alignment: .leading, spacing: Metrics.tightStackSpacing) {
            Text("Remember speakers")
            Text("Identify recurring voices across recordings.")
              .font(Tokens.settingsCaptionFont)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: Metrics.settingsWidth, height: Metrics.settingsHeight)
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func application(_ application: NSApplication, open urls: [URL]) {
    NotificationCenter.default.post(name: .notaOpenURLs, object: urls)
  }
}

extension Notification.Name {
  static let notaOpenURLs = Notification.Name("NotaOpenURLs")
}

@MainActor
final class NotaModel: ObservableObject {
  @Published var selectedURL: URL?
  @Published var markdown = ""
  @Published var status = "Drop audio to transcribe"
  @Published var isRunning = false
  @Published var isDropTargeted = false
  @Published var identifySpeakers: Bool = (UserDefaults.standard.object(forKey: "identifySpeakers") as? Bool) ?? true {
    didSet { UserDefaults.standard.set(identifySpeakers, forKey: "identifySpeakers") }
  }
  @Published var lastOutputURL: URL?
  @Published var displayName = "Drop Audio"
  @Published var displayPath = "MP3, M4A, WAV, CAF, QTA, MOV, MP4"
  @Published var history: [HistoryEntry] = []
  @Published var selectedHistoryID: HistoryEntry.ID?

  private let projectDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NOTA_PROJECT_DIR"] ?? "/Users/xiafawu/Developer/Nota")
  private let outputDirectory = notaOutputDirectory()

  var richText: NSAttributedString {
    renderMarkdownAsRichText(markdown)
  }

  var hasContent: Bool {
    !markdown.isEmpty
  }

  init() {
    NotificationCenter.default.addObserver(
      forName: .notaOpenURLs,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard
        let self,
        let urls = notification.object as? [URL],
        let first = urls.first
      else {
        return
      }
      Task { @MainActor in
        self.accept(first)
      }
    }
    refreshHistory()
  }

  func chooseFile() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = [
      .audio,
      .movie,
      UTType(filenameExtension: "qta") ?? .data,
      UTType(filenameExtension: "caf") ?? .audio,
      UTType(filenameExtension: "webm") ?? .movie,
      UTType(filenameExtension: "flac") ?? .audio
    ]

    if panel.runModal() == .OK, let url = panel.url {
      accept(url)
    }
  }

  func accept(_ url: URL) {
    guard isSupportedAudio(url) else {
      status = "Unsupported file type"
      return
    }

    markdown = ""
    lastOutputURL = nil
    displayName = url.lastPathComponent
    displayPath = url.path
    status = "Copying audio..."

    do {
      selectedURL = try makeStableInputCopy(from: url)
      status = url.lastPathComponent
    } catch {
      selectedURL = nil
      markdown = failureMarkdown("Could not copy audio", details: error.localizedDescription)
      status = "Could not copy audio"
      return
    }

    transcribe()
  }

  func transcribe() {
    guard let selectedURL, !isRunning else {
      return
    }

    isRunning = true
    markdown = ""
    lastOutputURL = nil
    status = "Preparing audio..."

    Task {
      do {
        let result = try await runNota(for: selectedURL)
        markdown = result.markdown
        lastOutputURL = result.outputURL
        status = "Complete"
        refreshHistory()
        if let entry = history.first(where: { $0.url.standardizedFileURL == result.outputURL.standardizedFileURL }) {
          selectedHistoryID = entry.id
        }
      } catch {
        markdown = failureMarkdown("Transcription failed", details: error.localizedDescription)
        status = "Transcription failed"
      }
      isRunning = false
    }
  }

  func refreshHistory() {
    let fileManager = FileManager.default
    let contents = (try? fileManager.contentsOfDirectory(
      at: outputDirectory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    )) ?? []

    let entries: [HistoryEntry] = contents.compactMap { url in
      let name = url.lastPathComponent
      guard name.hasSuffix(".summary.md"), !name.hasPrefix(".nota-") else {
        return nil
      }
      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
      let date = values?.contentModificationDate ?? Date.distantPast
      return HistoryEntry(url: url, modifiedAt: date)
    }
    history = entries.sorted { $0.modifiedAt > $1.modifiedAt }
  }

  func openHistory(_ entry: HistoryEntry) {
    guard !isRunning else {
      return
    }
    do {
      markdown = try String(contentsOf: entry.url, encoding: .utf8)
      lastOutputURL = entry.url
      selectedURL = nil
      selectedHistoryID = entry.id
      displayName = entry.title
      displayPath = entry.url.path
      status = entry.title
    } catch {
      status = "Could not open transcript"
    }
  }

  func newTranscription() {
    guard !isRunning else {
      return
    }
    markdown = ""
    lastOutputURL = nil
    selectedURL = nil
    selectedHistoryID = nil
    displayName = "Drop Audio"
    displayPath = "MP3, M4A, WAV, CAF, QTA, MOV, MP4"
    status = "Drop audio to transcribe"
  }

  func deleteHistory(_ entry: HistoryEntry) {
    guard !isRunning else {
      return
    }
    try? FileManager.default.removeItem(at: entry.url)
    if selectedHistoryID == entry.id {
      newTranscription()
    }
    refreshHistory()
  }

  func copyMarkdown() {
    guard !markdown.isEmpty else {
      return
    }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(markdown, forType: .string)
    status = "Copied Markdown"
  }

  func copyRichText() {
    guard !markdown.isEmpty else {
      return
    }

    let attributedText = richText
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    if let data = try? rtfData(from: attributedText) {
      pasteboard.setData(data, forType: .rtf)
    }
    pasteboard.setString(attributedText.string, forType: .string)
    status = "Copied Rich Text"
  }

  func exportMarkdown() {
    guard !markdown.isEmpty else {
      return
    }

    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    panel.nameFieldStringValue = defaultExportName(extensionName: "md")

    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }

    do {
      try markdown.write(to: url, atomically: true, encoding: .utf8)
      status = "Exported Markdown"
    } catch {
      status = "Export failed"
    }
  }

  func exportRichText() {
    guard !markdown.isEmpty else {
      return
    }

    let panel = NSSavePanel()
    panel.allowedContentTypes = [.rtf]
    panel.nameFieldStringValue = defaultExportName(extensionName: "rtf")

    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }

    do {
      try rtfData(from: richText).write(to: url, options: .atomic)
      status = "Exported Rich Text"
    } catch {
      status = "Export failed"
    }
  }

  func revealOutput() {
    guard let lastOutputURL else {
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting([lastOutputURL])
  }

  private func runNota(for url: URL) async throws -> NotaResult {
    try await Task.detached(priority: .userInitiated) { [identifySpeakers, projectDirectory, outputDirectory] in
      let fileManager = FileManager.default
      try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

      let shouldRemoveSharedInput = url.deletingLastPathComponent().standardizedFileURL == outputDirectory.standardizedFileURL
        && (url.lastPathComponent.hasPrefix(".nota-share-") || url.lastPathComponent.hasPrefix(".nota-input-"))

      let timestamp = notaTimestamp()
      let baseName = sanitizedBaseName(url)
      let outputURL = outputDirectory.appendingPathComponent("\(baseName)-\(timestamp).summary.md")
      let runnerURL = projectDirectory
        .appendingPathComponent("scripts", isDirectory: true)
        .appendingPathComponent("nota-app-run.sh")

      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/bash")
      process.currentDirectoryURL = projectDirectory
      var arguments = [runnerURL.path, url.path, outputURL.path, "-v"]
      if identifySpeakers {
        arguments.append("--identify")
      }
      process.arguments = arguments

      let outputPipe = Pipe()
      let errorPipe = Pipe()
      process.standardOutput = outputPipe
      process.standardError = errorPipe

      try process.run()
      process.waitUntilExit()

      let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      let succeeded = process.terminationStatus == 0

      if shouldRemoveSharedInput && succeeded {
        try? fileManager.removeItem(at: url)
      }

      guard succeeded else {
        throw NotaAppError.pipelineFailed(
          process.terminationStatus,
          command: "/bin/bash \(arguments.map(shellQuoted).joined(separator: " "))",
          stdout: stdout,
          stderr: stderr
        )
      }

      let markdown = try String(contentsOf: outputURL, encoding: .utf8)
      return NotaResult(markdown: markdown, outputURL: outputURL)
    }.value
  }

  private func isSupportedAudio(_ url: URL) -> Bool {
    supportedExtensions.contains(url.pathExtension.lowercased())
  }

  private func makeStableInputCopy(from url: URL) throws -> URL {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let extensionName = url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased()
    let destination = outputDirectory.appendingPathComponent(".nota-input-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).\(extensionName)")
    try fileManager.copyItem(at: url, to: destination)
    return destination
  }

  private func defaultExportName(extensionName: String) -> String {
    if let lastOutputURL {
      return "\(lastOutputURL.deletingPathExtension().lastPathComponent).\(extensionName)"
    }

    if let selectedURL {
      return "\(sanitizedBaseName(selectedURL)).summary.\(extensionName)"
    }

    return "nota-summary.\(extensionName)"
  }

}

private struct NotaResult {
  let markdown: String
  let outputURL: URL
}

struct HistoryEntry: Identifiable, Hashable {
  let url: URL
  let modifiedAt: Date

  var id: URL { url }

  var title: String {
    let base = url.deletingPathExtension().lastPathComponent
    let stripped = base.hasSuffix(".summary") ? String(base.dropLast(".summary".count)) : base
    if let dashRange = stripped.range(of: "-", options: .backwards),
       let _ = Int(stripped[dashRange.upperBound...].prefix(8)) {
      let prefix = stripped[..<dashRange.lowerBound]
      if !prefix.isEmpty {
        return String(prefix)
      }
    }
    return stripped
  }

  var relativeDate: String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: modifiedAt, relativeTo: Date())
  }
}

private enum NotaAppError: LocalizedError {
  case pipelineFailed(Int32, command: String, stdout: String, stderr: String)

  var errorDescription: String? {
    switch self {
    case .pipelineFailed(let status, let command, let stdout, let stderr):
      let detail = stderr.isEmpty ? stdout : stderr
      let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        return "Transcription failed with exit code \(status)\n\nCommand:\n\(command)"
      }
      return "\(trimmed)\n\nCommand:\n\(command)"
    }
  }
}

private func sanitizedBaseName(_ url: URL) -> String {
  let raw = url.deletingPathExtension().lastPathComponent
  let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
  let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
  let value = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  return value.isEmpty ? "recording" : value
}

private func notaTimestamp() -> String {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.dateFormat = "yyyyMMdd-HHmmss"
  return formatter.string(from: Date())
}

private func notaOutputDirectory() -> URL {
  if let override = ProcessInfo.processInfo.environment["NOTA_OUTPUT_DIR"], !override.isEmpty {
    return URL(fileURLWithPath: override, isDirectory: true)
  }

  return FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Documents", isDirectory: true)
    .appendingPathComponent("Nota", isDirectory: true)
}

private func shellQuoted(_ value: String) -> String {
  "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private func failureMarkdown(_ title: String, details: String) -> String {
  let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
  return """
  # \(title)

  ```text
  \(trimmed.isEmpty ? "No error detail was reported." : trimmed)
  ```
  """
}

private func runHeadlessSmokeTestIfRequested(arguments: [String]) -> Int32? {
  guard
    let inputFlagIndex = arguments.firstIndex(of: "--smoke-test"),
    arguments.indices.contains(inputFlagIndex + 1)
  else {
    return nil
  }

  let inputURL = URL(fileURLWithPath: arguments[inputFlagIndex + 1])
  let outputURL: URL
  if
    let outputFlagIndex = arguments.firstIndex(of: "--smoke-output"),
    arguments.indices.contains(outputFlagIndex + 1)
  {
    outputURL = URL(fileURLWithPath: arguments[outputFlagIndex + 1])
  } else {
    outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("nota-app-smoke-\(UUID().uuidString).summary.md")
  }

  do {
    try runHeadlessSmokeTest(inputURL: inputURL, outputURL: outputURL)
    print("nota-app-smoke: ok output=\(outputURL.path)")
    return 0
  } catch {
    writeStandardError("nota-app-smoke: \(error.localizedDescription)\n")
    return 1
  }
}

private func runHeadlessSmokeTest(inputURL: URL, outputURL: URL) throws {
  guard supportedExtensions.contains(inputURL.pathExtension.lowercased()) else {
    throw NotaSmokeError.unsupportedInput(inputURL.pathExtension)
  }

  let fileManager = FileManager.default
  let projectDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NOTA_PROJECT_DIR"] ?? "/Users/xiafawu/Developer/Nota")
  let outputDirectory = notaOutputDirectory()
  try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
  try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

  let extensionName = inputURL.pathExtension.isEmpty ? "m4a" : inputURL.pathExtension.lowercased()
  let stableInputURL = outputDirectory.appendingPathComponent(".nota-smoke-input-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).\(extensionName)")
  try fileManager.copyItem(at: inputURL, to: stableInputURL)
  defer {
    try? fileManager.removeItem(at: stableInputURL)
  }

  let runnerURL = projectDirectory
    .appendingPathComponent("scripts", isDirectory: true)
    .appendingPathComponent("nota-app-run.sh")

  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/bash")
  process.currentDirectoryURL = projectDirectory
  let arguments = [runnerURL.path, stableInputURL.path, outputURL.path, "-v"]
  process.arguments = arguments
  var environment = ProcessInfo.processInfo.environment
  environment["NOTA_APP_RUNNER_SMOKE"] = "1"
  process.environment = environment

  let outputPipe = Pipe()
  let errorPipe = Pipe()
  process.standardOutput = outputPipe
  process.standardError = errorPipe

  try process.run()
  process.waitUntilExit()

  let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

  guard process.terminationStatus == 0 else {
    throw NotaAppError.pipelineFailed(
      process.terminationStatus,
      command: "/bin/bash \(arguments.map(shellQuoted).joined(separator: " "))",
      stdout: stdout,
      stderr: stderr
    )
  }

  let markdown = try String(contentsOf: outputURL, encoding: .utf8)
  guard markdown.contains("# Nota App Smoke Test") else {
    throw NotaSmokeError.invalidOutput(outputURL.path)
  }
}

private enum NotaSmokeError: LocalizedError {
  case unsupportedInput(String)
  case invalidOutput(String)

  var errorDescription: String? {
    switch self {
    case .unsupportedInput(let extensionName):
      return "Unsupported smoke input extension: \(extensionName)"
    case .invalidOutput(let path):
      return "Smoke output was not valid markdown: \(path)"
    }
  }
}

private func writeStandardError(_ message: String) {
  if let data = message.data(using: .utf8) {
    FileHandle.standardError.write(data)
  }
}

private func rtfData(from attributedText: NSAttributedString) throws -> Data {
  try attributedText.data(
    from: NSRange(location: 0, length: attributedText.length),
    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
  )
}

private func renderMarkdownAsRichText(_ markdown: String) -> NSAttributedString {
  let output = NSMutableAttributedString()
  let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
  let lines = normalized.components(separatedBy: "\n")
  var isInCodeBlock = false

  for rawLine in lines {
    let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)

    if trimmedLine.hasPrefix("```") {
      isInCodeBlock.toggle()
      continue
    }

    if isInCodeBlock {
      appendPlainLine(rawLine, to: output, font: NSFonts.codeBlock, color: .secondaryLabelColor)
      continue
    }

    if trimmedLine.isEmpty {
      output.append(NSAttributedString(string: "\n"))
      continue
    }

    if trimmedLine == "---" {
      appendPlainLine("------------------------------", to: output, font: NSFonts.separator, color: .separatorColor)
      continue
    }

    if trimmedLine.hasPrefix("## ") {
      let title = String(trimmedLine.dropFirst(3))
      appendPlainLine(title, to: output, font: NSFonts.h2, paragraphSpacing: Metrics.paraSpacingH2)
      continue
    }

    if trimmedLine.hasPrefix("# ") {
      let title = String(trimmedLine.dropFirst(2))
      appendPlainLine(title, to: output, font: NSFonts.h1, paragraphSpacing: Metrics.paraSpacingH1)
      continue
    }

    if trimmedLine.hasPrefix("- ") {
      let item = String(trimmedLine.dropFirst(2))
      appendBulletLine(item, to: output)
      continue
    }

    if appendTranscriptLine(trimmedLine, to: output) {
      continue
    }

    appendInlineMarkdownLine(trimmedLine, to: output)
  }

  return output
}

private func appendPlainLine(
  _ line: String,
  to output: NSMutableAttributedString,
  font: NSFont,
  color: NSColor = .labelColor,
  paragraphSpacing: CGFloat = Metrics.paraSpacingTight
) {
  let paragraph = NSMutableParagraphStyle()
  paragraph.paragraphSpacing = paragraphSpacing
  paragraph.lineSpacing = Metrics.lineSpacingDefault
  output.append(NSAttributedString(string: line, attributes: [
    .font: font,
    .foregroundColor: color,
    .paragraphStyle: paragraph
  ]))
  output.append(NSAttributedString(string: "\n"))
}

private func appendBulletLine(_ line: String, to output: NSMutableAttributedString) {
  let paragraph = NSMutableParagraphStyle()
  paragraph.firstLineHeadIndent = 0
  paragraph.headIndent = Metrics.bulletHeadIndent
  paragraph.paragraphSpacing = Metrics.paraSpacingTight
  paragraph.lineSpacing = Metrics.lineSpacingDefault

  output.append(NSAttributedString(string: "• ", attributes: [
    .font: NSFonts.body,
    .foregroundColor: NSColor.labelColor,
    .paragraphStyle: paragraph
  ]))
  appendInlineMarkdown(line, to: output, font: NSFonts.body, paragraphStyle: paragraph)
  output.append(NSAttributedString(string: "\n"))
}

private func appendTranscriptLine(_ line: String, to output: NSMutableAttributedString) -> Bool {
  let pattern = #"^\[([0-9]{2}:[0-9]{2})\] \*\*(.+?):\*\* (.*)$"#
  guard
    let regex = try? NSRegularExpression(pattern: pattern),
    let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
    match.numberOfRanges == 4,
    let timestampRange = Range(match.range(at: 1), in: line),
    let speakerRange = Range(match.range(at: 2), in: line),
    let textRange = Range(match.range(at: 3), in: line)
  else {
    return false
  }

  let paragraph = NSMutableParagraphStyle()
  paragraph.paragraphSpacing = Metrics.paraSpacingTranscript
  paragraph.lineSpacing = Metrics.lineSpacingDefault

  let timestamp = String(line[timestampRange])
  let speaker = String(line[speakerRange])
  let text = String(line[textRange])

  output.append(NSAttributedString(string: "[\(timestamp)] ", attributes: [
    .font: NSFonts.timestamp,
    .foregroundColor: NSColor.secondaryLabelColor,
    .paragraphStyle: paragraph
  ]))
  output.append(NSAttributedString(string: "\(speaker): ", attributes: [
    .font: NSFonts.speaker,
    .foregroundColor: NSColor.labelColor,
    .paragraphStyle: paragraph
  ]))
  output.append(NSAttributedString(string: text, attributes: [
    .font: NSFonts.body,
    .foregroundColor: NSColor.labelColor,
    .paragraphStyle: paragraph
  ]))
  output.append(NSAttributedString(string: "\n"))
  return true
}

private func appendInlineMarkdownLine(_ line: String, to output: NSMutableAttributedString) {
  let paragraph = NSMutableParagraphStyle()
  paragraph.paragraphSpacing = Metrics.paraSpacingTight
  paragraph.lineSpacing = Metrics.lineSpacingDefault
  appendInlineMarkdown(line, to: output, font: NSFonts.body, paragraphStyle: paragraph)
  output.append(NSAttributedString(string: "\n"))
}

private func appendInlineMarkdown(
  _ line: String,
  to output: NSMutableAttributedString,
  font: NSFont,
  paragraphStyle: NSParagraphStyle
) {
  let parts = line.components(separatedBy: "**")
  for index in parts.indices {
    let part = parts[index]
    guard !part.isEmpty else {
      continue
    }

    let segmentFont = index.isMultiple(of: 2) ? font : NSFont.boldSystemFont(ofSize: font.pointSize)
    output.append(NSAttributedString(string: part, attributes: [
      .font: segmentFont,
      .foregroundColor: NSColor.labelColor,
      .paragraphStyle: paragraphStyle
    ]))
  }
}

struct RichTextViewer: NSViewRepresentable {
  let attributedString: NSAttributedString

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.drawsBackground = false

    let textView = NSTextView()
    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    textView.textContainerInset = NSSize(width: Metrics.richTextInsetX, height: Metrics.richTextInsetY)
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

    scrollView.documentView = textView
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView else {
      return
    }

    textView.textStorage?.setAttributedString(attributedString)
  }
}

private struct LiquidGlassModifier<S: Shape>: ViewModifier {
  let glass: Glass
  let shape: S
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    if reduceTransparency {
      content.background(.regularMaterial, in: shape)
    } else {
      content.glassEffect(glass, in: shape)
    }
  }
}

private struct LiquidGlassButtonModifier: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    if reduceTransparency {
      content.buttonStyle(.bordered)
    } else {
      content.buttonStyle(.glass)
    }
  }
}

extension View {
  fileprivate func liquidGlass<S: Shape>(_ glass: Glass = .regular, in shape: S) -> some View {
    modifier(LiquidGlassModifier(glass: glass, shape: shape))
  }

  fileprivate func liquidGlassButton() -> some View {
    modifier(LiquidGlassButtonModifier())
  }

  fileprivate func dropTargetGlass(isTargeted: Bool) -> some View {
    modifier(DropTargetGlassModifier(isTargeted: isTargeted))
  }
}

private struct DropTargetGlassModifier: ViewModifier {
  let isTargeted: Bool
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    if reduceTransparency {
      content
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Metrics.dropCornerRadius))
        .overlay(
          RoundedRectangle(cornerRadius: Metrics.dropCornerRadius)
            .strokeBorder(isTargeted ? Tokens.dropAccent : Tokens.dropFallbackStrokeIdle, lineWidth: isTargeted ? Metrics.dropStrokeActive : Metrics.dropStrokeIdle)
        )
    } else if isTargeted {
      content.glassEffect(.clear.tint(Tokens.dropAccent), in: RoundedRectangle(cornerRadius: Metrics.dropCornerRadius))
    } else {
      content.glassEffect(.clear, in: RoundedRectangle(cornerRadius: Metrics.dropCornerRadius))
    }
  }
}

struct ContentView: View {
  @ObservedObject var model: NotaModel

  var body: some View {
    NavigationSplitView {
      historyPane
        .navigationSplitViewColumnWidth(min: Metrics.sidebarMin, ideal: Metrics.sidebarIdeal, max: Metrics.sidebarMax)
    } detail: {
      mainPane
        .navigationSplitViewColumnWidth(min: Metrics.detailMin, ideal: Metrics.detailIdeal)
        .background(.thinMaterial)
    }
    .toolbar {
      ToolbarItemGroup(placement: .status) {
        if model.isRunning || model.status != "Drop audio to transcribe" {
          HStack(spacing: Metrics.statusHStackSpacing) {
            if model.isRunning {
              ProgressView()
                .controlSize(.small)
            }
            Text(model.status)
              .font(Tokens.statusFont)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          .padding(.horizontal, Metrics.statusPillH)
          .padding(.vertical, Metrics.statusPillV)
          .liquidGlass(.regular.tint(Tokens.toolbarStatusTint), in: .capsule)
          .transition(.opacity.combined(with: .scale))
        }
      }

      ToolbarItem(placement: .primaryAction) {
        Menu {
          Section("Copy") {
            Button {
              model.copyRichText()
            } label: {
              Label("Copy Rich Text", systemImage: "doc.on.clipboard")
            }
            Button {
              model.copyMarkdown()
            } label: {
              Label("Copy Markdown", systemImage: "chevron.left.forwardslash.chevron.right")
            }
          }
          Section("Export") {
            Button {
              model.exportRichText()
            } label: {
              Label("Export Rich Text...", systemImage: "textformat")
            }
            Button {
              model.exportMarkdown()
            } label: {
              Label("Export Markdown...", systemImage: "number")
            }
          }
          Section {
            Button {
              model.revealOutput()
            } label: {
              Label("Reveal in Finder", systemImage: "finder")
            }
            .disabled(model.lastOutputURL == nil)
          }
        } label: {
          Label("Share", systemImage: "square.and.arrow.up")
        }
        .menuIndicator(.hidden)
        .help("Copy, export, or reveal transcript")
        .liquidGlassButton()
        .disabled(model.markdown.isEmpty && model.lastOutputURL == nil)
      }
    }
    .animation(Tokens.animFast, value: model.isRunning)
    .containerBackground(.ultraThinMaterial, for: .window)
    .toolbarBackground(.hidden, for: .windowToolbar)
  }

  private var historyPane: some View {
    VStack(spacing: 0) {
      Button {
        model.newTranscription()
      } label: {
        HStack(spacing: Metrics.newButtonStackSpacing) {
          Image(systemName: "square.and.pencil")
          Text("New Transcription")
            .fontWeight(.medium)
          Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.newButtonH)
        .padding(.vertical, Metrics.newButtonV)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .liquidGlass(.regular.tint(Tokens.primaryActionTint), in: RoundedRectangle(cornerRadius: Metrics.primaryActionCornerRadius))
      .padding(.horizontal, Metrics.newButtonOuterH)
      .padding(.top, Metrics.newButtonOuterTop)
      .padding(.bottom, Metrics.newButtonOuterBottom)
      .disabled(model.isRunning)

      if model.history.isEmpty {
        Spacer()
        VStack(spacing: Metrics.emptyHistoryStackSpacing) {
          Image(systemName: "tray")
            .font(Tokens.emptyHistoryIconFont)
            .foregroundStyle(.secondary)
          Text("No transcripts yet")
            .font(Tokens.emptyHistoryLabelFont)
            .foregroundStyle(.secondary)
          Text("Drop audio into the main window")
            .font(Tokens.emptyHistoryHelperFont)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Metrics.historyEmptyHorizontalPadding)
        Spacer()
      } else {
        List(selection: $model.selectedHistoryID) {
          Section {
            ForEach(model.history) { entry in
              historyRow(entry)
                .tag(Optional(entry.id))
                .contextMenu {
                  Button {
                    model.openHistory(entry)
                  } label: {
                    Label("Open", systemImage: "doc.text")
                  }
                  Button {
                    NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                  } label: {
                    Label("Reveal in Finder", systemImage: "finder")
                  }
                  Divider()
                  Button(role: .destructive) {
                    model.deleteHistory(entry)
                  } label: {
                    Label("Delete", systemImage: "trash")
                  }
                }
            }
          } header: {
            Text("History")
              .font(Tokens.historySectionFont)
              .foregroundStyle(.secondary)
          }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
      }
    }
    .onChange(of: model.selectedHistoryID) { _, newValue in
      guard let newValue, let entry = model.history.first(where: { $0.id == newValue }) else {
        return
      }
      if entry.url.standardizedFileURL != model.lastOutputURL?.standardizedFileURL {
        model.openHistory(entry)
      }
    }
  }

  private func historyRow(_ entry: HistoryEntry) -> some View {
    VStack(alignment: .leading, spacing: Metrics.tightStackSpacing) {
      Text(entry.title)
        .font(Tokens.historyTitleFont)
        .fontWeight(.medium)
        .lineLimit(1)
        .truncationMode(.middle)
      Text(entry.relativeDate)
        .font(Tokens.historyDateFont)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, Metrics.historyRowVerticalPadding)
  }

  private var mainPane: some View {
    ZStack {
      if model.hasContent {
        resultPane
      } else {
        emptyState
      }

      if model.isDropTargeted {
        RoundedRectangle(cornerRadius: Metrics.dropFullBleedCornerRadius)
          .strokeBorder(Tokens.dropAccent, lineWidth: Metrics.dropTargetStrokeWidth)
          .allowsHitTesting(false)
          .transition(.opacity)
      }
    }
    .animation(Tokens.animSnap, value: model.isDropTargeted)
    .animation(Tokens.animFast, value: model.hasContent)
    .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.isDropTargeted) { providers in
      guard let provider = providers.first else {
        return false
      }

      provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
        let url: URL?
        if let data = item as? Data {
          url = URL(dataRepresentation: data, relativeTo: nil)
        } else if let nsURL = item as? NSURL {
          url = nsURL as URL
        } else {
          url = nil
        }

        if let url {
          Task { @MainActor in
            model.accept(url)
          }
        }
      }
      return true
    }
  }

  private var emptyState: some View {
    VStack(spacing: Metrics.emptyMainSpacing) {
      Spacer()

      Image(systemName: model.isRunning ? "waveform" : "tray.and.arrow.down")
        .font(Tokens.emptyMainIconFont)
        .foregroundStyle(model.isDropTargeted ? Tokens.dropAccent : Tokens.emptyIconColor)
        .symbolEffect(.pulse, isActive: model.isRunning)

      VStack(spacing: Metrics.emptyTextSpacing) {
        Text(model.displayName)
          .font(Tokens.emptyMainTitleFont)
          .fontWeight(.bold)
          .foregroundStyle(.primary)
          .multilineTextAlignment(.center)

        Text(model.displayPath)
          .font(Tokens.emptyMainPathFont)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, Metrics.emptySubtextHorizontalPadding)
      }

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(Metrics.emptyMainOuterPadding)
  }

  private var resultPane: some View {
    RichTextViewer(attributedString: model.richText)
  }
}
