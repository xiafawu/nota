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
        .frame(minWidth: 780, minHeight: 560)
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
  @StateObject private var speakers = SpeakersModel()

  var body: some View {
    TabView {
      generalTab
        .tabItem { Label("General", systemImage: "gearshape") }

      SpeakersSettingsView(model: speakers)
        .tabItem { Label("Speakers", systemImage: "person.wave.2") }
    }
    .frame(width: 720, height: 480)
  }

  private var generalTab: some View {
    Form {
      Section {
        Toggle(isOn: $model.identifySpeakers) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Remember speakers")
            Text("Identify recurring voices across recordings.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .formStyle(.grouped)
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
      appendPlainLine(rawLine, to: output, font: .monospacedSystemFont(ofSize: 12, weight: .regular), color: .secondaryLabelColor)
      continue
    }

    if trimmedLine.isEmpty {
      output.append(NSAttributedString(string: "\n"))
      continue
    }

    if trimmedLine == "---" {
      appendPlainLine("------------------------------", to: output, font: .systemFont(ofSize: 13), color: .separatorColor)
      continue
    }

    if trimmedLine.hasPrefix("## ") {
      let title = String(trimmedLine.dropFirst(3))
      appendPlainLine(title, to: output, font: .boldSystemFont(ofSize: 18), paragraphSpacing: 8)
      continue
    }

    if trimmedLine.hasPrefix("# ") {
      let title = String(trimmedLine.dropFirst(2))
      appendPlainLine(title, to: output, font: .boldSystemFont(ofSize: 26), paragraphSpacing: 10)
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
  paragraphSpacing: CGFloat = 4
) {
  let paragraph = NSMutableParagraphStyle()
  paragraph.paragraphSpacing = paragraphSpacing
  paragraph.lineSpacing = 2
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
  paragraph.headIndent = 18
  paragraph.paragraphSpacing = 4
  paragraph.lineSpacing = 2

  output.append(NSAttributedString(string: "• ", attributes: [
    .font: NSFont.systemFont(ofSize: 14),
    .foregroundColor: NSColor.labelColor,
    .paragraphStyle: paragraph
  ]))
  appendInlineMarkdown(line, to: output, font: .systemFont(ofSize: 14), paragraphStyle: paragraph)
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
  paragraph.paragraphSpacing = 5
  paragraph.lineSpacing = 2

  let timestamp = String(line[timestampRange])
  let speaker = String(line[speakerRange])
  let text = String(line[textRange])

  output.append(NSAttributedString(string: "[\(timestamp)] ", attributes: [
    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
    .foregroundColor: NSColor.secondaryLabelColor,
    .paragraphStyle: paragraph
  ]))
  output.append(NSAttributedString(string: "\(speaker): ", attributes: [
    .font: NSFont.boldSystemFont(ofSize: 14),
    .foregroundColor: NSColor.labelColor,
    .paragraphStyle: paragraph
  ]))
  output.append(NSAttributedString(string: text, attributes: [
    .font: NSFont.systemFont(ofSize: 14),
    .foregroundColor: NSColor.labelColor,
    .paragraphStyle: paragraph
  ]))
  output.append(NSAttributedString(string: "\n"))
  return true
}

private func appendInlineMarkdownLine(_ line: String, to output: NSMutableAttributedString) {
  let paragraph = NSMutableParagraphStyle()
  paragraph.paragraphSpacing = 4
  paragraph.lineSpacing = 2
  appendInlineMarkdown(line, to: output, font: .systemFont(ofSize: 14), paragraphStyle: paragraph)
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
    textView.textContainerInset = NSSize(width: 20, height: 18)
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
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
          RoundedRectangle(cornerRadius: 20)
            .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isTargeted ? 2 : 1)
        )
    } else if isTargeted {
      content.glassEffect(.clear.tint(.accentColor), in: RoundedRectangle(cornerRadius: 20))
    } else {
      content.glassEffect(.clear, in: RoundedRectangle(cornerRadius: 20))
    }
  }
}

