import AVFoundation
import AppKit
import SwiftUI
import XCTest

@testable import Nota

/// XIA-447 — pause and resume a live session, without ending it.
///
/// The decisions are pure types (`SessionClock`, `SessionDurationChoice`,
/// `SessionClusterAction`, `MiniIslandVisibility`, `LiveMeetingControls`), so
/// almost all of this runs with no microphone, no socket and no window server.
/// The two cases that cannot are here for the reason `testTheIdlePaneDrawsNoEmber`
/// is: "the ember goes out" is a claim about pixels, and "the word is on the
/// cluster" is a claim about a laid-out row.
@MainActor
final class SessionPauseTests: XCTestCase {
  // MARK: - The clock is audio time, not wall clock

  private func at(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSinceReferenceDate: seconds)
  }

  /// **The requirement in one assertion.** Pause two minutes inside a
  /// twenty-minute meeting and the recording is eighteen minutes.
  ///
  /// It matters because `recording.caf` is a concatenation of the audio that
  /// was kept, with the paused span simply absent — so a wall-clock elapsed
  /// would put every marker's `atSeconds`, every segment's `endTime` and the
  /// record's own `durationMinutes` two minutes past the audio they name.
  func testElapsedIsAudioTimeAndNotWallClock() {
    var clock = SessionClock(startedAt: at(0))
    clock.pause(now: at(300))
    clock.resume(now: at(420))  // two minutes away from the desk
    XCTAssertEqual(clock.elapsed(now: at(1_200)), 1_080, accuracy: 0.001)
    XCTAssertEqual(
      at(1_200).timeIntervalSince(at(0)),
      1_200,
      "the wall clock did not move, so this proves nothing"
    )
  }

  /// The clock **stops** while paused rather than being frozen by a ticker that
  /// happens not to run: a surface reading it once, late, during a pause gets
  /// the same answer as one that read it at the press.
  func testTheClockStopsWhilePaused() {
    var clock = SessionClock(startedAt: at(0))
    clock.pause(now: at(100))
    XCTAssertEqual(clock.elapsed(now: at(100)), 100, accuracy: 0.001)
    XCTAssertEqual(clock.elapsed(now: at(600)), 100, accuracy: 0.001)
    XCTAssertTrue(clock.isPaused)

    clock.resume(now: at(600))
    XCTAssertFalse(clock.isPaused)
    XCTAssertEqual(clock.elapsed(now: at(610)), 110, accuracy: 0.001)
  }

  /// Pauses **accumulate**. One long pause and three short ones are the same
  /// arithmetic, and a session with several is where a naive `startedAt = now`
  /// at resume quietly loses the earlier ones.
  func testEveryPauseIsSubtracted() {
    var clock = SessionClock(startedAt: at(0))
    for (start, end) in [(10.0, 20.0), (30.0, 45.0), (60.0, 61.0)] {
      clock.pause(now: at(start))
      clock.resume(now: at(end))
    }
    XCTAssertEqual(clock.elapsed(now: at(100)), 100 - 26, accuracy: 0.001)
    XCTAssertTrue(clock.everPaused)
  }

  /// A second Pause press while paused must not re-stamp the start and lose the
  /// seconds already accrued; a Resume with nothing to resume must bank nothing.
  func testPauseAndResumeAreIdempotent() {
    var clock = SessionClock(startedAt: at(0))
    clock.pause(now: at(10))
    clock.pause(now: at(50))
    clock.resume(now: at(60))
    XCTAssertEqual(clock.elapsed(now: at(100)), 50, accuracy: 0.001)

    clock.resume(now: at(200))
    XCTAssertEqual(clock.elapsed(now: at(100)), 50, accuracy: 0.001)
  }

  /// A clock that went backwards banks zero rather than *rewinding* the
  /// recording past audio that exists on disk.
  func testTheClockNeverRunsBackwards() {
    var clock = SessionClock(startedAt: at(0))
    clock.pause(now: at(100))
    clock.resume(now: at(40))
    XCTAssertEqual(clock.elapsed(now: at(120)), 120, accuracy: 0.001)
    XCTAssertGreaterThanOrEqual(clock.elapsed(now: at(-500)), 0)
  }

  /// **A moment flagged after a resume names the right second of the
  /// recording** — the case the ticket asks for by name.
  ///
  /// The mark is stamped with `elapsed`, `LiveTranscriptMarking` matches it
  /// against segment end times stamped the same way, and both come from this
  /// one clock. So the assertion is that a mark two minutes after a two-minute
  /// pause lands on the words that were being said, not two minutes past them.
  func testAMomentFlaggedAfterAResumeNamesTheAudioItBelongsTo() {
    var clock = SessionClock(startedAt: at(0))
    clock.pause(now: at(300))
    clock.resume(now: at(420))

    // A turn that finalized 30s of audio after the resume…
    let turn = LiveTranscriptLine(
      id: UUID(),
      text: "…and that is the rollback plan.",
      endTime: clock.elapsed(now: at(450))
    )
    let earlier = LiveTranscriptLine(id: UUID(), text: "before the break", endTime: 290)
    // …and a ⌘K pressed while it was in flight.
    let log = SessionMarkerLog()
    let marker = log.mark(at: clock.elapsed(now: at(445)))

    XCTAssertEqual(marker.at, 325, accuracy: 0.001, "the mark is at wall-clock time")
    XCTAssertEqual(turn.endTime, 330, accuracy: 0.001)
    XCTAssertEqual(
      LiveTranscriptMarking.markedLineIDs(markers: [marker], lines: [earlier, turn]),
      [turn.id],
      "the mark landed on the wrong line — the clock and the segments disagree"
    )
  }

  // MARK: - Which duration a record is sealed with

  /// A session that never paused is unaffected: the server's
  /// `audio_duration_seconds` still wins, because it still counts exactly the
  /// frames the server received.
  func testAnUnpausedSessionStillSealsWithTheServersDuration() {
    XCTAssertEqual(
      SessionDurationChoice.duration(serverReported: 1_197, elapsed: 1_200, everPaused: false),
      1_197
    )
    XCTAssertEqual(
      SessionDurationChoice.duration(serverReported: nil, elapsed: 1_200, everPaused: false),
      1_200,
      "with no server figure there is only the clock"
    )
  }

  /// A **paused** session is sealed with the clock instead, and the reason is
  /// the socket decision: the stream is kept alive with silent frames, so the
  /// server's figure includes every paused second — it is wall clock, which is
  /// the one thing `elapsed` deliberately is not. Sealing with it would undo
  /// the whole of the audio-time correction from the far side.
  func testAPausedSessionSealsWithTheAudioClockAndNotTheServer() {
    XCTAssertEqual(
      SessionDurationChoice.duration(serverReported: 1_200, elapsed: 1_080, everPaused: true),
      1_080
    )
  }

  // MARK: - The seam: what the socket is sent, and what the file gets

  /// **The socket decision, written down as a test.** One socket for the whole
  /// session, kept alive with zeroed frames — chosen over close-and-reopen
  /// (there is no reopen path, and `start()` begins by wiping the session) and
  /// over sending nothing (an idle realtime stream is disconnected, which lands
  /// in `failSession`, and capping the pause is forbidden — a pause lasts
  /// forever).
  ///
  /// The frame is the shape `handlePCMBuffer` sends: 16 kHz mono Int16, all
  /// zero.
  func testThePauseKeepAliveFrameIsRealSilenceInTheStreamsOwnFormat() {
    let frame = LiveMeetingSession.silentFrame(seconds: 1)
    XCTAssertEqual(frame.count, 16_000 * MemoryLayout<Int16>.stride)
    XCTAssertTrue(frame.allSatisfy { $0 == 0 }, "the keep-alive is not silent")
    XCTAssertEqual(LiveMeetingSession.silentFrame(seconds: 0).count, 0)
    XCTAssertEqual(LiveMeetingSession.pauseKeepAliveInterval, 1, accuracy: 0.001)
  }

  /// **Audio continuity.** One predicate decides whether a delivered buffer
  /// reaches the socket *and* whether it reaches `recording.caf`, so the file
  /// is exactly the buffers that got past it: the paused span is absent from
  /// it, not a gap of silence and not a second file.
  ///
  /// It is asserted separately from `meterFollowsMicrophone` because the two
  /// answer different questions — bytes versus what may be claimed on screen —
  /// and only happen to agree today.
  func testNoAudioIsKeptWhilePausedAndTheFileStaysOneRecording() {
    XCTAssertTrue(LiveMeetingSession.capturesAudio(.recording))
    XCTAssertFalse(LiveMeetingSession.capturesAudio(.paused))
    XCTAssertFalse(LiveMeetingSession.capturesAudio(.stopping))
    XCTAssertFalse(LiveMeetingSession.capturesAudio(.idle))
    XCTAssertFalse(LiveMeetingSession.capturesAudio(.failed("x")))
  }

  /// **The pre-press tail is not dropped, and the paused span does not leak.**
  ///
  /// Driven across a real `pause()` / `resume()` on a real `MicCapture`,
  /// because the rule is entirely about *ordering* and nothing about ordering
  /// is visible from a queue asserted on its own. The predecessor of this test
  /// built its own `PendingPCMBuffers`, checked that `take()` returns what was
  /// put in, and then flushed an **empty** queue — an assertion one step to the
  /// side of the thing that matters. It stayed green when
  /// `capture.flushPending()` was moved to *after* the state flip, and green
  /// again while the session's buffer callback opened a `Task { @MainActor }`
  /// that deferred every drained buffer past that flip and dropped the whole
  /// tail on every pause.
  ///
  /// Two directions, and the second is the worse one: audio captured *during* a
  /// pause must not be written when the drain happens to land after Resume — a
  /// pause is often taken for privacy, and the promise is that the span is
  /// absent from `recording.caf`.
  func testAPauseKeepsThePrePressTailAndAResumeDropsThePausedSpan() {
    let session = LiveMeetingSession()
    session.beginForTesting(startedAt: at(0))
    let capture = session.captureForTesting

    // The last word before the press, still in flight across the queue hop.
    for _ in 0..<3 { capture.enqueueForTesting(Self.silentBuffer()) }
    XCTAssertEqual(session.keptBufferCountForTesting, 0, "nothing has been drained yet")

    session.pause(now: at(10))
    XCTAssertEqual(
      session.keptBufferCountForTesting, 3,
      "the tail queued at the press was judged against .paused and thrown away"
    )

    // …and audio captured while paused, drained after the state flips back.
    for _ in 0..<2 { capture.enqueueForTesting(Self.silentBuffer()) }
    session.resume(now: at(70))
    XCTAssertEqual(
      session.keptBufferCountForTesting, 3,
      "audio from the paused span reached the file the owner was told does not hold it"
    )

    // A buffer captured after the resume is kept again, so this is not just a
    // session that stopped delivering.
    capture.enqueueForTesting(Self.silentBuffer())
    capture.flushPending()
    XCTAssertEqual(session.keptBufferCountForTesting, 4)
    XCTAssertNotNil(capture.onPCMBuffer, "a flush must not detach the tap")
  }

  private static func silentBuffer() -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
    buffer.frameLength = 160
    return buffer
  }

  /// **A finalized hypothesis that lands during a pause is kept.** The Apple
  /// analyzer finalizes asynchronously — audio fed at t−0.5s resolves at
  /// t+0.3s — so the sentence spoken just before the press arrives after it.
  /// Gated on `.recording` alone it was dropped and never re-emitted, because
  /// Apple's finalized results are deltas: a mid-meeting pause silently lost
  /// the last turn before it from the sealed transcript and the summary.
  ///
  /// The WS path is asserted alongside it because the two engines used to
  /// disagree about this one boundary, and a rule that holds on one of them is
  /// a rule that will drift.
  func testAFinalizedTurnThatLandsDuringAPauseIsStillKept() {
    let session = LiveMeetingSession()
    session.beginForTesting(startedAt: at(0))
    session.pause(now: at(30))

    session.handleMessageJSON(
      #"{"type":"Turn","transcript":"and that is the rollback plan","end_of_turn":true}"#
    )
    XCTAssertEqual(session.segments.count, 1, "the WS path dropped a late turn")
    XCTAssertEqual(
      session.segments.first?.endTime ?? -1, 30, accuracy: 0.001,
      "the late turn was stamped past the audio it names"
    )

    session.handleAppleHypothesisForTesting(
      Hypothesis(text: "before the break", isFinal: true)
    )
    XCTAssertEqual(
      session.segments.count, 2,
      "the Apple path dropped a hypothesis finalized just after the press"
    )
    XCTAssertEqual(session.segments.last?.text, "before the break")
  }

  /// **A blank end-of-turn is not a turn.** A pause streams zeroed frames for
  /// as long as it lasts, and silence is exactly the input that closes a turn —
  /// so without this a five-minute break adds an empty segment to the live
  /// transcript and a blank line to the sealed `.md`, at every pause.
  func testKeepAliveSilenceDoesNotAppendAnEmptySegment() {
    let session = LiveMeetingSession()
    session.beginForTesting(startedAt: at(0))
    session.pause(now: at(30))
    session.handleMessageJSON(#"{"type":"Turn","transcript":"","end_of_turn":true}"#)
    session.handleMessageJSON(#"{"type":"Turn","transcript":"   ","end_of_turn":true}"#)
    XCTAssertTrue(session.segments.isEmpty, "the server's silence became a transcript line")
  }

  /// **Every way out of a pause stops the keep-alive.** It is the one part of
  /// pause that spends the owner's money — 32 KB of silence a second into a
  /// live AssemblyAI stream — and `URLSessionWebSocketTask.send` is not
  /// observable, so before the sink existed the loop's guard and all five
  /// `stopPauseKeepAlive()` calls were unasserted by construction.
  func testThePauseKeepAliveSendsAndEveryExitCancelsIt() async {
    func paused() -> LiveMeetingSession {
      let session = LiveMeetingSession()
      session.pauseKeepAliveSink = { _ in }
      session.pauseKeepAliveIntervalOverride = 0.01
      session.beginForTesting(startedAt: at(0))
      session.pause(now: at(10))
      return session
    }

    // It really sends, in the stream's own format.
    let sending = paused()
    var frames: [Data] = []
    sending.pauseKeepAliveSink = { frames.append($0) }
    XCTAssertTrue(sending.isPauseKeepAliveRunning)
    try? await Task.sleep(nanoseconds: 60_000_000)
    XCTAssertGreaterThan(frames.count, 0, "a paused session sent the server nothing")
    XCTAssertEqual(frames.first?.count, 16_000 * MemoryLayout<Int16>.stride)

    // Resume.
    let resumed = paused()
    resumed.resume(now: at(20))
    XCTAssertFalse(resumed.isPauseKeepAliveRunning, "resume left the keep-alive running")

    // Stop, from the pause.
    let stopped = paused()
    stopped.finishWatchdogNanoseconds = 10_000_000
    _ = try? await stopped.stop()
    XCTAssertFalse(stopped.isPauseKeepAliveRunning, "stop left the keep-alive running")

    // A server-initiated end while paused.
    let terminated = paused()
    terminated.handleMessageJSON(#"{"type":"Termination","audio_duration_seconds":10}"#)
    XCTAssertFalse(terminated.isPauseKeepAliveRunning, "a Termination left the keep-alive running")

    // Teardown.
    let cancelled = paused()
    cancelled.cancel()
    XCTAssertFalse(cancelled.isPauseKeepAliveRunning, "cancel left the keep-alive running")
  }

  // MARK: - The session's own transitions

  /// Pause stops the clock and keeps the session; resume continues into the
  /// same one. Driven on the real session through its test seams, because the
  /// guards (`state == .recording`, `state == .paused`) are what a surface
  /// pressing twice runs into.
  func testTheSessionPausesAndResumesWithoutEnding() {
    let session = LiveMeetingSession()
    session.beginForTesting(startedAt: at(0))
    XCTAssertEqual(session.state, .recording)

    session.pause(now: at(100))
    XCTAssertEqual(session.state, .paused)
    XCTAssertEqual(session.elapsed, 100, accuracy: 0.001)
    XCTAssertEqual(session.level.level, 0, "the meter did not fall to silence")

    // A second press changes nothing.
    session.pause(now: at(200))
    XCTAssertEqual(session.clockForTesting?.elapsed(now: at(400)), 100)

    session.resume(now: at(400))
    XCTAssertEqual(session.state, .recording)
    XCTAssertEqual(session.elapsed, 100, accuracy: 0.001)
    XCTAssertEqual(session.clockForTesting?.elapsed(now: at(430)), 130)
    XCTAssertEqual(session.clockForTesting?.everPaused, true)
  }

  /// A session that is not recording cannot be paused, and one that is not
  /// paused cannot be resumed — so a stale press from a surface that has not
  /// caught up cannot put a stopping or failed session into `.paused`.
  func testOnlyALiveSessionPausesAndOnlyAPausedOneResumes() {
    for state in [
      LiveMeetingSession.SessionState.idle, .stopping, .failed("dropped"),
    ] {
      let session = LiveMeetingSession()
      session.setStateForTesting(state)
      session.pause()
      XCTAssertEqual(session.state, state, "\(state) was pausable")
      session.resume()
      XCTAssertEqual(session.state, state, "\(state) was resumable")
    }
  }

  /// **Stop is terminal, from a pause too.** A paused session is stoppable
  /// precisely so the owner never has to resume in order to end — and nothing
  /// resumes afterwards, because `stop()` settles the session to `.idle` and
  /// `resume()` refuses everything that is not `.paused`.
  func testStopIsTerminalFromAPauseAndNothingResumesAfterIt() async throws {
    let session = LiveMeetingSession()
    session.beginForTesting(startedAt: at(0))
    session.pause(now: at(30))
    session.finishWatchdogNanoseconds = 10_000_000

    let result = try await session.stop()
    XCTAssertEqual(session.state, .idle)
    XCTAssertEqual(result.duration, 30, accuracy: 0.5, "a paused session sealed wall-clock time")

    session.resume()
    XCTAssertEqual(session.state, .idle, "a session resumed after Stop")
  }

  // MARK: - A paused session never looks stopped

  /// The one decision every surface reads. A paused session **keeps the
  /// cluster** — taking it away is exactly the "looks stopped" failure — while
  /// the ember rules in the transcript margin go, because the microphone is
  /// closed and the ember means it is open. Those two used to be the same
  /// property and are now deliberately not.
  func testAPausedSessionKeepsItsSurfaceAndLosesItsEmber() {
    let controls = LiveMeetingControls.make(state: .paused, isStarting: false, hasTranscript: true)
    XCTAssertEqual(controls, .paused)
    XCTAssertTrue(controls.showsRecordingPane, "the pane vanished, so a pause looks like a stop")
    XCTAssertFalse(controls.drawsMarkerRules, "ember over a closed microphone")
    XCTAssertTrue(LiveMeetingControls.stop.drawsMarkerRules, "the split proves nothing")
    XCTAssertFalse(LiveMeetingSession.meterFollowsMicrophone(.paused))
  }

  /// **The word, on every surface that can say it.** A colour change alone is
  /// not enough: the ember going out and the clock stopping are both absences,
  /// and an absence is what a stopped session looks like.
  func testEverySurfaceSaysTheWordPaused() {
    XCTAssertEqual(LiveMeetingFormat.stateLabel(.paused), RecordingPaneCopy.pausedTitle)
    XCTAssertEqual(RecordingPaneCopy.pausedTitle, "Paused")
    XCTAssertEqual(RecordingPaneCopy.activity(.paused), "paused")

    // The island.
    XCTAssertEqual(MiniIslandPhase.paused.message, RecordingPaneCopy.pausedTitle)
    XCTAssertTrue(MiniIslandCopy.all(.paused).contains(RecordingPaneCopy.pausedTitle))

    // The menu bar: the item itself, and the status row inside the popover.
    let presence = MenuBarSessionPresence.make(state: .paused, elapsed: 754)
    XCTAssertEqual(presence?.isPaused, true)
    XCTAssertEqual(presence?.isEmber, false)
    XCTAssertEqual(presence?.accessibilityLabel, "Nota: paused, 12:34")
    XCTAssertTrue(
      MenuBarSessionCopy.status(state: .paused, elapsed: 754)
        .contains(RecordingPaneCopy.pausedTitle)
    )

    // And it is a string the copy promise covers, so it cannot drift out of
    // `all(kind:controls:)` unnoticed.
    XCTAssertTrue(
      RecordingPaneCopy.all(kind: .meeting, controls: .paused)
        .contains(RecordingPaneCopy.pausedTitle)
    )
  }

  /// **The ember goes out.** Rendered and scanned rather than asserted about a
  /// constant, the way `testTheIdlePaneDrawsNoEmber` is: "there is no ember on
  /// screen" is a claim about pixels, and the meter, the clock and the capsules
  /// are all still drawn — so a constant somewhere saying `false` proves
  /// nothing about what the cluster put on the screen.
  func testTheClusterDrawsNoEmberWhilePaused() {
    func emberPixels(_ controls: LiveMeetingControls) -> Int? {
      guard
        let bitmap = RenderProbe.bitmap(
          ZStack {
            Color.white
            SessionCapsuleCluster(
              elapsed: 754,
              // A LOUD level, so a meter that kept answering would be found.
              level: MicLevelFeed(level: 0.95),
              controls: controls,
              markers: [SessionMarker(at: 12)],
              onMark: {},
              onPause: {},
              onStop: {}
            )
          }
          .environment(\.colorScheme, .light),
          size: CGSize(width: 700, height: 200)
        )
      else { return nil }
      return RenderProbe.emberPixels(bitmap, scheme: .light)
    }

    guard let live = emberPixels(.stop), let paused = emberPixels(.paused) else {
      return XCTFail("the hosting view produced no bitmap")
    }
    XCTAssertGreaterThan(live, 0, "the probe cannot see the ember it is looking for")
    // The meter's FLOOR is what this catches. The level falls to zero at the
    // press, but a meter is never blank — a blank meter and an absent meter look
    // the same — so the bars are still drawn, and drawn in ember they were the
    // one reserved signal sitting over a closed microphone for the whole of a
    // pause. `SessionMeter.isLive` moves the colour and nothing else; it was 110
    // ember pixels before it existed.
    XCTAssertEqual(paused, 0, "the cluster draws the recording accent over a closed microphone")
  }

  /// …and the meter itself is at its **floor** while paused, which is the other
  /// half: a meter that kept moving would say a voice was being recorded.
  /// `publishLevel` silences it at the press, ungated.
  func testTheMeterFallsToItsFloorAtThePress() {
    let session = LiveMeetingSession()
    session.beginForTesting(startedAt: at(0))
    session.level.publish(0.9, now: 100)
    XCTAssertEqual(session.level.level, 0.9, accuracy: 0.001)

    session.pause(now: at(10))
    XCTAssertEqual(session.level.level, 0, "the meter kept the last thing it heard")
    XCTAssertEqual(
      SessionMeterMetrics.barHeights(level: 0, variant: .compact),
      Array(repeating: SessionMeterMetrics.Variant.compact.minBarHeight, count: 5),
      "a silent meter is not the floor — a blank meter and an absent one look the same"
    )
  }

  /// **The word costs the row nothing.** It is an overlay, like the moment
  /// tally, and for the identical rule: no state of the session may move Stop
  /// under the pointer, and a centred cluster splits any widening across both
  /// sides. Drawn *inside* the timer capsule it would have widened it.
  func testTheWordPausedNeverMovesTheCluster() {
    func size(_ controls: LiveMeetingControls) -> CGSize {
      let host = NSHostingView(
        rootView: SessionCapsuleCluster(
          elapsed: 754,
          level: MicLevelFeed(level: 0.4),
          controls: controls,
          markers: [SessionMarker(at: 12)],
          onMark: {},
          onPause: {},
          onStop: {}
        )
      )
      host.layoutSubtreeIfNeeded()
      return host.fittingSize
    }
    let live = size(.stop)
    let paused = size(.paused)
    XCTAssertGreaterThan(live.width, 0, "the hosting view produced no layout")
    XCTAssertEqual(paused.width, live.width, accuracy: 0.5, "the badge widened the row")
    XCTAssertEqual(paused.height, live.height, accuracy: 0.5, "the badge grew the row")
    XCTAssertEqual(
      live.height,
      RecordingPaneMetrics.capsuleHeight,
      accuracy: 0.5,
      "the row is not one capsule tall, so this comparison is not about the badge"
    )
  }

  /// **The word is actually on the cluster**, not merely in a copy table.
  ///
  /// `testEverySurfaceSaysTheWordPaused` asserts constants and
  /// `testTheWordPausedNeverMovesTheCluster` compares `fittingSize`, which an
  /// `.overlay` cannot change *by definition* — so both stayed green with the
  /// badge deleted outright (verified by mutation). For the ticket whose thesis
  /// is "a paused session must never look stopped", the badge is the
  /// load-bearing pixel and it was the one thing unpinned.
  ///
  /// Asserted as **blue ink outside the row's own band**: the badge is
  /// `primaryBlue` and sits clear of the capsules, so the live render fixes
  /// where the row's blue lives (Mark's capsule) and the paused render has to
  /// put blue somewhere else. That is independent of which way the bitmap's y
  /// axis runs, and it fails the moment the overlay stops being drawn.
  func testTheClusterActuallyDrawsTheWordPaused() {
    // The word moved *into* the Pause capsule (owner, 2026-08-12), so the
    // signal moved with it. It used to be blue pixels in rows the running
    // cluster left empty — a badge floating above the row.
    //
    // The capsule is probed **alone**, not inside the cluster. Measuring the
    // whole row was tried and is worthless here: the blue is identical in both
    // states by construction (`pauseCapsuleWidth` reserves the wide form so the
    // press cannot move Stop), so the only honest difference is the ink inside
    // that one capsule — and a full-row probe reads the white page between the
    // capsules and the timer's own glyphs, which swamp six letters by an order
    // of magnitude. Measured: 8320 running against 4967 paused, i.e. the noise
    // moved further than the signal and in the wrong direction.
    func ink(_ controls: LiveMeetingControls) -> Int? {
      let cluster = SessionCapsuleCluster(
        elapsed: 754,
        level: MicLevelFeed(level: 0.4),
        controls: controls,
        markers: [],
        onMark: {},
        onPause: {},
        onStop: {}
      )
      guard
        let bitmap = RenderProbe.bitmap(
          cluster.capsule(.pause).environment(\.colorScheme, .light),
          size: CGSize(width: 240, height: 80)
        )
      else { return nil }
      var white = 0
      for x in 0..<bitmap.pixelsWide {
        for y in 0..<bitmap.pixelsHigh {
          guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
          // The glyph and the letters are white on the blue plate. Requiring
          // alpha keeps the transparent surround out of the count.
          if pixel.alphaComponent > 0.5, pixel.brightnessComponent > 0.8,
            pixel.saturationComponent < 0.12
          {
            white += 1
          }
        }
      }
      return white
    }

    guard let live = ink(.stop), let paused = ink(.paused) else {
      return XCTFail("the hosting view produced no bitmap")
    }
    XCTAssertGreaterThan(live, 0, "the probe cannot see the glyph it is looking for")
    XCTAssertGreaterThan(
      paused, live + 60,
      "the Pause capsule carries \(paused) white pixels paused against \(live) running — the "
        + "word 'Paused' is not being drawn on it"
    )
  }

  // MARK: - The island and the menu bar

  /// **A paused session keeps the island up.** The phase is resolved above the
  /// microphone gate deliberately: everything below it asks
  /// `meterFollowsMicrophone`, which a paused session fails, so the island
  /// would go off screen at the press — in the one situation where the owner is
  /// looking at another app and the window can tell them nothing.
  func testTheIslandStaysUpAndSaysPaused() {
    let inputs = MiniIslandInputs(
      sessionState: .paused, appIsFrontmost: false, now: 10
    )
    XCTAssertEqual(MiniIslandVisibility.phase(inputs), .paused)

    // Nota in front still takes it down — that rule has no exceptions.
    var frontmost = inputs
    frontmost.appIsFrontmost = true
    XCTAssertNil(MiniIslandVisibility.phase(frontmost))
  }

  /// What the paused card offers, and what it does not draw. No ember; the
  /// clock stays, because the length of the recording so far is still true and
  /// still the owner's — it has simply stopped moving.
  func testThePausedIslandOffersResumeAndStopAndDrawsNoEmber() {
    XCTAssertEqual(MiniIslandPhase.paused.actions, [.resume, .stop])
    XCTAssertFalse(MiniIslandPhase.paused.showsEmber)
    XCTAssertTrue(MiniIslandPhase.paused.showsClock)
    XCTAssertEqual(MiniIslandPhase.recording.actions, [.mark, .pause, .stop])
  }

  /// The verbs, driven through the one switch every surface routes through, so
  /// a swapped body is a failure rather than a card that happens to still work.
  func testEachIslandActionRunsItsOwnPauseVerb() {
    var paused = 0
    var resumed = 0
    var stopped = 0
    let controller = MiniRecorderIslandController(
      presenter: StubIslandPresenter(),
      frontmost: { true },
      clock: { 0 },
      settings: { DictationSettings() },
      source: { IslandSource(sessionState: .paused, isHandoffProcessing: false, elapsed: 0, level: nil) },
      verbs: IslandVerbs(
        mark: { nil },
        pause: { paused += 1 },
        resume: { resumed += 1 },
        stop: { stopped += 1 },
        show: {},
        retry: {},
        reportUnavailable: {}
      )
    )

    controller.perform(.pause)
    XCTAssertEqual([paused, resumed, stopped], [1, 0, 0])
    controller.perform(.resume)
    XCTAssertEqual([paused, resumed, stopped], [1, 1, 0])
    controller.perform(.stop)
    XCTAssertEqual([paused, resumed, stopped], [1, 1, 1])
  }

  /// **The menu bar offers a way back.** It is the surface an owner who walked
  /// away is most likely to reach, and it is the one place that had to stop
  /// asking `meterFollowsMicrophone`: unchanged, a paused session showed a
  /// status row reading "Paused" and no row that could resume it anywhere.
  func testTheMenuBarCanResumeAPausedSessionAndCannotMarkOne() {
    XCTAssertEqual(SessionMenuRows.rows(state: .paused), [.resume, .stop])
    XCTAssertEqual(SessionMenuRows.rows(state: .recording), [.mark, .pause, .stop])
    XCTAssertEqual(SessionMenuRows.rows(state: .stopping), [])
    XCTAssertTrue(SessionMenuRows.showsStatus(state: .paused))
    XCTAssertEqual(SessionMenuRow.resume.action, .resume)
    XCTAssertEqual(SessionMenuRow.pause.action, .pause)
  }

  /// The status item's **own** string, which is what an owner reads from
  /// another app. Built inline in the view body it could be deleted with
  /// nothing failing — `MenuBarSessionCopy.status` is the popover row, a
  /// different string.
  func testTheMenuBarItemItselfSaysPaused() {
    guard let paused = MenuBarSessionPresence.make(state: .paused, elapsed: 754) else {
      return XCTFail("a paused session showed nothing in the menu bar")
    }
    XCTAssertEqual(MenuBarSessionCopy.itemText(paused), "12:34 · Paused")
    guard let live = MenuBarSessionPresence.make(state: .recording, elapsed: 754) else {
      return XCTFail("no presence for a live session")
    }
    XCTAssertEqual(MenuBarSessionCopy.itemText(live), "12:34", "a live session read as paused")
  }

  // MARK: - The status contract

  /// **Paused is a flag, and both sides agree about it.** The status stays
  /// `recording`, so nothing in the machine moved: `isInFlight` still true,
  /// `interruptedResolution` still `failed(recording)`, `canAdvance` untouched.
  ///
  /// A `"paused"` status would have been unsafe rather than merely expensive —
  /// `normalized` resolves an unrecognized value by what the record HAS, so an
  /// older build would have read it as `transcribed`, a rest state the launch
  /// sweep never revisits.
  func testPausedIsAFlagOnRecordingAndNotAStatusOfItsOwn() {
    XCTAssertNil(HistoryStatus(rawValue: "paused"), "paused became a status")
    XCTAssertFalse(HistoryStatus.allCases.map(\.rawValue).contains("paused"))
    XCTAssertEqual(
      HistoryStatus.normalized("paused", hasSummary: false),
      .transcribed,
      "an unknown status resolves to a REST state — which is exactly why paused may not be one"
    )

    XCTAssertEqual(HistoryStatus.recording.presentation(paused: true), "Paused")
    XCTAssertEqual(HistoryStatus.recording.presentation(), "Recording")
    XCTAssertTrue(HistoryStatus.recording.isInFlight)
    XCTAssertEqual(HistoryStatus.recording.interruptedResolution, .failed(stage: .recording))
    XCTAssertTrue(HistoryStatus.recording.canAdvance(to: .transcribing))
  }

  /// **A paused session that was interrupted is Interrupted, not Paused.** The
  /// launch sweep is untouched by the flag — the record still says `recording`,
  /// so it still resolves — and the words follow what happened: nobody is
  /// coming back to that one.
  func testAnInterruptedPausedRecordStillReadsAsInterrupted() {
    let resolved = HistoryStatus.recording.interruptedResolution
    XCTAssertEqual(
      resolved?.presentation(interrupted: true, paused: true),
      "Interrupted"
    )
    // And the flag alone never rescues a failure into a live-sounding word.
    XCTAssertEqual(
      HistoryStatus.failed(stage: .recording).presentation(paused: true),
      "Failed (recording)"
    )
    // A flag on a status that is not `recording` is stale, not a new state.
    XCTAssertEqual(HistoryStatus.done.presentation(paused: true), "Done")
  }
}

// MARK: - Stub presenter

/// The island presenter with no window server in it — the seam
/// `MiniRecorderPresenting` exists for.
@MainActor
private final class StubIslandPresenter: MiniRecorderPresenting {
  var isPresenting = false
  var glassTintAlpha: Double = 0.55
  var glassMaterial: GlassMaterial = .frosted

  func show(_ render: MiniIslandRender, perform: @escaping (MiniIslandAction) -> Void) -> Bool {
    isPresenting = true
    return true
  }

  func update(_ render: MiniIslandRender) {}

  func dismiss() {
    isPresenting = false
  }
}
