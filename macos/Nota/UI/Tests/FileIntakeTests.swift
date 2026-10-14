import XCTest
@testable import Nota

/// Whether Nota may take a file in, and what it says when it may not
/// (PT-1, FB-3).
///
/// `NotaModel` cannot be built in a test (its init sweeps the real `~/.nota`),
/// so the decision is `FileIntake`, pure, and the wiring — that ⌘O and
/// `accept(_:)` ask it, and ask it first — is read off the source.
final class FileIntakeTests: XCTestCase {
  // MARK: - PT-1: one predicate, asked by every way a file arrives

  /// The whole matrix. A running file transcription refuses, and so does a
  /// live session the window is showing (which covers a starting one: that is
  /// `LivePhaseGate`'s answer, passed in as `liveSessionShown`).
  func testAFileIsTakenOnlyWhenNothingIsRunningAndNoSessionIsShown() {
    XCTAssertTrue(FileIntake.isOpen(isRunning: false, liveSessionShown: false))
    XCTAssertFalse(FileIntake.isOpen(isRunning: true, liveSessionShown: false))
    XCTAssertFalse(FileIntake.isOpen(isRunning: false, liveSessionShown: true))
    XCTAssertFalse(FileIntake.isOpen(isRunning: true, liveSessionShown: true))

    // The live half is the window's own gate: starting refuses, handed-off
    // (Stop brought the window home) does not.
    let starting = LivePhaseGate.showsLiveSession(isStarting: true, sessionIsIdle: true, handedOff: false)
    let recording = LivePhaseGate.showsLiveSession(isStarting: false, sessionIsIdle: false, handedOff: false)
    let handedOff = LivePhaseGate.showsLiveSession(isStarting: false, sessionIsIdle: false, handedOff: true)
    XCTAssertFalse(FileIntake.isOpen(isRunning: false, liveSessionShown: starting))
    XCTAssertFalse(FileIntake.isOpen(isRunning: false, liveSessionShown: recording))
    XCTAssertTrue(FileIntake.isOpen(isRunning: false, liveSessionShown: handedOff))
  }

  /// ⌘O is disabled from `canTakeFile`, `accept(_:)` refuses on `canTakeFile`
  /// before the dismissal policy runs, and `canTakeFile` is `FileIntake.isOpen`
  /// over the window's live gate. ⌘O used to carry no `.disabled` at all, so
  /// during a live meeting it started a second paid pipeline behind the pane.
  func testTheOpenCommandAndAcceptAskTheSamePredicateFirst() {
    let model = Self.source("App/NotaModel.swift")
    let app = Self.source("App/NotaApp.swift")

    let predicate = Self.body(of: "var canTakeFile: Bool", in: model)
    XCTAssertTrue(predicate.contains("FileIntake.isOpen("), "canTakeFile no longer asks FileIntake")
    XCTAssertTrue(predicate.contains("LivePhaseGate.showsLiveSession("), "canTakeFile no longer asks the window's gate")

    let accept = Self.body(of: "func accept(", in: model)
    let guardAt = accept.range(of: "canTake: canTakeFile")
    let dismissalAt = accept.range(of: "requestSummaryRailDismissal")
    XCTAssertNotNil(guardAt, "accept(_:) no longer refuses on canTakeFile")
    XCTAssertNotNil(dismissalAt, "accept(_:) no longer runs the dismissal policy")
    if let guardAt, let dismissalAt {
      XCTAssertLessThan(
        guardAt.lowerBound, dismissalAt.lowerBound,
        "a refused file would close the Details panel before being refused"
      )
    }
    XCTAssertTrue(accept.contains("presentOwnerAlert(refusal)"), "a refusal is silent again")

    let command = Self.body(of: "private struct TranscribeFileCommand", in: app)
    XCTAssertTrue(command.contains("Button(\"Transcribe File…\")"))
    XCTAssertTrue(command.contains(".keyboardShortcut(\"o\")"))
    XCTAssertTrue(command.contains(".disabled(!model.canTakeFile)"), "⌘O is live during a run or a session again")
    XCTAssertTrue(command.contains("@ObservedObject var liveSession"), "⌘O cannot see the session change")
    XCTAssertTrue(app.contains("TranscribeFileCommand(model: model, liveSession: model.liveSession)"))
    // Exactly one "Transcribe File…" item: the one above.
    XCTAssertEqual(app.components(separatedBy: "Button(\"Transcribe File…\")").count - 1, 1)
  }

  // MARK: - FB-3: a refusal is said, and a double delivery is not one

  func testABusyRefusalNamesTheFileAndWhatIsRunning() {
    let dropped = URL(fileURLWithPath: "/tmp/b.m4a")
    let running = URL(fileURLWithPath: "/tmp/a.m4a")

    XCTAssertEqual(
      FileIntake.decide(
        fileURL: dropped, fileName: "b.m4a", canTake: true,
        isRunning: false, runningURL: nil, runningName: ""
      ),
      .take
    )

    guard case .refuse(let midRun) = FileIntake.decide(
      fileURL: dropped, fileName: "b.m4a", canTake: false,
      isRunning: true, runningURL: running, runningName: "a.m4a"
    ) else { return XCTFail("a file arriving mid-run was taken") }
    XCTAssertEqual(midRun.title, "“b.m4a” was not opened")
    XCTAssertTrue(midRun.message.contains("transcribing “a.m4a”"), midRun.message)

    guard case .refuse(let midSession) = FileIntake.decide(
      fileURL: dropped, fileName: "b.m4a", canTake: false,
      isRunning: false, runningURL: nil, runningName: ""
    ) else { return XCTFail("a file arriving during a session was taken") }
    XCTAssertEqual(midSession.title, "“b.m4a” was not opened")
    XCTAssertTrue(midSession.message.contains("recording session"), midSession.message)
  }

  /// A Finder open can reach `accept` twice; the second copy finds its own
  /// file running and must not tell the owner that file was turned away.
  func testTheFileAlreadyRunningArrivingAgainIsNotRefused() {
    let running = URL(fileURLWithPath: "/tmp/sub/../a.m4a")
    XCTAssertEqual(
      FileIntake.decide(
        fileURL: URL(fileURLWithPath: "/tmp/a.m4a"), fileName: "a.m4a", canTake: false,
        isRunning: true, runningURL: running, runningName: "a.m4a"
      ),
      .ignore
    )
    // Only while it is the RUNNING file: during a session it is refused.
    if case .ignore = FileIntake.decide(
      fileURL: URL(fileURLWithPath: "/tmp/a.m4a"), fileName: "a.m4a", canTake: false,
      isRunning: false, runningURL: running, runningName: "a.m4a"
    ) {
      XCTFail("a file arriving during a live session was dropped silently")
    }
  }

  // MARK: - Source helpers

  /// A file under `macos/Nota/`, found relative to this source file.
  private static func source(_ path: String) -> String {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // UI
      .deletingLastPathComponent()  // Nota
      .appendingPathComponent(path)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
  }

  /// A declaration's body: from its signature to the first closing brace back
  /// at a top-level member's two-space indent, or at column zero for a type.
  private static func body(of signature: String, in source: String) -> String {
    guard let start = source.range(of: signature) else { return "" }
    let terminator = signature.hasPrefix("private struct") || signature.hasPrefix("struct")
      ? "\n}\n" : "\n  }\n"
    guard let end = source.range(of: terminator, range: start.upperBound..<source.endIndex) else { return "" }
    return String(source[start.lowerBound..<end.upperBound])
  }
}
