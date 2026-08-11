import Foundation
import XCTest

@testable import Nota

/// The lifecycle status as a pure value: its wire form, its tolerance for
/// records written before it existed, and the transitions it will and will not
/// allow. No files, no session, no window server (XIA-430).
final class HistoryStatusTests: XCTestCase {
  // MARK: - Wire form (the contract with src/pipeline/history-status.ts)

  func testRawValuesAreExactlyTheStringsTheCLIWrites() {
    // These strings ARE the cross-process contract: `nota history show <id>`
    // has to report the status the app is displaying. Changing one here
    // without changing src/pipeline/history-status.ts silently splits the two
    // halves of the app in a way no compiler can see.
    XCTAssertEqual(HistoryStatus.recording.rawValue, "recording")
    XCTAssertEqual(HistoryStatus.transcribing.rawValue, "transcribing")
    XCTAssertEqual(HistoryStatus.transcribed.rawValue, "transcribed")
    XCTAssertEqual(HistoryStatus.summarizing.rawValue, "summarizing")
    XCTAssertEqual(HistoryStatus.done.rawValue, "done")
    XCTAssertEqual(HistoryStatus.failed(stage: .recording).rawValue, "failed:recording")
    XCTAssertEqual(HistoryStatus.failed(stage: .transcribing).rawValue, "failed:transcribing")
    XCTAssertEqual(HistoryStatus.failed(stage: .summarizing).rawValue, "failed:summarizing")
  }

  func testEveryStatusRoundTripsThroughItsRawValue() {
    for status in HistoryStatus.allCases {
      XCTAssertEqual(HistoryStatus(rawValue: status.rawValue), status)
    }
    XCTAssertEqual(HistoryStatus.allCases.count, 8)
  }

  func testAnUnnameableStatusIsRefusedRatherThanGuessed() {
    XCTAssertNil(HistoryStatus(rawValue: "uploading"))
    XCTAssertNil(HistoryStatus(rawValue: "failed"))
    XCTAssertNil(HistoryStatus(rawValue: "failed:uploading"))
    XCTAssertNil(HistoryStatus(rawValue: ""))
  }

  // MARK: - The machine

  func testInFlightIsExactlyTheStagesAProcessWorksOn() {
    XCTAssertTrue(HistoryStatus.recording.isInFlight)
    XCTAssertTrue(HistoryStatus.transcribing.isInFlight)
    XCTAssertTrue(HistoryStatus.summarizing.isInFlight)
    // A rest state: nobody is working, and nothing is wrong.
    XCTAssertFalse(HistoryStatus.transcribed.isInFlight)
    XCTAssertFalse(HistoryStatus.done.isInFlight)
    XCTAssertFalse(HistoryStatus.failed(stage: .recording).isInFlight)
  }

  func testTerminalIsDoneAndEveryFailureAndNothingElse() {
    let terminal = HistoryStatus.allCases.filter(\.isTerminal)
    XCTAssertEqual(
      Set(terminal.map(\.rawValue)),
      ["done", "failed:recording", "failed:transcribing", "failed:summarizing"]
    )
  }

  func testTheHappyPathIsWalkedOneStepAtATime() {
    XCTAssertTrue(HistoryStatus.recording.canAdvance(to: .transcribing))
    XCTAssertTrue(HistoryStatus.transcribing.canAdvance(to: .transcribed))
    XCTAssertTrue(HistoryStatus.transcribed.canAdvance(to: .summarizing))
    XCTAssertTrue(HistoryStatus.summarizing.canAdvance(to: .done))
    // A memo summarizes straight off the stream, without resting.
    XCTAssertTrue(HistoryStatus.transcribing.canAdvance(to: .summarizing))
  }

  func testStagesCannotBeSkippedOrWalkedBackwards() {
    XCTAssertFalse(HistoryStatus.recording.canAdvance(to: .done))
    XCTAssertFalse(HistoryStatus.recording.canAdvance(to: .summarizing))
    XCTAssertFalse(HistoryStatus.recording.canAdvance(to: .transcribed))
    XCTAssertFalse(HistoryStatus.summarizing.canAdvance(to: .transcribing))
    XCTAssertFalse(HistoryStatus.transcribed.canAdvance(to: .recording))
  }

  func testATerminalStatusAcceptsNothingAtAll() {
    for terminal in HistoryStatus.allCases.filter(\.isTerminal) {
      for next in HistoryStatus.allCases {
        XCTAssertFalse(
          terminal.canAdvance(to: next),
          "\(terminal.rawValue) must not advance to \(next.rawValue)"
        )
      }
    }
  }

  func testARecordMayOnlyFailInTheStageItIsIn() {
    XCTAssertTrue(HistoryStatus.recording.canAdvance(to: .failed(stage: .recording)))
    XCTAssertTrue(HistoryStatus.transcribing.canAdvance(to: .failed(stage: .transcribing)))
    XCTAssertTrue(HistoryStatus.summarizing.canAdvance(to: .failed(stage: .summarizing)))
    // Waiting for a summary, so the summary is what can fail.
    XCTAssertTrue(HistoryStatus.transcribed.canAdvance(to: .failed(stage: .summarizing)))

    XCTAssertFalse(HistoryStatus.recording.canAdvance(to: .failed(stage: .summarizing)))
    XCTAssertFalse(HistoryStatus.transcribed.canAdvance(to: .failed(stage: .recording)))
    XCTAssertFalse(HistoryStatus.summarizing.canAdvance(to: .failed(stage: .transcribing)))
  }

