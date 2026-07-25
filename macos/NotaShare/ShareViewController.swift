import AppKit
import UniformTypeIdentifiers

@objc(ShareViewController)
final class ShareViewController: NSViewController {
  private let statusLabel = NSTextField(labelWithString: "Opening in Nota...")
  private var didStart = false

  override func loadView() {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
    statusLabel.alignment = .center
    statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(statusLabel)

    NSLayoutConstraint.activate([
      statusLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      statusLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
      statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 20),
      statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20)
    ])

    view = root
  }

  override func viewDidAppear() {
    super.viewDidAppear()

    guard !didStart else {
      return
    }
    didStart = true

    Task {
      await routeSharedAudio()
    }
  }

  @MainActor
  private func finish(with message: String, error: Error? = nil) {
    statusLabel.stringValue = message

    if let error {
      extensionContext?.cancelRequest(withError: error)
      return
    }

    extensionContext?.completeRequest(returningItems: nil)
  }

  private func routeSharedAudio() async {
    pruneStaleStagedFiles()
    do {
      guard let url = try await firstSharedFileURL() else {
        await MainActor.run {
          finish(with: "No audio file found", error: ShareError.noFile)
        }
        return
      }

      let originalName = url.lastPathComponent
      let copiedURL = try copyForNota(url)
      await MainActor.run {
        self.openInNota(copiedURL, originalName: originalName)
      }
    } catch {
      await MainActor.run {
        finish(with: "Could not open in Nota", error: error)
      }
    }
  }

  /// Hand the staged file to the host app via its custom URL scheme. A
  /// sandboxed extension must use `extensionContext.open` (not NSWorkspace,
  /// which is restricted in extensions), and a `nota://` URL guarantees the
  /// file opens in Nota rather than the system default audio handler.
  @MainActor
  private func openInNota(_ fileURL: URL, originalName: String) {
    var components = URLComponents()
    components.scheme = "nota"
    components.host = "import"
    // `name` carries the user-facing original filename (e.g. "Voice Memo.qta")
    // for display only — the host reads `path` for the actual file. The staged
    // copy's basename is a synthetic ".nota-share-<epoch>-<uuid>" that must not
    // reach the UI. URLComponents percent-encodes both values.
    components.queryItems = [
      URLQueryItem(name: "path", value: fileURL.path),
      URLQueryItem(name: "name", value: originalName)
    ]

    guard let url = components.url else {
      finish(with: "Could not open in Nota", error: ShareError.openFailed)
      return
    }

    // macOS share extensions launch the host app through NSWorkspace.
    // NSExtensionContext.open is an iOS containing-app API: on a macOS share
    // extension it no-ops and reports failure, so it cannot hand off here.
    let opened = NSWorkspace.shared.open(url)
    finish(
      with: opened ? "Opened in Nota" : "Could not open in Nota",
      error: opened ? nil : ShareError.openFailed
    )
  }

  private func firstSharedFileURL() async throws -> URL? {
    let inputItems = extensionContext?.inputItems as? [NSExtensionItem] ?? []

    for item in inputItems {
      for provider in item.attachments ?? [] {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
          if let url = try await loadURL(from: provider, typeIdentifier: UTType.fileURL.identifier) {
            return url
          }
        }
      }
    }

    return nil
  }

  private func loadURL(from provider: NSItemProvider, typeIdentifier: String) async throws -> URL? {
    try await withCheckedThrowingContinuation { continuation in
      provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }

        if let url = item as? URL {
          continuation.resume(returning: url)
        } else if let nsURL = item as? NSURL {
          continuation.resume(returning: nsURL as URL)
        } else if let data = item as? Data {
          continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
        } else {
          continuation.resume(returning: nil)
        }
      }
    }
  }

  private func copyForNota(_ url: URL) throws -> URL {
    let fileManager = FileManager.default
    // `notaInboxDirectory()` lives in macos/Shared/NotaInbox.swift, compiled into
    // both this extension and the host app so the hand-off path cannot drift.
    let directory = try notaInboxDirectory()
    // A no-op when the directory exists — which is the normal case, because the
    // unsandboxed sides create it (AppDelegate at launch, deploy script at
    // install). It must still throw if staging genuinely cannot proceed: this
    // extension's entitlement covers `/.nota/inbox/` but not the intermediate
    // `~/.nota`, so on a machine that has never run Nota this is the call that
    // reports the problem instead of silently staging somewhere unreadable.
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

    let extensionName = url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased()
    let destination = directory.appendingPathComponent(".nota-share-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).\(extensionName)")
    try fileManager.copyItem(at: url, to: destination)
    return destination
  }

  /// Sweep stale share-staging files older than 5 minutes from the shared
  /// inbox (~/.nota/inbox). Without this the inbox accumulates ~78 MB per
  /// share — nothing auto-cleans it. The host app already re-copies a
  /// successful share into ~/Documents/Nota via makeStableInputCopy and
  /// deletes the staged original, so anything still here is debris from a
  /// share the host never picked up. Best-effort: a missing staging
  /// directory or an unresolvable home simply means nothing to prune.
  private func pruneStaleStagedFiles() {
    let fileManager = FileManager.default
    guard let directory = try? notaInboxDirectory() else { return }
    guard let entries = try? fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: []
    ) else { return }
    let cutoff = Date().addingTimeInterval(-5 * 60)
    for entry in entries where entry.lastPathComponent.hasPrefix(".nota-share-") {
      let mtime = (try? entry.resourceValues(
        forKeys: [.contentModificationDateKey]
      ).contentModificationDate) ?? .distantPast
      if mtime < cutoff {
        try? fileManager.removeItem(at: entry)
      }
    }
  }
}

// A failure to resolve the home directory surfaces as
// `NotaInboxError.noHomeDirectory` (macos/Shared/NotaInbox.swift); it reaches
// the user through the same `finish(with:error:)` path as these cases.
private enum ShareError: LocalizedError {
  case noFile
  case openFailed

  var errorDescription: String? {
    switch self {
    case .noFile:
      return "No shared audio file was provided."
    case .openFailed:
      return "Could not open Nota for the shared audio."
    }
  }
}
