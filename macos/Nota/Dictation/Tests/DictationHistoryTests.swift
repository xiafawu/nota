import AppKit
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

/// **A copy says whether it landed** (FB-6). The drawer row's expansion is the
/// receipt of this copy (decision 16), and it used to appear whether or not
/// the write reached the pasteboard: the result went only to a published
/// notice that nothing read (deleted since, FB-1). A private named pasteboard
/// keeps the owner's clipboard out of it.
@MainActor
final class DictationHistoryCopyTests: XCTestCase {
  private var directory: URL!
  private var pasteboard: NSPasteboard!

  override func setUp() {
    super.setUp()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("nota-dictation-copy-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    pasteboard = NSPasteboard(name: NSPasteboard.Name("nota-tests-\(UUID().uuidString)"))
  }

  override func tearDown() {
    pasteboard.releaseGlobally()
    pasteboard = nil
    try? FileManager.default.removeItem(at: directory)
    super.tearDown()
  }

  func testTheCopyReportsWhetherTheTextLanded() throws {
    let store = DictationHistoryStore(
      fileURL: directory.appendingPathComponent("dictation-history.json"))
    let id = try XCTUnwrap(store.record(text: "Ship the drawer fix"))
    let controller = DictationController(review: StubReviewPresenter(), historyStore: store)

    XCTAssertTrue(controller.copyDictationHistory(id, to: pasteboard))
    XCTAssertEqual(pasteboard.string(forType: .string), "Ship the drawer fix")

    XCTAssertFalse(
      controller.copyDictationHistory(UUID(), to: pasteboard),
      "a copy of an entry that is not there claimed success")
  }
}

/// **A failed Insert Again reaches the failure state** (FB-1). The retry's
/// reason used to be written to a published notice that nothing read, beside
/// the `state` write that actually surfaces it. The notice is gone, so the
/// only route left must keep working: the reason lands in `.failed(message:)`
/// and on the entry, for both ways a retry fails. The target resolver is
/// injected so the test never reads the owner's frontmost app.
@MainActor
final class DictationHistoryRetryTests: XCTestCase {
  private var directory: URL!

  override func setUp() {
    super.setUp()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("nota-dictation-retry-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: directory)
    super.tearDown()
  }

  private func makeController() throws -> (DictationController, DictationHistoryStore, UUID) {
    let store = DictationHistoryStore(
      fileURL: directory.appendingPathComponent("dictation-history.json"))
    let id = try XCTUnwrap(store.record(text: "Ship the drawer fix"))
    return (DictationController(review: StubReviewPresenter(), historyStore: store), store, id)
  }

  /// The retry lands its outcome on a Task, so wait for the failure rather
  /// than for a fixed time.
  private func failure(of controller: DictationController) async -> String? {
    for _ in 0..<300 {
      if case .failed(let message) = controller.state { return message }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return nil
  }

  func testARetryWithNoTargetReachesTheFailureState() async throws {
    let (controller, store, id) = try makeController()

    controller.retryDictationHistory(id, resolvingTarget: { _ in nil })

    let message = await failure(of: controller)
    XCTAssertEqual(
      message, "Open the app where you want the dictation inserted, then try again.")
    XCTAssertEqual(store.entry(id: id)?.status, .failed)
  }

  func testARetryTheInjectorRefusesReachesTheFailureState() async throws {
    let (controller, store, id) = try makeController()
    let secureField = FocusedTarget(
      bundleID: "com.apple.TextEdit",
      isSecureInput: true,
      accessibilityElement: nil,
      processID: 4242
    )

    controller.retryDictationHistory(id, resolvingTarget: { _ in secureField })

    let message = await failure(of: controller)
    XCTAssertEqual(message, "Cannot dictate into a password or secure field")
    XCTAssertEqual(store.entry(id: id)?.status, .failed)
  }
}

/// **Both verbs on a recent dictation are reachable with VoiceOver or Switch
/// Control** (PT-3, FS-1, KB-5) — named actions, which Full Keyboard Access
/// alone does not reach. The menu-bar row picks its verb by hover (decision 24),
/// and a keyboard or VoiceOver press never hovers — so it always copied and
/// Insert Again had no route at all. Read from the source: the row is private,
/// and SwiftUI publishes no accessibility tree for an unhosted hosting view.
final class RecentDictationRowAccessibilityTests: XCTestCase {
  func testCopyAndInsertAgainAreNamedActionsOnTheRow() throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("DictationMenuBarView.swift")
    let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    let start = try XCTUnwrap(
      source.range(of: "private struct RecentDictationRow: View {"),
      "could not find the recent-dictation row in DictationMenuBarView.swift")
    let end = try XCTUnwrap(source.range(of: "\n}\n", range: start.upperBound..<source.endIndex))
    let row = String(source[start.lowerBound..<end.upperBound])
    XCTAssertTrue(
      row.contains(".accessibilityAction(named: \"Insert Again\") { onInsertAgain() }"),
      "Insert Again is reachable only by a pointer hovering the row")
    XCTAssertTrue(
      row.contains(".accessibilityAction(named: \"Copy\") { onCopy() }"),
      "Copy is not named on the row")
  }
}
