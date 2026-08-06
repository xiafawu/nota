import Foundation
import XCTest

@testable import Nota

/// XIA-435 — Stop is a handoff, not a wait.
///
/// Everything asserted here is a pure decision or a plain `@MainActor` object:
/// `NotaModel.init` sweeps the real `~/.nota` and runs preflight, so no test
/// may build one. The rules therefore live in `BackgroundProcessing.swift` and
/// the model is a thin delegator over them — the same shape XIA-430 used for
/// `LiveSessionOwner`.
@MainActor
final class BackgroundProcessingTests: XCTestCase {

  // MARK: - Stop lands home, whatever the length

  func testStopReturnsHomeImmediately_regardlessOfSession() {
    // The handoff flag alone decides, so the pane leaves the live phase on the
    // press — with the session still `.stopping` and even still `.recording`.
    XCTAssertFalse(LivePhaseGate.showsLiveSession(
      isStarting: false,
      sessionIsIdle: false,
      handedOff: true
    ))
    XCTAssertFalse(LivePhaseGate.showsLiveSession(
      isStarting: true,
      sessionIsIdle: false,
      handedOff: true
    ))
  }

  func testLivePhase_pinsForStartAndForALiveSession() {
    XCTAssertTrue(LivePhaseGate.showsLiveSession(
      isStarting: true,
      sessionIsIdle: true,
      handedOff: false
    ))
    XCTAssertTrue(LivePhaseGate.showsLiveSession(
      isStarting: false,
      sessionIsIdle: false,
      handedOff: false
    ))
    XCTAssertFalse(LivePhaseGate.showsLiveSession(
      isStarting: false,
      sessionIsIdle: true,
      handedOff: false
    ))
  }

  // MARK: - The row is the progress UI