struct ContentView: View {
  @ObservedObject var model: NotaModel

  var body: some View {
    NavigationSplitView {
      historyPane
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
    } detail: {
      mainPane
        .navigationSplitViewColumnWidth(min: 520, ideal: 720)
        .background(.thinMaterial)
    }
    .toolbar {
      ToolbarItemGroup(placement: .status) {
        if model.isRunning || model.status != "Drop audio to transcribe" {
          HStack(spacing: 6) {
            if model.isRunning {
              ProgressView()
                .controlSize(.small)
            }
            Text(model.status)
              .font(.callout)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
          .liquidGlass(.regular.tint(.secondary.opacity(0.1)), in: .capsule)
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
    .animation(.easeInOut(duration: 0.2), value: model.isRunning)
    .containerBackground(.ultraThinMaterial, for: .window)
    .toolbarBackground(.hidden, for: .windowToolbar)
  }

  private var historyPane: some View {
    VStack(spacing: 0) {
      Button {
        model.newTranscription()
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "square.and.pencil")
          Text("New Transcription")
            .fontWeight(.medium)
          Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .liquidGlass(.regular.tint(.accentColor.opacity(0.15)), in: RoundedRectangle(cornerRadius: 10))
      .padding(.horizontal, 10)
      .padding(.top, 10)
      .padding(.bottom, 6)
      .disabled(model.isRunning)

      if model.history.isEmpty {
        Spacer()
        VStack(spacing: 8) {
          Image(systemName: "tray")
            .font(.system(size: 26, weight: .regular))
            .foregroundStyle(.secondary)
          Text("No transcripts yet")
            .font(.callout)
            .foregroundStyle(.secondary)
          Text("Drop audio into the main window")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
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
              .font(.caption)
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
    VStack(alignment: .leading, spacing: 2) {
      Text(entry.title)
        .font(.callout)
        .fontWeight(.medium)
        .lineLimit(1)
        .truncationMode(.middle)
      Text(entry.relativeDate)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 2)
  }

  private var mainPane: some View {
    ZStack {
      if model.hasContent {
        resultPane
      } else {
        emptyState
      }

      if model.isDropTargeted {
        RoundedRectangle(cornerRadius: 0)
          .strokeBorder(Color.accentColor, lineWidth: 3)
          .allowsHitTesting(false)
          .transition(.opacity)
      }
    }
    .animation(.easeInOut(duration: 0.15), value: model.isDropTargeted)
    .animation(.easeInOut(duration: 0.2), value: model.hasContent)
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
    VStack(spacing: 24) {
      Spacer()

      Image(systemName: model.isRunning ? "waveform" : "tray.and.arrow.down")
        .font(.system(size: 72, weight: .semibold))
        .foregroundStyle(model.isDropTargeted ? Color.accentColor : Color.primary.opacity(0.85))
        .symbolEffect(.pulse, isActive: model.isRunning)

      VStack(spacing: 10) {
        Text(model.displayName)
          .font(.title)
          .fontWeight(.bold)
          .foregroundStyle(.primary)
          .multilineTextAlignment(.center)

        Text(model.displayPath)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 24)
      }

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(40)
  }

  private var resultPane: some View {
    RichTextViewer(attributedString: model.richText)
  }
}

// MARK: - Speakers Settings

struct SpeakerProfile: Codable, Hashable {
  var embedding: [Double]
  var enrolledAt: String
  var source: String
}

struct SpeakerStore: Codable {
  var version: Int
  var speakers: [String: SpeakerProfile]

  static let empty = SpeakerStore(version: 1, speakers: [:])
}

enum SpeakerStoreLocation {
  static var primary: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".nota", isDirectory: true)
      .appendingPathComponent("speakers.json")
  }

  static var legacy: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".meetingsum", isDirectory: true)
      .appendingPathComponent("speakers.json")
  }
}

enum SpeakerStoreError: LocalizedError {
  case notFound(String)
  case nameCollision(String)
  case sameName
  case mergeFailed(String)

  var errorDescription: String? {
    switch self {
    case .notFound(let name):
      return "Speaker \"\(name)\" not found."
    case .nameCollision(let name):
      return "A speaker named \"\(name)\" already exists."
    case .sameName:
      return "Source and destination must be different speakers."
    case .mergeFailed(let detail):
      return "Merge failed: \(detail)"
    }
  }
}

struct SpeakerEntry: Identifiable, Hashable {
  var name: String
  var profile: SpeakerProfile
  var id: String { name }
}

@MainActor
final class SpeakersModel: ObservableObject {
  @Published private(set) var entries: [SpeakerEntry] = []
  @Published var selectedID: String?
  @Published var draftName: String = ""
  @Published var statusMessage: String = ""
  @Published var lastError: String?
  @Published private(set) var isBusy: Bool = false

  private let projectDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NOTA_PROJECT_DIR"] ?? "/Users/xiafawu/Developer/Nota")

  init() {
    refresh()
  }

  var selected: SpeakerEntry? {
    guard let selectedID else { return nil }
    return entries.first { $0.id == selectedID }
  }

  var canCommitRename: Bool {
    guard let selected else { return false }
    let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == selected.name { return false }
    return !entries.contains { $0.name == trimmed }
  }

  var mergeCandidates: [SpeakerEntry] {
    guard let selected else { return [] }
    return entries.filter { $0.id != selected.id }
  }

  func refresh() {
    let store = Self.loadStore()
    let next = store.speakers
      .map { SpeakerEntry(name: $0.key, profile: $0.value) }
      .sorted { $0.name.lowercased() < $1.name.lowercased() }
    entries = next

    if let selectedID, !next.contains(where: { $0.id == selectedID }) {
      self.selectedID = next.first?.id
    } else if selectedID == nil {
      selectedID = next.first?.id
    }
    syncDraftWithSelection()
  }

  func selectionChanged() {
    syncDraftWithSelection()
    lastError = nil
  }

  func commitRename() {
    guard let selected else { return }
    let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      lastError = "Name cannot be empty."
      return
    }
    if trimmed == selected.name { return }

    do {
      var store = Self.loadStore()
      guard let profile = store.speakers[selected.name] else {
        throw SpeakerStoreError.notFound(selected.name)
      }
      if store.speakers[trimmed] != nil {
        throw SpeakerStoreError.nameCollision(trimmed)
      }
      store.speakers.removeValue(forKey: selected.name)
      store.speakers[trimmed] = profile
      try Self.writeStore(store)
      statusMessage = "Renamed \"\(selected.name)\" to \"\(trimmed)\"."
      lastError = nil
      selectedID = trimmed
      refresh()
    } catch {
      lastError = error.localizedDescription
    }
  }

  func deleteSelected() {
    guard let selected else { return }
    do {
      var store = Self.loadStore()
      guard store.speakers.removeValue(forKey: selected.name) != nil else {
        throw SpeakerStoreError.notFound(selected.name)
      }
      try Self.writeStore(store)
      statusMessage = "Deleted \"\(selected.name)\"."
      lastError = nil
      selectedID = nil
      refresh()
    } catch {
      lastError = error.localizedDescription
    }
  }

  func merge(into destination: String) {
    guard let selected else { return }
    guard !destination.isEmpty, destination != selected.name else {
      lastError = SpeakerStoreError.sameName.localizedDescription
      return
    }

    isBusy = true
    lastError = nil
    statusMessage = "Merging \(selected.name) into \(destination)..."
    let src = selected.name
    let projectDir = projectDirectory

    Task.detached(priority: .userInitiated) {
      let result = shellMergeSpeakers(src: src, dst: destination, projectDirectory: projectDir)
      await MainActor.run {
        self.isBusy = false
        switch result {
        case .success:
          self.statusMessage = "Merged \"\(src)\" into \"\(destination)\"."
          self.selectedID = destination
          self.refresh()
        case .failure(let error):
          self.lastError = error.localizedDescription
          self.statusMessage = ""
        }
      }
    }
  }

  // MARK: - Helpers

  private func syncDraftWithSelection() {
    draftName = selected?.name ?? ""
  }

  static func loadStore() -> SpeakerStore {
    if let store = readStore(at: SpeakerStoreLocation.primary) {
      return store
    }
    if let legacy = readStore(at: SpeakerStoreLocation.legacy) {
      return legacy
    }
    return .empty
  }

  private static func readStore(at url: URL) -> SpeakerStore? {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    do {
      let data = try Data(contentsOf: url)
      return try JSONDecoder().decode(SpeakerStore.self, from: data)
    } catch {
      return nil
    }
  }

  static func writeStore(_ store: SpeakerStore) throws {
    let target = SpeakerStoreLocation.primary
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: target.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(store)

    let tempDirectory = target.deletingLastPathComponent()
    let tempURL = tempDirectory.appendingPathComponent(
      ".speakers-\(UUID().uuidString).tmp"
    )
    try data.write(to: tempURL, options: .atomic)

    if fileManager.fileExists(atPath: target.path) {
      _ = try fileManager.replaceItemAt(target, withItemAt: tempURL)
    } else {
      try fileManager.moveItem(at: tempURL, to: target)
    }
  }

}

private func shellMergeSpeakers(
  src: String,
  dst: String,
  projectDirectory: URL
) -> Result<Void, Error> {
  let process = Process()
  process.currentDirectoryURL = projectDirectory

  let distEntry = projectDirectory
    .appendingPathComponent("dist", isDirectory: true)
    .appendingPathComponent("index.js")
  let srcEntry = projectDirectory
    .appendingPathComponent("src", isDirectory: true)
    .appendingPathComponent("index.ts")

  let arguments: [String]
  if FileManager.default.fileExists(atPath: distEntry.path) {
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    arguments = ["node", distEntry.path, "speakers", "merge", src, dst]
  } else {
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    arguments = ["npx", "tsx", srcEntry.path, "speakers", "merge", src, dst]
  }
  process.arguments = arguments

  let outPipe = Pipe()
  let errPipe = Pipe()
  process.standardOutput = outPipe
  process.standardError = errPipe

  do {
    try process.run()
    process.waitUntilExit()
  } catch {
    return .failure(SpeakerStoreError.mergeFailed(error.localizedDescription))
  }

  let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

  if process.terminationStatus == 0 {
    return .success(())
  }
  let detail = stderr.isEmpty ? stdout : stderr
  let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
  return .failure(SpeakerStoreError.mergeFailed(
    trimmed.isEmpty ? "exit code \(process.terminationStatus)" : trimmed
  ))
}

struct SpeakersSettingsView: View {
  @ObservedObject var model: SpeakersModel
  @State private var showDeleteConfirmation: Bool = false
  @State private var mergeTarget: String = ""

  private static let displayDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()

  private static let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  var body: some View {
    HStack(spacing: 0) {
      sidebar
        .frame(width: 240)
      Divider()
      detail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .toolbar {
      ToolbarItemGroup(placement: .automatic) {
        Button {
          // Reserved for future enrolment flow.
        } label: {
          Label("New", systemImage: "plus")
        }
        .disabled(true)
        .help("Enrolment is available via nota --identify")

        Button {
          model.refresh()
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .help("Reload from ~/.nota/speakers.json")
      }
    }
    .onAppear { model.refresh() }
  }

  private var sidebar: some View {
    VStack(spacing: 0) {
      if model.entries.isEmpty {
        Spacer()
        VStack(spacing: 8) {
          Image(systemName: "person.wave.2")
            .font(.system(size: 28))
            .foregroundStyle(.secondary)
          Text("No enrolled speakers")
            .font(.callout)
            .foregroundStyle(.secondary)
          Text("Run nota --identify to enrol voices.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
        }
        Spacer()
      } else {
        List(selection: Binding(
          get: { model.selectedID },
          set: { newValue in
            model.selectedID = newValue
            model.selectionChanged()
          }
        )) {
          ForEach(model.entries) { entry in
            speakerRow(entry)
              .tag(Optional(entry.id))
          }
        }
        .listStyle(.sidebar)
      }
    }
  }

  private func speakerRow(_ entry: SpeakerEntry) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(entry.name)
        .font(.callout)
        .fontWeight(.medium)
        .lineLimit(1)
        .truncationMode(.middle)
      HStack(spacing: 6) {
        Text(formatEnrolledAt(entry.profile.enrolledAt))
        if !entry.profile.source.isEmpty {
          Text("•")
          Text(URL(fileURLWithPath: entry.profile.source).lastPathComponent)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 2)
  }

  @ViewBuilder
  private var detail: some View {
    if let selected = model.selected {
      detailForm(for: selected)
    } else {
      VStack(spacing: 12) {
        Image(systemName: "person.crop.circle.badge.questionmark")
          .font(.system(size: 36))
          .foregroundStyle(.secondary)
        Text("Select a speaker")
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func detailForm(for entry: SpeakerEntry) -> some View {
    Form {
      Section("Identity") {
        TextField("Name", text: Binding(
          get: { model.draftName },
          set: { model.draftName = $0 }
        ))
        .textFieldStyle(.roundedBorder)
        HStack {
          Spacer()
          Button("Rename") {
            model.commitRename()
          }
          .disabled(!model.canCommitRename)
        }
      }

      Section("Profile") {
        LabeledContent("Enrolled") {
          Text(formatEnrolledAt(entry.profile.enrolledAt))
        }
        LabeledContent("Source") {
          Text(entry.profile.source.isEmpty ? "Unknown" : entry.profile.source)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
        LabeledContent("Embedding") {
          Text("\(entry.profile.embedding.count) dims")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      Section("Merge") {
        HStack {
          Picker("Merge into", selection: $mergeTarget) {
            Text("Select speaker").tag("")
            ForEach(model.mergeCandidates) { candidate in
              Text(candidate.name).tag(candidate.name)
            }
          }
          .pickerStyle(.menu)

          Button("Merge") {
            model.merge(into: mergeTarget)
            mergeTarget = ""
          }
          .disabled(mergeTarget.isEmpty || model.isBusy)
        }
        Text("Averages embeddings via nota speakers merge. The source speaker is removed.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section {
        HStack {
          Spacer()
          Button(role: .destructive) {
            showDeleteConfirmation = true
          } label: {
            Label("Delete Speaker", systemImage: "trash")
          }
        }
      }

      if model.isBusy || !model.statusMessage.isEmpty || model.lastError != nil {
        Section {
          if let lastError = model.lastError {
            Label(lastError, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.red)
              .font(.caption)
          } else if model.isBusy {
            HStack(spacing: 8) {
              ProgressView().controlSize(.small)
              Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          } else if !model.statusMessage.isEmpty {
            Text(model.statusMessage)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .formStyle(.grouped)
    .alert("Delete \(entry.name)?", isPresented: $showDeleteConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) {
        model.deleteSelected()
      }
    } message: {
      Text("This removes the voiceprint from \(SpeakerStoreLocation.primary.path). It cannot be undone.")
    }
  }

  private func formatEnrolledAt(_ raw: String) -> String {
    if let date = Self.isoFormatter.date(from: raw) {
      return Self.displayDateFormatter.string(from: date)
    }
    let fallback = ISO8601DateFormatter()
    if let date = fallback.date(from: raw) {
      return Self.displayDateFormatter.string(from: date)
    }
    return raw
  }
}
