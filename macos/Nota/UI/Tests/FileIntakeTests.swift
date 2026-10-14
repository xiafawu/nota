import UniformTypeIdentifiers
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
        fileURL: dropped, fileName: "b.m4a", isSupported: true, canTake: true,
        isRunning: false, runningURL: nil, runningName: ""
      ),
      .take(note: nil)
    )

    guard case .refuse(let midRun) = FileIntake.decide(
      fileURL: dropped, fileName: "b.m4a", isSupported: true, canTake: false,
      isRunning: true, runningURL: running, runningName: "a.m4a"
    ) else { return XCTFail("a file arriving mid-run was taken") }
    XCTAssertEqual(midRun.title, "“b.m4a” was not opened")
    XCTAssertTrue(midRun.message.contains("transcribing “a.m4a”"), midRun.message)

    guard case .refuse(let midSession) = FileIntake.decide(
      fileURL: dropped, fileName: "b.m4a", isSupported: true, canTake: false,
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
        fileURL: URL(fileURLWithPath: "/tmp/a.m4a"), fileName: "a.m4a", isSupported: true, canTake: false,
        isRunning: true, runningURL: running, runningName: "a.m4a"
      ),
      .ignore
    )
    // Only while it is the RUNNING file: during a session it is refused.
    if case .ignore = FileIntake.decide(
      fileURL: URL(fileURLWithPath: "/tmp/a.m4a"), fileName: "a.m4a", isSupported: true, canTake: false,
      isRunning: false, runningURL: running, runningName: "a.m4a"
    ) {
      XCTFail("a file arriving during a live session was dropped silently")
    }
  }

  // MARK: - PT-2: a file Nota does not transcribe is refused, and said

  /// A dropped .avi used to light the target, be taken, and then do nothing:
  /// the refusal went to a status line drawn only during a run. It is an
  /// alert now, naming the file and every type Nota would have taken.
  func testAnUnsupportedFileIsRefusedNamingItAndEveryTypeNotaTakes() {
    XCTAssertTrue(FileIntake.isSupported(URL(fileURLWithPath: "/tmp/memo.QTA")))
    XCTAssertTrue(FileIntake.isSupported(URL(fileURLWithPath: "/tmp/a.m4a")))
    XCTAssertFalse(FileIntake.isSupported(URL(fileURLWithPath: "/tmp/clip.avi")))
    XCTAssertFalse(FileIntake.isSupported(URL(fileURLWithPath: "/tmp/notes.pdf")))
    XCTAssertFalse(FileIntake.isSupported(URL(fileURLWithPath: "/tmp/Folder", isDirectory: true)))

    let avi = URL(fileURLWithPath: "/tmp/clip.avi")
    // Refused whether or not anything else is going on — the type is the
    // answer worth giving first.
    for canTake in [true, false] {
      guard case .refuse(let refusal) = FileIntake.decide(
        fileURL: avi, fileName: "clip.avi", isSupported: false, canTake: canTake,
        isRunning: !canTake, runningURL: nil, runningName: "a.m4a"
      ) else { return XCTFail("an unsupported file was taken (canTake: \(canTake))") }
      XCTAssertEqual(refusal.title, "Nota can't transcribe “clip.avi”")
      for ext in supportedExtensions {
        XCTAssertTrue(refusal.message.contains(ext.uppercased()), "\(ext) missing: \(refusal.message)")
      }
    }
    XCTAssertEqual(FileIntake.supportedTypesList(["mp3"]), "MP3")
    XCTAssertEqual(FileIntake.supportedTypesList(["wav", "mp3", "aac"]), "AAC, MP3 and WAV")
  }

  /// The check runs in `accept`, ahead of the summary rail's dismissal policy
  /// (a file about to be refused could close the Details panel or raise its
  /// Keep Editing alert), and the old silent branch in `performAccept` is gone.
  func testTheTypeIsCheckedInAcceptBeforeTheDismissalPolicy() {
    let model = Self.source("App/NotaModel.swift")
    let accept = Self.body(of: "func accept(", in: model)
    let checkAt = accept.range(of: "isSupported: isSupportedAudio(fileURL)")
    let dismissalAt = accept.range(of: "requestSummaryRailDismissal")
    XCTAssertNotNil(checkAt, "accept(_:) no longer checks the type")
    if let checkAt, let dismissalAt {
      XCTAssertLessThan(checkAt.lowerBound, dismissalAt.lowerBound)
    }
    XCTAssertFalse(model.contains("status = \"Unsupported file type\""), "the invisible refusal is back")
    XCTAssertTrue(
      Self.body(of: "private func isSupportedAudio(", in: model).contains("FileIntake.isSupported(")
    )
  }

  /// The panel is built from the one list. It used to offer `.audio` and
  /// `.movie` whole, so .avi was offered and then refused.
  func testTheOpenPanelOffersTheSupportedTypesAndNothingWider() {
    let types = FileIntake.openPanelTypes()
    for ext in supportedExtensions {
      guard let type = UTType(filenameExtension: ext) else { continue }
      XCTAssertTrue(types.contains(type), "\(ext) is not openable from the panel")
    }
    XCTAssertFalse(types.contains(.audio))
    XCTAssertFalse(types.contains(.movie))
    XCTAssertFalse(types.contains(.data), "every file is offered again")
    let avi = UTType(filenameExtension: "avi")!
    XCTAssertFalse(types.contains { avi.conforms(to: $0) }, ".avi is offered and then refused")

    // A system that declares nothing for .qta still lets it be opened — the
    // last-resort `.data`, which `accept`'s own check then guards.
    let undeclared = FileIntake.openPanelTypes(extensions: ["m4a", "qta"]) {
      $0 == "qta" ? nil : UTType(filenameExtension: $0)
    }
    XCTAssertTrue(undeclared.contains(.data), ".qta became unopenable")
    XCTAssertTrue(undeclared.contains(UTType(filenameExtension: "m4a")!))

    let chooser = Self.body(of: "func chooseFile(", in: Self.source("App/NotaModel.swift"))
    XCTAssertTrue(chooser.contains("panel.allowedContentTypes = FileIntake.openPanelTypes()"))
  }

  /// **The panel and `accept` agree item by item.** A type admits whatever
  /// conforms to it, so `.mp4`'s `public.mpeg-4` offered .m4v and `.ogg`'s
  /// type offered .opus and .oga — each then refused by `accept`. The panel's
  /// second gate asks the extension check itself.
  func testTheOpenPanelGreysOutWhatAcceptWouldRefuse() {
    func enables(_ path: String, directory: Bool = false) -> Bool {
      FileIntake.enablesInOpenPanel(URL(fileURLWithPath: path), isDirectory: directory)
    }
    for ext in supportedExtensions {
      XCTAssertTrue(enables("/tmp/a.\(ext)"), ".\(ext) is greyed out but accepted")
      XCTAssertTrue(enables("/tmp/A.\(ext.uppercased())"), "an upper-case .\(ext) is greyed out")
    }
    for ext in ["m4v", "opus", "oga", "avi", "txt", "pdf"] {
      XCTAssertFalse(enables("/tmp/a.\(ext)"), ".\(ext) is offered and then refused")
    }
    XCTAssertTrue(enables("/tmp/Recordings", directory: true), "a folder cannot be opened to browse")
    XCTAssertTrue(enables("/tmp/Meetings.m4v", directory: true), "a folder is named like a file")

    // Whatever the panel's types admit beyond the list, the gate refuses: the
    // two gates together offer exactly what `accept` takes.
    let types = FileIntake.openPanelTypes()
    for ext in ["m4v", "opus", "oga", "m4b", "aifc", "3gp", "mpg"] {
      guard let type = UTType(filenameExtension: ext),
        types.contains(where: { type.conforms(to: $0) })
      else { continue }
      XCTAssertFalse(enables("/tmp/a.\(ext)"), "the panel's types admit .\(ext) and nothing refuses it")
    }

    // A supported file never pays the disk read the folder check makes.
    var stats = 0
    func isDirectory() -> Bool {
      stats += 1
      return false
    }
    _ = FileIntake.enablesInOpenPanel(URL(fileURLWithPath: "/tmp/a.m4a"), isDirectory: isDirectory())
    XCTAssertEqual(stats, 0)
    _ = FileIntake.enablesInOpenPanel(URL(fileURLWithPath: "/tmp/a.txt"), isDirectory: isDirectory())
    XCTAssertEqual(stats, 1)

    // The panel is told: the delegate is set, kept alive for the modal run
    // (`delegate` is weak), and decides through the pure check above.
    let model = Self.source("App/NotaModel.swift")
    let chooser = Self.body(of: "func chooseFile(", in: model)
    XCTAssertTrue(chooser.contains("panel.delegate = gate"), "the panel has no second gate")
    XCTAssertTrue(
      chooser.contains("withExtendedLifetime(gate, { panel.runModal() })"),
      "the gate can be released before the panel lists anything")
    XCTAssertTrue(
      Self.body(of: "private final class OpenPanelGate", in: model)
        .contains("FileIntake.enablesInOpenPanel("),
      "the gate decides something other than what accept checks")
  }

  /// Three files dropped at once: the first was taken and the other two
  /// vanished without a sign. Now the first is taken and the rest are named
  /// as not opened — and every way several files arrive passes the count.
  func testAMultiFileDropSaysOnlyTheFirstWasTaken() {
    let a = URL(fileURLWithPath: "/tmp/a.m4a")
    XCTAssertEqual(
      FileIntake.decide(
        fileURL: a, fileName: "a.m4a", isSupported: true, alsoDropped: 0, canTake: true,
        isRunning: false, runningURL: nil, runningName: ""
      ),
      .take(note: nil)
    )
    guard case .take(let note?) = FileIntake.decide(
      fileURL: a, fileName: "a.m4a", isSupported: true, alsoDropped: 2, canTake: true,
      isRunning: false, runningURL: nil, runningName: ""
    ) else { return XCTFail("a three-file drop said nothing about two of them") }
    XCTAssertEqual(note.title, "Only “a.m4a” was opened")
    XCTAssertTrue(note.message.contains("the other 2 files were not opened"), note.message)
    XCTAssertTrue(
      FileIntake.onlyFirstNote(fileName: "a.m4a", alsoDropped: 1)?.message
        .contains("the other file was not opened") ?? false
    )
    // A refused first file says the rest went nowhere either.
    XCTAssertTrue(
      FileIntake.unsupportedRefusal(fileName: "x.pdf", alsoDropped: 1).message
        .hasSuffix("The other file was not opened either.")
    )

    // The note is said only once the file is in (inside the dismissal
    // closure), and each multi-file route passes its count.
    let model = Self.source("App/NotaModel.swift")
    XCTAssertTrue(Self.body(of: "func accept(", in: model).contains("if let note { self?.presentOwnerAlert(note) }"))
    XCTAssertTrue(model.contains("self.accept(first, alsoDropped: urls.count - 1)"))
    XCTAssertTrue(Self.source("UI/MainPaneView.swift").contains("let alsoDropped = providers.count - 1"))
    XCTAssertTrue(Self.source("UI/HomeDashboardView.swift").contains("model.accept(url, alsoDropped: alsoDropped)"))
    XCTAssertEqual(
      Self.source("UI/ContentView.swift")
        .components(separatedBy: "model.accept(url, alsoDropped: others)").count - 1,
      3
    )
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
