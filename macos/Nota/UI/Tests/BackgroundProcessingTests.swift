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

  /// Renamed from `testStopReturnsHomeImmediately_regardlessOfSession`, which
  /// was offered as the evidence for the ticket's headline acceptance item and
  /// observed neither the stop path nor elapsed time. What a test in this
  /// harness *can* pin is the gate: `handedOff` beats every other input, and
  /// the decision takes no other input — so there is nowhere for a duration
  /// threshold to live. Exhaustive over the other two, because "for every other
  /// state" is the claim; a `handedOff` check placed after either of the other
  /// two branches turns this red.
  ///
  /// What it does NOT cover, and nothing here can: that the flag is assigned
  /// before the first `await` in `performStopLiveSession`. That is a source
  /// order fact about a method on a model no test may construct.
  func testHandedOff_leavesTheLivePhaseForEveryOtherState() {
    for isStarting in [true, false] {
      for sessionIsIdle in [true, false] {
        XCTAssertFalse(
          LivePhaseGate.showsLiveSession(
            isStarting: isStarting,
            sessionIsIdle: sessionIsIdle,
            handedOff: true
          ),
          "handed off but still live for isStarting=\(isStarting) idle=\(sessionIsIdle)"
        )
      }
    }
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

  // `testProgressLine_carriesNoPercentage` was deleted rather than repaired.
  // It asserted that a string built as "\(stage) · \(stamp)" contains no "%",
  // which no code path could have produced — a test that cannot fail, reading
  // as coverage. The no-percentage rule is enforced by the shape of the API
  // instead: `ProcessingFreshness` and `ProcessingRowStatus` take no numeric
  // argument anywhere, so a fraction cannot be passed in to be drawn. That is a
  // property of the declarations, not of a run, and it is stated where it is
  // enforced rather than pretended at here.

  /// The stamp is the progress indicator, so it has to keep moving while a
  /// record is worked on — a stalled stamp is the only signal a stuck pipeline
  /// gives. This is that fact, rather than the tautology it replaced: the line
  /// changes as the clock advances, for every in-flight stage.
  func testProgressLine_advancesWithTheClock() {
    let start = Date(timeIntervalSince1970: 0)
    for status in [HistoryStatus.recording, .transcribing, .summarizing] {
      let early = ProcessingFreshness.line(status: status, updatedAt: start, now: start + 3)
      let later = ProcessingFreshness.line(status: status, updatedAt: start, now: start + 47)
      XCTAssertEqual(early, "\(ProcessingFreshness.stageLabel(status)!) · updated 3s ago")
      XCTAssertNotEqual(early, later, "\(status.rawValue)'s stamp froze")
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

    // Landing one leaves the other exactly where it was. Landing is `forget`:
    // the ledger holds a record while there is work to do and lets it go when
    // there is not (see `inFlight`).
    ledger.advance(recordID: "a", to: .done, at: t0 + 20)
    ledger.forget(recordID: "a")
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

  // `testProvisionalTitles_areWhatARecordIsCalledUntilSummarized` was deleted.
  // Half of it restated two string literals back at a lookup table, and the
  // other half exercised `ProvisionalTitle.isProvisional` / `.all`, which no
  // production code ever called — so the predicate has been removed too
  // (nothing asks "has the title arrived?"; the row re-reading the `.md` IS
  // the signal). What is left, `forKind`, is a three-case constant table used
  // by the seal and by the notification's fallback title, and it is stated
  // plainly that no test covers it: a test of a constant table can only agree
  // with whatever the table currently says.

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
      CompletionFacts.line(duration: 2460, speakerCount: 2, markerCount: 3),
      "41:00 · 2 speakers · 3 moments"
    )
    XCTAssertEqual(
      CompletionFacts.line(duration: 60, speakerCount: 1, markerCount: nil),
      "01:00 · 1 speaker"
    )
    XCTAssertEqual(
      CompletionFacts.line(duration: 720, speakerCount: 0, markerCount: 0),
      "12:00"
    )
    XCTAssertEqual(CompletionFacts.line(duration: nil, speakerCount: nil, markerCount: nil), "")
  }

  /// **The notification is not a third fact list** (XIA-429). It says the same
  /// words in the same order as the receipt that rises at Stop and the strip
  /// under the document header; one record may not be described three ways
  /// depending on where the owner happens to read it.
  func testCompletionFactsSaysWhatTheStripSays() {
    let record: [String: Any] = [
      "durationSeconds": 1122,
      "durationMinutes": 19,
      "segments": [["speaker": "A"], ["speaker": "B"], ["speaker": "C"]],
      "markers": [["at": 1], ["at": 2], ["at": 3], ["at": 4]]
    ]
    // …and the seconds win over the rounded-up minutes, or the banner says
    // 19 min for a session whose clock ended on 18:42.
    XCTAssertEqual(CompletionFacts.line(fromRecord: record), "18:42 · 3 speakers · 4 moments")
    XCTAssertEqual(
      CompletionFacts.line(fromRecord: record),
      RecordFacts(duration: 1122, speakerCount: 3, momentCount: 4).stripText,
      "the notification and the document's own strip disagree about one record"
    )
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

  /// The ledger's own `inFlight` is what ⌘Q asks, so a record it has let go
  /// must not be able to raise the prompt.
  func testQuitPrompt_ignoresRecordsTheLedgerHasLetGo() {
    let ledger = ProcessingLedger()
    ledger.begin(recordID: "a", kind: .meeting, outputPath: nil, status: .summarizing)
    XCTAssertNotNil(QuitPrompt.decide(inFlight: ledger.inFlight))
    ledger.advance(recordID: "a", to: .done)
    ledger.forget(recordID: "a")
    XCTAssertNil(QuitPrompt.decide(inFlight: ledger.inFlight))
  }

  /// ⌘Q's blind window, closed.
  ///
  /// Between the seal (which puts the job at `transcribed`, a **rest** state)
  /// and the summary claiming it (`summarizing`) there is a Task hop and a file
  /// write. Asking the *status* whether work was in flight answered no for that
  /// whole window, so a ⌘Q landing in it terminated with no prompt while a
  /// summary was about to start. The ledger holding the record is what "there
  /// is still work" means — only the ledger can know about work that has not
  /// begun.
  func testQuitPrompt_asksDuringTheGapBetweenTheSealAndTheSummary() {
    let ledger = ProcessingLedger()
    ledger.begin(recordID: "a", kind: .meeting, outputPath: nil, status: .transcribing)
    ledger.advance(recordID: "a", to: .transcribed)
    XCTAssertFalse(HistoryStatus.transcribed.isInFlight, "the premise: this is a rest state")
    XCTAssertNotNil(QuitPrompt.decide(inFlight: ledger.inFlight))
  }

  // MARK: - The join between rows and records

  func testJobLookupByOutputPath_standardizesBothSides() {
    let ledger = ProcessingLedger()
    ledger.begin(recordID: "a", kind: .meeting, outputPath: nil, status: .transcribing)
    XCTAssertNil(ledger.job(outputPath: "/out/a.summary.md"))

    ledger.attachOutput(recordID: "a", outputPath: "/out/./a.summary.md")
    XCTAssertEqual(ledger.job(outputPath: "/out/a.summary.md")?.recordID, "a")
  }

  // MARK: - Skip summary is about work Nota starts by itself

  /// The MAJOR defect, at the level it is decided.
  ///
  /// A record interrupted mid-summary reads "Interrupted · transcript saved"
  /// with a Retry. Pressing it with Skip summary on used to rewrite the record
  /// to `transcribed`, clear `interrupted`, and then run nothing — and
  /// `transcribed` offers no Retry, so the record's only recovery path was gone
  /// for good. A press is not automatic work.
  func testSkipSummary_stopsTheAutomaticRun_neverAPress() {
    XCTAssertFalse(SummaryTrigger.automatic.shouldRun(skipSummary: true))
    XCTAssertTrue(SummaryTrigger.automatic.shouldRun(skipSummary: false))
    XCTAssertTrue(SummaryTrigger.manualRetry.shouldRun(skipSummary: true))
    XCTAssertTrue(SummaryTrigger.manualRetry.shouldRun(skipSummary: false))
  }

  /// The other half of the same defect: the status is not touched until the
  /// work is going to happen, so a refused press leaves the failure — and its
  /// Retry — exactly where it was.
  func testRetryPlan_writesNothingUnlessTheSummaryWillRun() {
    XCTAssertEqual(
      RetrySummaryPlan.make(current: .failed(stage: .summarizing), isInLedger: false),
      .reopenThenRun
    )
    XCTAssertEqual(RetrySummaryPlan.make(current: .transcribed, isInLedger: false), .run)
    // Nothing else may be reopened by a summary retry: the stage that is re-run
    // has to be the stage that failed.
    XCTAssertEqual(RetrySummaryPlan.make(current: .done, isInLedger: false), .refuse)
    XCTAssertEqual(
      RetrySummaryPlan.make(current: .failed(stage: .transcribing), isInLedger: false),
      .refuse
    )
    XCTAssertEqual(RetrySummaryPlan.make(current: .recording, isInLedger: false), .refuse)
    // A record already being worked on is not started twice, whatever it says.
    XCTAssertEqual(
      RetrySummaryPlan.make(current: .failed(stage: .summarizing), isInLedger: true),
      .alreadyRunning
    )
  }

  /// A refused plan is a plan with no write in it. Pinned as an exhaustive
  /// fact over the enum so a fourth case cannot quietly acquire one.
  func testOnlyARunningPlanEverReopensTheRecord() {
    for status in HistoryStatus.allCases {
      let plan = RetrySummaryPlan.make(current: status, isInLedger: false)
      if plan == .reopenThenRun {
        XCTAssertEqual(status, .failed(stage: .summarizing))
      }
    }
  }

  // MARK: - A failure that fails before it has a row

  /// The MINOR silent-disappearance defect. Record 20 seconds muted, press
  /// Stop: the seal throws `.emptyTranscript`, the record settles at
  /// `failed:transcribing` with no `outputPath`, and rows are built from the
  /// output directory — so there is no row, no title to change, and (since Stop
  /// leaves the live pane on the press) no pane either. The frontmost
  /// suppression exists because the row's identity changing is already the
  /// signal; with no row there is no signal, so it does not apply.
  func testFailureWithNoRow_isAnnouncedEvenWhenNotaIsFrontmost() {
    let rowless = ProcessingJob(
      recordID: "r1",
      kind: .meeting,
      outputPath: nil,
      status: .failed(stage: .transcribing),
      interrupted: false,
      updatedAt: Date()
    )
    let notice = CompletionNotifierPolicy.decide(
      job: rowless,
      title: "Untitled meeting",
      facts: "",
      appIsFrontmost: true
    )
    XCTAssertEqual(notice?.body, "Transcription failed. The audio is saved.")
    XCTAssertNil(notice?.retry)

    // A record that DID write markdown keeps the old rule: its row says it.
    XCTAssertNil(CompletionNotifierPolicy.decide(
      job: job(status: .failed(stage: .summarizing)),
      title: "Q3 planning",
      facts: "",
      appIsFrontmost: true
    ))
  }

  /// And the window says it too, because a notification can be denied and
  /// because the owner is looking at the app.
  func testHandoffFailureMessage_onlyForAFailureWithNowhereElseToGo() {
    XCTAssertEqual(
      HandoffFailureNotice.message(status: .failed(stage: .transcribing), hasRow: false),
      "Transcription failed — the audio is saved."
    )
    XCTAssertEqual(
      HandoffFailureNotice.message(status: .failed(stage: .recording), hasRow: false),
      "Recording failed — the audio is saved."
    )
    // A row carries its own failure and its Retry; two surfaces for one failure
    // is the doubling this lane's notification policy already refuses.
    XCTAssertNil(HandoffFailureNotice.message(status: .failed(stage: .summarizing), hasRow: true))
    // Nothing to say about a record that landed.
    XCTAssertNil(HandoffFailureNotice.message(status: .done, hasRow: true))
    XCTAssertNil(HandoffFailureNotice.message(status: .transcribed, hasRow: false))
  }

  /// A transcription failure is not a recording failure. Saying it is sends the
  /// owner looking for audio that is exactly where it should be.
  func testTranscriptionAndRecordingFailuresAreNamedApart() {
    XCTAssertEqual(
      CompletionNotifierPolicy.failureBody(.transcribing),
      "Transcription failed. The audio is saved."
    )
    XCTAssertEqual(
      CompletionNotifierPolicy.failureBody(.recording),
      "Recording failed. The audio is saved."
    )
    let now = Date()
    XCTAssertEqual(
      ProcessingRowStatus.make(
        status: .failed(stage: .transcribing),
        interrupted: false,
        updatedAt: now,
        now: now
      )?.text,
      "Transcription failed · audio saved"
    )
  }

  // MARK: - Where a record got to when the work stopped

  func testLanding_readsTheRecordRatherThanAssuming() {
    XCTAssertEqual(
      ProcessingLanding.resolve(record: ["status": "done"]).status,
      .done
    )
    XCTAssertEqual(
      ProcessingLanding.resolve(record: ["status": "failed:summarizing", "interrupted": true])
        .interrupted,
      true
    )
    // A legacy record with no status resolves by what it HAS, never as live.
    XCTAssertEqual(ProcessingLanding.resolve(record: ["summary": "x"]).status, .done)
    // No record to consult: never `done`, and never a stage whose artifacts may
    // not exist.
    XCTAssertEqual(ProcessingLanding.resolve(record: nil).status, .failed(stage: .transcribing))
    XCTAssertFalse(ProcessingLanding.resolve(record: nil).interrupted)
  }

  func testCompletionFacts_countDistinctSpeakersOffTheSegments() {
    let record: [String: Any] = [
      "durationMinutes": 41,
      "segments": [
        ["speaker": "Kenny"],
        ["speaker": "Kenny"],
        ["speaker": "Rex"],
        ["speaker": ""],
        ["text": "no speaker at all"]
      ],
      "markers": [["at": 1], ["at": 2], ["at": 3]]
    ]
    XCTAssertEqual(CompletionFacts.line(fromRecord: record), "41:00 · 2 speakers · 3 moments")
    // A record written before `durationSeconds` existed still has a length.
    XCTAssertEqual(CompletionFacts.line(fromRecord: ["durationMinutes": 12]), "12:00")
    XCTAssertEqual(CompletionFacts.line(fromRecord: nil), "")
  }

  // MARK: - The menu bar names the stage

  /// Acceptance item 4: the menu-bar item shows the stage. The wording is a
  /// pure function so it can be asserted without a status item; the view draws
  /// exactly this string next to its glyph.
  func testMenuBarNamesTheStage_andTheEarliestOneWhenSeveralRun() {
    let ledger = ProcessingLedger()
    XCTAssertNil(ProcessingMenuBar.stageText(inFlight: ledger.inFlight))

    ledger.begin(recordID: "a", kind: .meeting, outputPath: nil, status: .transcribing)
    XCTAssertEqual(ProcessingMenuBar.stageText(inFlight: ledger.inFlight), "Transcribing…")

    ledger.advance(recordID: "a", to: .summarizing)
    XCTAssertEqual(ProcessingMenuBar.stageText(inFlight: ledger.inFlight), "Summarizing…")

    // Two at once: the earliest stage wins — it is the work with the furthest
    // still to go — and the count says how many.
    ledger.begin(recordID: "b", kind: .memo, outputPath: nil, status: .transcribing)
    XCTAssertEqual(ProcessingMenuBar.stageText(inFlight: ledger.inFlight), "Transcribing… (2)")
  }

  /// The window between the seal and the summary is the one stretch with no
  /// drawer row (there is no `.md` before the seal) and no stage name. The slot
  /// still has to be warm, which is what the count is for.
  func testMenuBar_saysNothingForAJobBetweenStages() {
    let ledger = ProcessingLedger()
    ledger.begin(recordID: "a", kind: .meeting, outputPath: nil, status: .transcribed)
    XCTAssertNil(ProcessingMenuBar.stageText(inFlight: ledger.inFlight))
    XCTAssertFalse(ledger.inFlight.isEmpty, "still work, even with no stage to name")
  }
}

// MARK: - Where Stop lands (XIA-429)

/// The routing decision lives in **one** pure helper so the owner can reverse
/// it after living with it; these are the three things it may never do,
/// asserted against that helper rather than against a rendered window.
final class StopLandingTests: XCTestCase {
  /// The ordinary case: a clean Stop lands on the document it just sealed.
  func testASealedSessionOpensItsOwnDocument() {
    XCTAssertTrue(
      StopLanding.opensSealedDocument(sealed: true, discarded: false, isLiveSessionActive: false)
    )
  }

  /// **A seal that failed falls back to home.** There is no document, so
  /// routing to one would be routing to nothing; the orphan toolbar pill is
  /// what acknowledges the record instead.
  func testAFailedSealNeverRoutesToADocument() {
    XCTAssertFalse(
      StopLanding.opensSealedDocument(sealed: false, discarded: false, isLiveSessionActive: false)
    )
  }

  /// **A discarded session must not route either.** Discard sets the same
  /// `isLiveSessionHandedOff` flag Stop does — XIA-434 already found the two
  /// sharing it — and deletes the whole record, so a decision made on that flag
  /// would open a document for a session the owner said they did not want.
  func testADiscardedSessionNeverRoutesToADocument() {
    XCTAssertFalse(
      StopLanding.opensSealedDocument(sealed: true, discarded: true, isLiveSessionActive: false)
    )
  }

  /// A Start press that beat the seal keeps the window. The seal completes
  /// asynchronously and a session that is already recording must not have the
  /// window yanked out from under it — the rule `CompletionEffect.decide` keeps.
  func testASessionThatIsRecordingAgainKeepsTheWindow() {
    XCTAssertFalse(
      StopLanding.opensSealedDocument(sealed: true, discarded: false, isLiveSessionActive: true)
    )
  }

  /// **A file transcription started in the gap owns the pane.** Stop comes home
  /// on the press and the seal lands seconds later; `ContentView.phase` tests
  /// `hasContent` before `isRunning`, so writing a document here would take the
  /// running pane away outright.
  func testAFileTranscriptionStartedInTheGapKeepsThePane() {
    XCTAssertFalse(
      StopLanding.opensSealedDocument(
        sealed: true,
        discarded: false,
        isLiveSessionActive: false,
        isTranscribingAFile: true
      )
    )
  }

  /// **Whatever the owner opened in the meantime wins.** The AssemblyAI stop
  /// waits on the final transcript up to a 5s watchdog, which is more than long
  /// enough to press ⌘L and open yesterday's meeting; the seal must not then
  /// swap the document out from under them.
  func testADocumentTheOwnerOpenedInTheMeantimeIsNotReplaced() {
    XCTAssertFalse(
      StopLanding.opensSealedDocument(
        sealed: true,
        discarded: false,
        isLiveSessionActive: false,
        openDocumentChanged: true
      )
    )
  }

  /// The switch is one flag, and **flipping it turns the whole feature off** —
  /// asserted by driving the off state, not by asserting the constant is true.
  /// The latter proves nothing about the switch and makes using the escape
  /// hatch a red suite, which is the opposite of an escape hatch.
  func testTheOwnerCanTurnTheWholeThingOffInOnePlace() {
    for active in [false, true] {
      for running in [false, true] {
        for changed in [false, true] {
          XCTAssertFalse(
            StopLanding.opensSealedDocument(
              routes: false,
              sealed: true,
              discarded: false,
              isLiveSessionActive: active,
              isTranscribingAFile: running,
              openDocumentChanged: changed
            ),
            "one flag has to be enough to restore \"Stop goes home\""
          )
        }
      }
    }
    XCTAssertTrue(StopLanding.routesToDocument, "shipped on; flip this to go back")
  }
}
