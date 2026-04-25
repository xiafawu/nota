import Foundation

func runHeadlessSmokeTestIfRequested(arguments: [String]) -> Int32? {
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
