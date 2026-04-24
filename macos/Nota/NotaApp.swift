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
      }
    }
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
  @Published var identifySpeakers = false
  @Published var lastOutputURL: URL?
  @Published var displayName = "Drop Audio"
  @Published var displayPath = "MP3, M4A, WAV, CAF, QTA, MOV, MP4"

  private let projectDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NOTA_PROJECT_DIR"] ?? "/Users/xiafawu/Developer/Nota")
  private let outputDirectory = notaOutputDirectory()

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
      } catch {
        markdown = failureMarkdown("Transcription failed", details: error.localizedDescription)
        status = "Transcription failed"
      }
      isRunning = false
    }
  }

  func copyMarkdown() {
    guard !markdown.isEmpty else {
      return
    }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(markdown, forType: .string)
    status = "Copied"
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

}

private struct NotaResult {
  let markdown: String
  let outputURL: URL
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

struct ContentView: View {
  @ObservedObject var model: NotaModel

  var body: some View {
    VStack(spacing: 0) {
      toolbar
        .padding(12)
        .background(.bar)

      HSplitView {
        dropPane
          .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)

        resultPane
          .frame(minWidth: 460)
      }
    }
  }

  private var toolbar: some View {
    HStack(spacing: 10) {
      Button {
        model.chooseFile()
      } label: {
        Label("Open", systemImage: "folder")
      }
      .disabled(model.isRunning)

      Button {
        model.transcribe()
      } label: {
        Label("Transcribe", systemImage: "waveform")
      }
      .disabled(model.selectedURL == nil || model.isRunning)

      Toggle("Remember speakers", isOn: $model.identifySpeakers)
        .toggleStyle(.checkbox)
        .disabled(model.isRunning)

      Spacer()

      if model.isRunning {
        ProgressView()
          .controlSize(.small)
      }

      Text(model.status)
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.middle)
        .foregroundStyle(.secondary)
        .frame(maxWidth: 280, alignment: .trailing)
    }
  }

  private var dropPane: some View {
    VStack(spacing: 16) {
      Spacer()

      Image(systemName: model.isRunning ? "waveform" : "tray.and.arrow.down")
        .font(.system(size: 48, weight: .regular))
        .foregroundStyle(model.isDropTargeted ? Color.accentColor : Color.secondary)
        .symbolEffect(.pulse, isActive: model.isRunning)

      VStack(spacing: 6) {
        Text(model.displayName)
          .font(.title3)
          .fontWeight(.semibold)
          .lineLimit(3)
          .multilineTextAlignment(.center)

        Text(model.displayPath)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(4)
          .multilineTextAlignment(.center)
      }

      Spacer()
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(model.isDropTargeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .windowBackgroundColor))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(model.isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
        .padding(14)
    }
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

  private var resultPane: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text("Transcript")
          .font(.headline)

        Spacer()

        Button {
          model.copyMarkdown()
        } label: {
          Label("Copy", systemImage: "doc.on.doc")
        }
        .disabled(model.markdown.isEmpty)

        Button {
          model.revealOutput()
        } label: {
          Label("Reveal", systemImage: "finder")
        }
        .disabled(model.lastOutputURL == nil)
      }
      .padding(12)

      Divider()

      TextEditor(text: $model.markdown)
        .font(.system(.body, design: .monospaced))
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .textBackgroundColor))
    }
  }
}
