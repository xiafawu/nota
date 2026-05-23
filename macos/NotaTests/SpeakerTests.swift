// Swift tests for in-transcript speaker naming.
// Compiled and run by macos/NotaTests/run-tests.sh — see that file for details.
// Uses a minimal hand-rolled assertion helper so no XCTest or SPM dependency
// is needed (the app has no .xcodeproj / test target).

import Foundation

// MARK: - Minimal test runner

private var failures: [(test: String, message: String)] = []
private var passed = 0

private func test(_ name: String, body: () throws -> Void) {
  do {
    try body()
    passed += 1
    print("  PASS  \(name)")
  } catch {
    let msg = "\(error)"
    failures.append((name, msg))
    print("  FAIL  \(name): \(msg)")
  }
}

private func expect(_ condition: Bool, _ message: String = "assertion failed", file: StaticString = #file, line: Int = #line) throws {
  if !condition {
    throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(message) (\(file):\(line))"])
  }
}

// MARK: - Inline types under test (mirrors production code without importing the app binary)
// We re-declare only the structs/enums we need to test so this file can
// be compiled as an isolated executable.

private struct VoiceprintT: Decodable {
  var id: String
  var embedding: [Double]
  var enrolledAt: String
  var source: String
}

private struct SpeakerProfileT: Decodable {
  var voiceprints: [VoiceprintT]

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let voiceprints = try container.decodeIfPresent([VoiceprintT].self, forKey: .voiceprints) {
      self.voiceprints = voiceprints
      return
    }
    let embedding = try container.decode([Double].self, forKey: .legacyEmbedding)
    let enrolledAt = try container.decode(String.self, forKey: .legacyEnrolledAt)
    let source = try container.decode(String.self, forKey: .legacySource)
    self.voiceprints = [
      VoiceprintT(id: enrolledAt, embedding: embedding, enrolledAt: enrolledAt, source: source)
    ]
  }

  private enum CodingKeys: String, CodingKey {
    case voiceprints
    case legacyEmbedding = "embedding"
    case legacyEnrolledAt = "enrolledAt"
    case legacySource = "source"
  }
}

private struct SpeakerStoreT: Decodable {
  var version: Int
  var speakers: [String: SpeakerProfileT]
}

private struct SpeakerSidecarDataT: Codable {
  var version: Int
  var speakers: [String: String]
}

// Mirrors SpeakerSidecar.sidecarURL
private func sidecarURL(for documentURL: URL) -> URL {
  documentURL.deletingPathExtension().appendingPathExtension("speakers.json")
}

// Mirrors SpeakerSidecar.load
private func loadSidecar(for documentURL: URL) -> SpeakerSidecarDataT {
  let url = sidecarURL(for: documentURL)
  guard FileManager.default.fileExists(atPath: url.path) else {
    return SpeakerSidecarDataT(version: 1, speakers: [:])
  }
  guard
    let data = try? Data(contentsOf: url),
    let decoded = try? JSONDecoder().decode(SpeakerSidecarDataT.self, from: data)
  else {
    return SpeakerSidecarDataT(version: 1, speakers: [:])
  }
  return decoded
}

// Mirrors SpeakerSidecar.save
private func saveSidecar(_ sidecar: SpeakerSidecarDataT, for documentURL: URL) throws {
  let target = sidecarURL(for: documentURL)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  let data = try encoder.encode(sidecar)
  let tempURL = target.deletingLastPathComponent().appendingPathComponent(
    ".speakers-\(UUID().uuidString).tmp"
  )
  try data.write(to: tempURL, options: .atomic)
  let fileManager = FileManager.default
  if fileManager.fileExists(atPath: target.path) {
    _ = try fileManager.replaceItemAt(target, withItemAt: tempURL)
  } else {
    try fileManager.moveItem(at: tempURL, to: target)
  }
}

// Mirrors NotaModel.parseSpeakerLabels
private func parseSpeakerLabels(from markdown: String) -> [String] {
  let pattern = #"^\[([0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?)\] \*\*(.+?):\*\*"#
  guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else {
    return []
  }
  var seen = Set<String>()
  var ordered: [String] = []
  let range = NSRange(markdown.startIndex..., in: markdown)
  for match in regex.matches(in: markdown, range: range) {
    if let labelRange = Range(match.range(at: 2), in: markdown) {
      let label = String(markdown[labelRange])
      if seen.insert(label).inserted {
        ordered.append(label)
      }
    }
  }
  return ordered
}

// MARK: - Test suites

