import AVFoundation
import XCTest

@testable import Nota

/// Regression tests for "dictation ate the last couple of words".
///
/// The batch analyzer path used to seal a session on the first result that
/// arrived after the trigger was released. That result is a preview of audio
/// the analyzer has not finished resolving, so the words spoken just before
/// the release were dropped — intermittently, depending on whether the release
/// landed close behind the last word.
final class BatchTranscriptTests: XCTestCase {
  // MARK: - When a session may be sealed

  /// The bug, stated as a test: a result never resolves `finish()`, however
  /// final the teardown flag says it is.
  func testAResultNeverResolvesTheSession() {
    var transcript = BatchTranscript()
    transcript.record("the quick brown")
    XCTAssertNil(transcript.resolution(after: .result))
  }

  /// Sealing happens when the analyzer has flushed everything, and by then the
  /// tail has arrived.
  func testEndOfResultsResolvesWithTheCompleteText() {
    var transcript = BatchTranscript()
    transcript.record("the quick brown")
    XCTAssertNil(transcript.resolution(after: .result))
    // The finalization pass resolves the trailing audio.
    transcript.record("the quick brown fox jumps")
    XCTAssertEqual(transcript.resolution(after: .resultsEnded), "the quick brown fox jumps")
  }

  /// The latest result is the session, not the first one after the release —
  /// the interpretation of a result is unchanged; only the moment of
  /// resolution moved.
  func testTheLatestResultWinsNotTheFirst() {
    var transcript = BatchTranscript()
    for text in ["one", "one two", "one two three"] {
      transcript.record(text)
    }
    XCTAssertEqual(transcript.resolution(after: .resultsEnded), "one two three")
  }

  // MARK: - Bounded wait

  /// A stuck recognizer may delay a session's text, never swallow it: the
  /// watchdog resolves with the best text so far rather than with nothing.
  func testTheWatchdogResolvesWithTheBestTextSoFar() {
    var transcript = BatchTranscript()
    transcript.record("half a sentence")
    XCTAssertEqual(transcript.resolution(after: .watchdog), "half a sentence")
  }

  func testAWatchdogOnASilentSessionResolvesEmpty() {
    let transcript = BatchTranscript()
    XCTAssertEqual(transcript.resolution(after: .watchdog), "")
  }

  // MARK: - Folding results

  /// A short or silent hold yields no results at all; the session is empty
  /// rather than never-ending.
  func testNoResultsResolvesEmpty() {
    let transcript = BatchTranscript()
    XCTAssertEqual(transcript.resolution(after: .resultsEnded), "")
  }

  /// A trailing blank is the analyzer saying nothing new, not a retraction of
  /// the session.
  func testAnEmptyResultDoesNotEraseWhatWasHeard() {
    var transcript = BatchTranscript()
    transcript.record("do not lose me")
    transcript.record("")
    XCTAssertEqual(transcript.resolution(after: .resultsEnded), "do not lose me")
  }
}

/// The other half of the same symptom: audio captured before the release but
/// still crossing the audio-thread → main-thread hop when `stop()` ran was
/// dropped by an `isCapturing` check that had already flipped.
final class PendingPCMBuffersTests: XCTestCase {
  private func buffer(frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16_000,
      channels: 1,
      interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    return buffer
  }

  func testTakeReturnsEveryBufferInCaptureOrder() {
    let pending = PendingPCMBuffers()
    pending.append(buffer(frames: 10))
    pending.append(buffer(frames: 20))
    pending.append(buffer(frames: 30))

    let taken = pending.take()
    XCTAssertEqual(taken.map(\.frameLength), [10, 20, 30])
  }

  /// One consumer, one delivery: a drained buffer is never handed out twice
  /// (which would duplicate audio into the recognizer).
  func testTakeEmptiesTheQueue() {
    let pending = PendingPCMBuffers()
    pending.append(buffer(frames: 10))
    XCTAssertEqual(pending.take().count, 1)
    XCTAssertTrue(pending.take().isEmpty)
    XCTAssertEqual(pending.count, 0)
  }

  /// The tail case: buffers appended after the queued drain ran are still
  /// there for `stop()`'s synchronous drain to find.
  func testBuffersAppendedAfterADrainSurviveForTheNextOne() {
    let pending = PendingPCMBuffers()
    pending.append(buffer(frames: 10))
    _ = pending.take()
    pending.append(buffer(frames: 40))
    XCTAssertEqual(pending.take().map(\.frameLength), [40])
  }

  func testConcurrentAppendsAreAllRetained() {
    let pending = PendingPCMBuffers()
    let group = DispatchGroup()
    for _ in 0..<200 {
      DispatchQueue.global().async(group: group) {
        pending.append(self.buffer(frames: 16))
      }
    }
    group.wait()
    XCTAssertEqual(pending.take().count, 200)
  }
}
