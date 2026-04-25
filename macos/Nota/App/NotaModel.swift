import AppKit
import SwiftUI
import UniformTypeIdentifiers

let supportedExtensions: Set<String> = [
  "mp3", "wav", "m4a", "aac", "caf", "aif", "aiff", "ogg", "webm", "flac", "qta", "mov", "mp4"
]

@MainActor
final class NotaModel: ObservableObject {
  @Published var selectedURL: URL?
  @Published var originalSelectedURL: URL?
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
      originalSelectedURL = url
      status = url.lastPathComponent
    } catch {
      selectedURL = nil
      originalSelectedURL = nil
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
    let displayURL = originalSelectedURL ?? selectedURL

    isRunning = true
    markdown = ""
    lastOutputURL = nil
    status = "Preparing audio..."

    Task {
      do {
        let result = try await runNota(for: selectedURL, displayURL: displayURL)
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
      guard name.hasSuffix(".summary.md") else {
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
    originalSelectedURL = nil
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

  private func runNota(for url: URL, displayURL: URL) async throws -> NotaResult {
    try await Task.detached(priority: .userInitiated) { [identifySpeakers, projectDirectory, outputDirectory] in
      let fileManager = FileManager.default
      try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

      let shouldRemoveSharedInput = url.deletingLastPathComponent().standardizedFileURL == outputDirectory.standardizedFileURL
        && (url.lastPathComponent.hasPrefix(".nota-share-") || url.lastPathComponent.hasPrefix(".nota-input-"))

      let timestamp = notaTimestamp()
      let baseName = sanitizedBaseName(displayURL)
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

    if let url = originalSelectedURL ?? selectedURL {
      return "\(sanitizedBaseName(url)).summary.\(extensionName)"
    }

    return "nota-summary.\(extensionName)"
  }
}

struct NotaResult {
  let markdown: String
  let outputURL: URL
}

enum NotaAppError: LocalizedError {
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