func runSidecarTests() {
  print("\nSpeakerSidecar round-trip")

  test("sidecarURL: strips .md and appends .speakers.json") {
    let docURL = URL(fileURLWithPath: "/tmp/foo.summary.md")
    let expected = URL(fileURLWithPath: "/tmp/foo.summary.speakers.json")
    try expect(sidecarURL(for: docURL) == expected, "got \(sidecarURL(for: docURL))")
  }

  test("load returns empty when file is absent") {
    let docURL = URL(fileURLWithPath: "/tmp/nota-test-absent-\(UUID().uuidString).summary.md")
    let sidecar = loadSidecar(for: docURL)
    try expect(sidecar.speakers.isEmpty, "expected empty speakers map")
    try expect(sidecar.version == 1)
  }

  test("save + load round-trip preserves speaker map") {
    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("nota-sidecar-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let docURL = tmpDir.appendingPathComponent("recording.summary.md")
    let original = SpeakerSidecarDataT(version: 1, speakers: [
      "Speaker 1": "Alice",
      "Speaker 2": "Bob",
    ])
    try saveSidecar(original, for: docURL)

    let loaded = loadSidecar(for: docURL)
    try expect(loaded.speakers["Speaker 1"] == "Alice", "Speaker 1 mismatch")
    try expect(loaded.speakers["Speaker 2"] == "Bob", "Speaker 2 mismatch")
    try expect(loaded.version == 1, "version mismatch")
  }

  test("save is atomic: second save replaces first") {
    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("nota-sidecar2-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let docURL = tmpDir.appendingPathComponent("recording.summary.md")
    try saveSidecar(SpeakerSidecarDataT(version: 1, speakers: ["Speaker 1": "Alice"]), for: docURL)
    try saveSidecar(SpeakerSidecarDataT(version: 1, speakers: ["Speaker 1": "Bob"]), for: docURL)

    let loaded = loadSidecar(for: docURL)
    try expect(loaded.speakers["Speaker 1"] == "Bob", "expected Bob after overwrite")
  }

  test("load returns empty when JSON is malformed") {
    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("nota-sidecar3-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let docURL = tmpDir.appendingPathComponent("recording.summary.md")
    let sidecarPath = sidecarURL(for: docURL)
    try "not-json".write(to: sidecarPath, atomically: true, encoding: .utf8)

    let loaded = loadSidecar(for: docURL)
    try expect(loaded.speakers.isEmpty, "expected empty on malformed JSON")
  }
}

func runLabelParsingTests() {
  print("\nLabel parsing from markdown")

  test("extracts unique labels in first-seen order") {
    let markdown = """
    # Title
    **Captured:** 2026-01-01

    ## Transcript
    [00:01] **Speaker 1:** Hello world.
    [00:03] **Speaker 2:** Hi there.
    [00:05] **Speaker 1:** How are you?
    [00:07] **Speaker 3:** Fine, thanks.
    """
    let labels = parseSpeakerLabels(from: markdown)
    try expect(labels == ["Speaker 1", "Speaker 2", "Speaker 3"], "got \(labels)")
  }

  test("handles HH:MM:SS timestamp format") {
    let markdown = "[1:02:03] **Alice:** Some text here."
    let labels = parseSpeakerLabels(from: markdown)
    try expect(labels == ["Alice"], "got \(labels)")
  }

  test("returns empty array when no transcript lines present") {
    let markdown = "# Title\n\nJust a paragraph with no transcript."
    let labels = parseSpeakerLabels(from: markdown)
    try expect(labels.isEmpty, "expected empty, got \(labels)")
  }

  test("deduplicates without changing first-seen order") {
    let markdown = """
    [00:01] **Bob:** First.
    [00:02] **Alice:** Second.
    [00:03] **Bob:** Third.
    [00:04] **Alice:** Fourth.
    """
    let labels = parseSpeakerLabels(from: markdown)
    try expect(labels == ["Bob", "Alice"], "got \(labels)")
  }
}

func runSpeakerProfileMigrationTests() {
  print("\nSpeakerProfile v1 → v2 Codable migration")

  test("decodes v2 shape directly") {
    let json = """
    {
      "voiceprints": [
        { "id": "2026-01-01T00:00:00.000Z",
          "embedding": [0.1, 0.2],
          "enrolledAt": "2026-01-01T00:00:00.000Z",
          "source": "demo.mp3" }
      ]
    }
    """.data(using: .utf8)!
    let profile = try JSONDecoder().decode(SpeakerProfileT.self, from: json)
    try expect(profile.voiceprints.count == 1, "expected 1 voiceprint")
    try expect(profile.voiceprints[0].source == "demo.mp3")
    try expect(profile.voiceprints[0].embedding == [0.1, 0.2])
  }

  test("migrates v1 flat shape into single-element voiceprints array") {
    let json = """
    {
      "embedding": [1.0, 0.0, 0.5],
      "enrolledAt": "2026-01-01T00:00:00.000Z",
      "source": "legacy.mp3"
    }
    """.data(using: .utf8)!
    let profile = try JSONDecoder().decode(SpeakerProfileT.self, from: json)
    try expect(profile.voiceprints.count == 1, "expected 1 voiceprint after migration")
    let vp = profile.voiceprints[0]
    try expect(vp.embedding == [1.0, 0.0, 0.5], "embedding mismatch")
    try expect(vp.source == "legacy.mp3")
    try expect(vp.enrolledAt == "2026-01-01T00:00:00.000Z")
    try expect(vp.id == "2026-01-01T00:00:00.000Z", "id should equal enrolledAt in v1 migration")
  }

  test("migrates a full v1 store with multiple speakers") {
    let json = """
    {
      "version": 1,
      "speakers": {
        "Alice": { "embedding": [1,0,0], "enrolledAt": "2026-01-01T00:00:00.000Z", "source": "a.mp3" },
        "Bob":   { "embedding": [0,1,0], "enrolledAt": "2026-02-01T00:00:00.000Z", "source": "b.mp3" }
      }
    }
    """.data(using: .utf8)!
    let store = try JSONDecoder().decode(SpeakerStoreT.self, from: json)
    try expect(store.speakers["Alice"] != nil)
    try expect(store.speakers["Bob"] != nil)
    try expect(store.speakers["Alice"]!.voiceprints.count == 1, "Alice should have 1 voiceprint")
    try expect(store.speakers["Bob"]!.voiceprints[0].source == "b.mp3")
  }
}

// MARK: - Main

runSidecarTests()
runLabelParsingTests()
runSpeakerProfileMigrationTests()

print("\n\(passed) passed, \(failures.count) failed")
if !failures.isEmpty {
  for f in failures {
    print("  FAILED: \(f.test) — \(f.message)")
  }
  exit(1)
}
print("All tests passed.")
