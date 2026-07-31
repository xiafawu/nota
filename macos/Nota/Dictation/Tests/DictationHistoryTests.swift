import Foundation
import XCTest

@testable import Nota

final class DictationHistoryTests: XCTestCase {
  private var temporaryDirectory: URL!
  private var fileURL: URL!

  override func setUp() {
    super.setUp()
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("nota-dictation-history-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    fileURL = temporaryDirectory.appendingPathComponent("dictation-history.json")
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: temporaryDirectory)
    super.tearDown()
  }

  func testRetentionIsNewestFirst() {
    let store = DictationHistoryStore(fileURL: fileURL, retentionLimit: 3)
    let base = Date(timeIntervalSince1970: 100)

    for offset in 0..<5 {
      store.record(
        text: "Dictation \(offset)",
        completedAt: base.addingTimeInterval(TimeInterval(offset))
      )
    }

    XCTAssertEqual(store.entries.map(\.text), ["Dictation 4", "Dictation 3", "Dictation 2"])
  }

  func testACompletedAtTimestampControlsNewestFirstOrder() {
    let store = DictationHistoryStore(fileURL: fileURL)
    let now = Date(timeIntervalSince1970: 200)

    _ = store.record(text: "Older", completedAt: now.addingTimeInterval(-10))
    _ = store.record(text: "Newer", completedAt: now)

    XCTAssertEqual(store.entries.map(\.text), ["Newer", "Older"])
  }

  func testEntryPersistsAndDeliveryStatusCanBeUpdated() throws {
    let store = DictationHistoryStore(fileURL: fileURL)
    let id = try XCTUnwrap(
      store.record(
        text: "Keep this even when insertion fails",
        status: .pending,
        targetBundleID: "com.example.Editor"
      )
    )

    store.update(
      id: id,
      status: .failed,
      statusDetail: "No focused target was available"
    )

    let reloaded = DictationHistoryStore(fileURL: fileURL)
    let entry = try XCTUnwrap(reloaded.entry(id: id))
    XCTAssertEqual(entry.text, "Keep this even when insertion fails")
    XCTAssertEqual(entry.status, .failed)
    XCTAssertEqual(entry.statusDetail, "No focused target was available")
    XCTAssertEqual(entry.targetBundleID, "com.example.Editor")
  }

  func testDeleteAndClearRemoveSensitiveText() throws {
    let store = DictationHistoryStore(fileURL: fileURL)
    let first = try XCTUnwrap(store.record(text: "First"))
    _ = store.record(text: "Second")

    store.delete(id: first)
    XCTAssertEqual(store.entries.map(\.text), ["Second"])

    store.clear()
    XCTAssertTrue(store.entries.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    let reloaded = DictationHistoryStore(fileURL: fileURL)
    XCTAssertTrue(reloaded.entries.isEmpty)
  }

  func testHistoryFileIsOwnerOnly() throws {
    _ = DictationHistoryStore(fileURL: fileURL).record(text: "Sensitive")
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
    XCTAssertEqual(permissions.intValue & 0o777, 0o600)
  }
}