  func testAStatusNeverAdvancesToItself() {
    for status in HistoryStatus.allCases {
      XCTAssertFalse(status.canAdvance(to: status))
    }
  }

  // MARK: - Interrupted resolution

  func testAnInterruptedRecordResolvesToTheFailureOfItsOwnStage() {
    XCTAssertEqual(HistoryStatus.recording.interruptedResolution, .failed(stage: .recording))
    XCTAssertEqual(HistoryStatus.transcribing.interruptedResolution, .failed(stage: .transcribing))
    XCTAssertEqual(HistoryStatus.summarizing.interruptedResolution, .failed(stage: .summarizing))
  }

  func testNothingAtRestWasInterrupted() {
    XCTAssertNil(HistoryStatus.transcribed.interruptedResolution)
    XCTAssertNil(HistoryStatus.done.interruptedResolution)
    XCTAssertNil(HistoryStatus.failed(stage: .transcribing).interruptedResolution)
  }

  func testEveryResolutionIsALegalTransitionFromWhatItResolves() {
    // The sweep writes through `updateStatus`, which refuses illegal moves —
    // a resolution the machine rejected would silently do nothing.
    for status in HistoryStatus.allCases {
      guard let resolution = status.interruptedResolution else { continue }
      XCTAssertTrue(
        status.canAdvance(to: resolution),
        "\(status.rawValue) cannot reach its own resolution \(resolution.rawValue)"
      )
    }
  }

  // MARK: - Tolerant decode of a legacy record

  func testTheLegacyCompletedSpellingBecomesDone() {
    XCTAssertEqual(HistoryStatus.normalized("completed", hasSummary: true), .done)
    XCTAssertEqual(HistoryStatus.normalized("completed", hasSummary: false), .done)
  }

  func testTranscribedKeepsItsNameBecauseItMeansWhatItAlwaysMeant() {
    XCTAssertEqual(HistoryStatus.normalized("transcribed", hasSummary: false), .transcribed)
  }

  func testAnAbsentOrUnknownStatusResolvesByWhatTheRecordHas() {
    XCTAssertEqual(HistoryStatus.normalized(nil, hasSummary: true), .done)
    XCTAssertEqual(HistoryStatus.normalized(nil, hasSummary: false), .transcribed)
    XCTAssertEqual(HistoryStatus.normalized("archived", hasSummary: true), .done)
    XCTAssertEqual(HistoryStatus.normalized("", hasSummary: false), .transcribed)
  }

  func testALegacyRecordNeverDecodesIntoALiveStage() {
    // A legacy record that read as in-flight would be swept up as
    // "Interrupted" at the next launch, on every machine, forever.
    for raw in [nil, "", "completed", "transcribed", "archived", "42"] as [String?] {
      for hasSummary in [true, false] {
        XCTAssertFalse(
          HistoryStatus.normalized(raw, hasSummary: hasSummary).isInFlight,
          "raw=\(raw ?? "nil") hasSummary=\(hasSummary)"
        )
      }
    }
  }

  func testDecodingStraightOffARecordDictionary() {
    XCTAssertEqual(
      HistoryStatus.normalized(fromRecord: ["status": "summarizing"]),
      .summarizing
    )
    // A legacy record: no status field, but it carries a summary.
    XCTAssertEqual(
      HistoryStatus.normalized(fromRecord: ["summary": ["title": "T"]]),
      .done
    )
    XCTAssertEqual(HistoryStatus.normalized(fromRecord: [:]), .transcribed)
    // A status of the wrong TYPE is as unreadable as an unknown one.
    XCTAssertEqual(HistoryStatus.normalized(fromRecord: ["status": 7]), .transcribed)
  }

  // MARK: - Presentation

  func testAnInterruptedFailureReadsAsInterruptedRatherThanAsAFailedStage() {
    XCTAssertEqual(
      HistoryStatus.failed(stage: .recording).presentation(interrupted: true),
      "Interrupted"
    )
    XCTAssertEqual(
      HistoryStatus.failed(stage: .summarizing).presentation(interrupted: true),
      "Interrupted"
    )
    XCTAssertEqual(
      HistoryStatus.failed(stage: .recording).presentation(),
      "Failed (recording)"
    )
  }

  func testEveryStatusHasWordsAndNoneOfThemAreEmpty() {
    for status in HistoryStatus.allCases {
      XCTAssertFalse(status.presentation().isEmpty, status.rawValue)
    }
    XCTAssertEqual(HistoryStatus.recording.presentation(), "Recording")
    XCTAssertEqual(HistoryStatus.transcribing.presentation(), "Transcribing")
    XCTAssertEqual(HistoryStatus.done.presentation(), "Done")
  }
}