  func testFreshnessLine_namesTheStageAndTheStamp() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    XCTAssertEqual(
      ProcessingFreshness.line(status: .summarizing, updatedAt: start, now: start + 8),
      "Summarizing… · updated 8s ago"
    )
    XCTAssertEqual(
      ProcessingFreshness.line(status: .transcribing, updatedAt: start, now: start + 0.2),
      "Transcribing… · updated just now"
    )
  }

  func testStamp_stepsThroughSecondsMinutesHours() {
    let start = Date(timeIntervalSince1970: 0)
    XCTAssertEqual(ProcessingFreshness.stamp(since: start, now: start + 59), "updated 59s ago")
    XCTAssertEqual(ProcessingFreshness.stamp(since: start, now: start + 60), "updated 1m ago")
    XCTAssertEqual(ProcessingFreshness.stamp(since: start, now: start + 3600), "updated 1h ago")
    XCTAssertEqual(
      ProcessingFreshness.stamp(since: start, now: start + 3600 + 4 * 60),
      "updated 1h 4m ago"
    )
    // Clock skew reads as "just now", never as a negative age.
    XCTAssertEqual(ProcessingFreshness.stamp(since: start, now: start - 30), "updated just now")
  }

  /// The stamp is the progress indicator precisely because there is no
  /// percentage: a stalled stamp is the only thing that reveals a stuck
  /// pipeline, and a bar over a model call would hide it. Pinned as a fact
  /// about the wording — no digit may appear except the age itself.
  func testProgressLine_carriesNoPercentage() {
    let start = Date(timeIntervalSince1970: 0)
    for status in [HistoryStatus.recording, .transcribing, .summarizing] {
      let line = ProcessingFreshness.line(status: status, updatedAt: start, now: start + 8)
      XCTAssertNotNil(line)
      XCTAssertFalse(line!.contains("%"), "\(status.rawValue) drew a percentage")
    }
  }

  func testAtRestStatuses_showNoProgressLine() {
    let now = Date()
    XCTAssertNil(ProcessingFreshness.line(status: .done, updatedAt: now, now: now))
    XCTAssertNil(ProcessingFreshness.line(status: .transcribed, updatedAt: now, now: now))
    XCTAssertNil(ProcessingRowStatus.make(
      status: .done,
      interrupted: false,
      updatedAt: now,
      now: now
    ))
  }

  /// Item 7's exact reading on the next launch.
  func testInterruptedSummary_readsAsSavedTranscriptWithARetry() {
    let now = Date()
    let row = ProcessingRowStatus.make(
      status: .failed(stage: .summarizing),
      interrupted: true,
      updatedAt: now,
      now: now
    )
    XCTAssertEqual(row?.text, "Interrupted · transcript saved")
    XCTAssertEqual(row?.tone, .failure)
    XCTAssertEqual(row?.retry, .summary)
  }

  func testFailedSummary_offersARetry_failedRecordingDoesNot() {
    let now = Date()
    XCTAssertEqual(
      ProcessingRowStatus.make(
        status: .failed(stage: .summarizing),
        interrupted: false,
        updatedAt: now,
        now: now
      )?.retry,
      .summary
    )
    // The realtime stream cannot be replayed, so there is no single stage to
    // re-run — and the audio is still on disk, which is what the row says.
    let recordingFailure = ProcessingRowStatus.make(
      status: .failed(stage: .recording),
      interrupted: false,
      updatedAt: now,
      now: now
    )
    XCTAssertNil(recordingFailure?.retry)
    XCTAssertTrue(recordingFailure!.text.contains("audio saved"))
  }

  // MARK: - Rows are independent; two records process at once

  func testTwoRecordsProcessConcurrently_eachAtItsOwnStage() {
    let ledger = ProcessingLedger()
    let t0 = Date(timeIntervalSince1970: 500)
    ledger.begin(recordID: "a", kind: .meeting, outputPath: nil, status: .transcribing, at: t0)
    ledger.begin(recordID: "b", kind: .memo, outputPath: nil, status: .transcribing, at: t0)

    ledger.advance(recordID: "a", to: .summarizing, at: t0 + 10)

    XCTAssertEqual(ledger.job(recordID: "a")?.status, .summarizing)
    XCTAssertEqual(ledger.job(recordID: "b")?.status, .transcribing)
    XCTAssertEqual(ledger.inFlight.count, 2)

    // Landing one leaves the other exactly where it was.
    ledger.advance(recordID: "a", to: .done, at: t0 + 20)
    XCTAssertEqual(ledger.job(recordID: "b")?.status, .transcribing)
    XCTAssertEqual(ledger.inFlight.map(\.recordID), ["b"])
  }

  func testBegin_refusesASecondJobForOneRecord() {
    let ledger = ProcessingLedger()
    XCTAssertTrue(ledger.begin(recordID: "a", kind: .meeting, outputPath: nil, status: .transcribing))
    XCTAssertFalse(ledger.begin(recordID: "a", kind: .meeting, outputPath: nil, status: .transcribing))
    XCTAssertEqual(ledger.jobs.count, 1)
  }

  // MARK: - A late result may not land on the wrong record

  /// The session-epoch rule, restated for records and made structural: every
  /// mutation is addressed by record id, and an id the ledger does not hold is
  /// refused. There is no "advance the current job" entry point to get wrong,
  /// so a summary returning after the owner started a NEW recording cannot
  /// reach it — the new session's record was never admitted (a live record is
  /// owned by `LiveSessionOwner` and enters the ledger only at Stop).
  func testLateResult_cannotTouchARecordTheLedgerDoesNotHold() {
    let ledger = ProcessingLedger()
    ledger.begin(recordID: "old", kind: .meeting, outputPath: nil, status: .summarizing)
    ledger.forget(recordID: "old")

    // The task that was started for "old" comes back after the owner has begun
    // recording "new". Both calls are refused: one because the id is gone, one
    // because that id was never begun.
    XCTAssertFalse(ledger.advance(recordID: "old", to: .done))
    XCTAssertFalse(ledger.advance(recordID: "new", to: .done))
    XCTAssertFalse(ledger.attachOutput(recordID: "new", outputPath: "/tmp/x.summary.md"))
    XCTAssertTrue(ledger.jobs.isEmpty)
  }

  /// The other half: even for a record the ledger *does* hold, a completion may
  /// only refresh the list while a session is live. It may never rewrite the
  /// pane the microphone owns.
  func testCompletionEffect_neverTouchesTheWindowWhileASessionIsLive() {
    XCTAssertEqual(
      CompletionEffect.decide(
        jobOutputPath: "/out/a.summary.md",
        openOutputPath: "/out/a.summary.md",
        isLiveSessionActive: true
      ),
      .listOnly
    )
    XCTAssertEqual(
      CompletionEffect.decide(
        jobOutputPath: "/out/a.summary.md",
        openOutputPath: "/out/a.summary.md",
        isLiveSessionActive: false
      ),
      .reloadOpenDocument
    )
    XCTAssertEqual(
      CompletionEffect.decide(
        jobOutputPath: "/out/a.summary.md",
        openOutputPath: "/out/b.summary.md",
        isLiveSessionActive: false
      ),
      .listOnly
    )
    XCTAssertEqual(
      CompletionEffect.decide(
        jobOutputPath: "/out/a.summary.md",
        openOutputPath: nil,
        isLiveSessionActive: false
      ),
      .listOnly
    )
  }

  // MARK: - The title arrives last

  func testProvisionalTitles_areWhatARecordIsCalledUntilSummarized() {
    XCTAssertEqual(ProvisionalTitle.forKind(.meeting), "Untitled meeting")
    XCTAssertEqual(ProvisionalTitle.forKind(.memo), "Untitled memo")
    XCTAssertTrue(ProvisionalTitle.isProvisional("Untitled meeting"))
    XCTAssertFalse(ProvisionalTitle.isProvisional("Q3 planning with Kenny"))
  }

  // MARK: - The notification

  private func job(
    _ id: String = "r1",
    status: HistoryStatus,
    notified: Bool = false
  ) -> ProcessingJob {
    ProcessingJob(
      recordID: id,
      kind: .meeting,
      outputPath: "/out/\(id).summary.md",
      status: status,
      interrupted: false,
      updatedAt: Date(),
      notified: notified
    )
  }

  func testNotification_firesWhenNotFrontmost() {
    let notice = CompletionNotifierPolicy.decide(
      job: job(status: .done),
      title: "Q3 planning",
      facts: "41 min · 2 speakers · 3 markers",
      appIsFrontmost: false
    )
    XCTAssertEqual(notice?.title, "Q3 planning")
    XCTAssertEqual(notice?.body, "41 min · 2 speakers · 3 markers")
    XCTAssertEqual(notice?.recordID, "r1")
    XCTAssertNil(notice?.retry)
  }

  func testNotification_doesNotFireWhenFrontmost() {
    XCTAssertNil(CompletionNotifierPolicy.decide(
      job: job(status: .done),
      title: "Q3 planning",
      facts: "41 min",
      appIsFrontmost: true
    ))
  }

  /// One per record, never per stage.
  func testNotification_firesOncePerRecord() {
    let ledger = ProcessingLedger()
    ledger.begin(recordID: "r1", kind: .meeting, outputPath: nil, status: .transcribing)
    XCTAssertTrue(ledger.markNotified(recordID: "r1"))
    XCTAssertFalse(ledger.markNotified(recordID: "r1"))

    XCTAssertNil(CompletionNotifierPolicy.decide(
      job: job(status: .done, notified: true),
      title: "Q3 planning",
      facts: "41 min",
      appIsFrontmost: false
    ))
  }

  /// A stage change is not news: only a landed record may interrupt.
  func testNotification_neverFiresForAnIntermediateStage() {
    for status in [HistoryStatus.recording, .transcribing, .summarizing] {
      XCTAssertNil(
        CompletionNotifierPolicy.decide(
          job: job(status: status),
          title: "Q3 planning",
          facts: "41 min",
          appIsFrontmost: false
        ),
        "\(status.rawValue) announced itself"
      )
    }
  }

  func testFailureNotification_carriesItsRetry() {
    let notice = CompletionNotifierPolicy.decide(
      job: job(status: .failed(stage: .summarizing)),
      title: "Untitled meeting",
      facts: "41 min",
      appIsFrontmost: false
    )
    XCTAssertEqual(notice?.retry, .summary)
    XCTAssertEqual(notice?.body, "Summary failed. The transcript is saved.")

    // A recording failure has no single stage to re-run, so it carries none.
    XCTAssertNil(CompletionNotifierPolicy.decide(
      job: job(status: .failed(stage: .recording)),
      title: "Untitled meeting",
      facts: "",
      appIsFrontmost: false
    )?.retry)
  }

  func testCompletionFacts_dropAbsentAndZeroParts() {
    XCTAssertEqual(
      CompletionFacts.line(durationMinutes: 41, speakerCount: 2, markerCount: 3),
      "41 min · 2 speakers · 3 markers"
    )
    XCTAssertEqual(
      CompletionFacts.line(durationMinutes: 1, speakerCount: 1, markerCount: nil),
      "1 min · 1 speaker"
    )
    XCTAssertEqual(
      CompletionFacts.line(durationMinutes: 12, speakerCount: 0, markerCount: 0),
      "12 min"
    )
    XCTAssertEqual(CompletionFacts.line(durationMinutes: nil, speakerCount: nil, markerCount: nil), "")
  }

  // MARK: - ⌘Q

  func testQuitPrompt_asksNothingWhenNothingIsInFlight() {
    XCTAssertNil(QuitPrompt.decide(inFlight: []))
  }

  func testQuitPrompt_asksOnceAndPromisesTheTranscriptIsSaved() {
    let ask = QuitPrompt.decide(inFlight: [job(status: .summarizing)])
    XCTAssertEqual(ask?.messageText, "1 recording is still processing.")
    XCTAssertTrue(ask!.informativeText.contains("already saved"))
    XCTAssertTrue(ask!.informativeText.contains("retry"))
    XCTAssertEqual(ask?.quitButtonTitle, "Quit Anyway")

    let two = QuitPrompt.decide(inFlight: [
      job("a", status: .summarizing),
      job("b", status: .transcribing)
    ])
    XCTAssertEqual(two?.messageText, "2 recordings are still processing.")
  }

  /// The ledger's own `inFlight` is what ⌘Q asks, so a landed record must not
  /// be able to raise the prompt.
  func testQuitPrompt_ignoresLandedRecords() {
    let ledger = ProcessingLedger()
    ledger.begin(recordID: "a", kind: .meeting, outputPath: nil, status: .summarizing)
    XCTAssertNotNil(QuitPrompt.decide(inFlight: ledger.inFlight))
    ledger.advance(recordID: "a", to: .done)
    XCTAssertNil(QuitPrompt.decide(inFlight: ledger.inFlight))
  }

  // MARK: - The join between rows and records

  func testJobLookupByOutputPath_standardizesBothSides() {
    let ledger = ProcessingLedger()
    ledger.begin(recordID: "a", kind: .meeting, outputPath: nil, status: .transcribing)
    XCTAssertNil(ledger.job(outputPath: "/out/a.summary.md"))

    ledger.attachOutput(recordID: "a", outputPath: "/out/./a.summary.md")
    XCTAssertEqual(ledger.job(outputPath: "/out/a.summary.md")?.recordID, "a")
  }
}
