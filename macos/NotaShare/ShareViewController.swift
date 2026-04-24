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
    do {
      guard let url = try await firstSharedFileURL() else {
        await MainActor.run {
          finish(with: "No audio file found", error: ShareError.noFile)
        }
        return
      }

      let copiedURL = try copyForNota(url)
      let _ = await MainActor.run {
        NSWorkspace.shared.open(copiedURL)
      }
      await MainActor.run {
        finish(with: "Opened in Nota")
      }
    } catch {
      await MainActor.run {
        finish(with: "Could not open in Nota", error: error)
      }
    }
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
    let directory = fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Documents", isDirectory: true)
      .appendingPathComponent("Nota", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

    let extensionName = url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased()
    let destination = directory.appendingPathComponent(".nota-share-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).\(extensionName)")
    try fileManager.copyItem(at: url, to: destination)
    return destination
  }
}

private enum ShareError: LocalizedError {
  case noFile

  var errorDescription: String? {
    switch self {
    case .noFile:
      return "No shared audio file was provided."
    }
  }
}
