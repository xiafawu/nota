import Foundation
import XCTest

@testable import Nota

/// A counter that only the main actor touches, so a main-actor task can leave
/// evidence that it ran.
@MainActor
private final class MainActorTicks {
  var count = 0
}

/// XIA-435 — the summary runs in the background, and "background" is a claim
/// about the main actor.
///
/// `NotaModel` cannot be constructed in a test (its `init` sweeps the real
/// `~/.nota` and runs preflight), so the subprocess seam is a `nonisolated
/// static` on it: that is exactly the property under test, and a test that can
/// call it without a model is the proof.
@MainActor
final class BackgroundSummaryProcessTests: XCTestCase {

  private var scratch: URL { FileManager.default.temporaryDirectory }
  private var environment: [String: String] { ProcessInfo.processInfo.environment }

  /// THE BLOCKER, as a test.
  ///
  /// The old body was four synchronous blocking calls with no suspension point
  /// in a `@MainActor` method, so awaiting it from a main-actor `Task` ran the
  /// whole subprocess inline on the main thread: minutes of beachball for a
  /// long meeting, up to 30 minutes for a `claude-code/*` summary model. During
  /// it the drawer's 1s freshness ticker could not fire, a second Stop press
  /// could not be delivered, and ⌘Q was never dispatched.
  ///
  /// The ticker task here is the main actor's stand-in for all three: it can
  /// only tick if the main actor is free while the child runs. With the call
  /// main-actor-isolated and blocking it never gets a turn — measured at 0
  /// ticks when the old shape was restored to check this goes red.
  func testTheSummarySubprocessLeavesTheMainActorFree() async {
    let ticks = MainActorTicks()
    let ticker = Task { @MainActor in
      while !Task.isCancelled {
        ticks.count += 1
        try? await Task.sleep(nanoseconds: 20_000_000)
      }
    }

    let started = Date()
    let outcome = await NotaModel.runShellScript(
      "sleep 0.6",
      workingDirectory: scratch,
      environment: environment
    )
    let elapsed = Date().timeIntervalSince(started)
    ticker.cancel()

    XCTAssertNil(outcome.launchError)
    XCTAssertEqual(outcome.status, 0)
    XCTAssertGreaterThan(elapsed, 0.4, "the call did not actually wait for the child")
    XCTAssertGreaterThan(ticks.count, 5, "the main actor was held for the child's whole life")
  }

  /// The other half of the same fix. Reading stdout to EOF and *then* stderr —
  /// the shape this replaced — blocks forever the moment the child fills the
  /// stderr pipe's buffer (64 KB) and stops draining, because the child then
  /// blocks on write and never closes stdout. `nota history summarize` writes
  /// its progress to stderr, so this is the ordinary case for a long run and
  /// not an exotic one.
  func testBothPipesAreDrainedConcurrently() async {
    let outcome = await NotaModel.runShellScript(
      "head -c 200000 /dev/zero | tr '\\0' 'e' >&2; head -c 4096 /dev/zero | tr '\\0' 'o'",
      workingDirectory: scratch,
      environment: environment
    )
    XCTAssertNil(outcome.launchError)
    XCTAssertEqual(outcome.status, 0)
    XCTAssertEqual(outcome.stderr.utf8.count, 200_000)
  }

  /// A launch that never happened is reported as one, rather than as an exit
  /// status of a process that does not exist.
  func testALaunchFailureIsNamed() async {
    let outcome = await NotaModel.runShellScript(
      "true",
      workingDirectory: URL(fileURLWithPath: "/no/such/directory/at/all"),
      environment: environment
    )
    XCTAssertNotNil(outcome.launchError)
  }

  /// A non-zero exit is a failed summary, and its stderr is what the log gets.
  func testAFailedRunCarriesItsStatusAndStderr() async {
    let outcome = await NotaModel.runShellScript(
      "echo 'summary model unavailable' >&2; exit 3",
      workingDirectory: scratch,
      environment: environment
    )
    XCTAssertEqual(outcome.status, 3)
    XCTAssertTrue(outcome.stderr.contains("summary model unavailable"))
  }

  // MARK: - ⌘Q kills the child

  /// ⌘Q's prompt promises the record is "left unsummarized". A Foundation child
  /// survives its parent, so without this the orphan either finished (and the
  /// promise was false) or was still running when the owner relaunched — where
  /// the launch sweep offers a Retry that spawns a **second** paid summary over
  /// the same record's JSON.
  func testQuitAnywayTerminatesALiveSummaryChild() async {
    let registry = RunningSummaries()
    let run = Task { [scratch, environment] in
      await NotaModel.runShellScript(
        "sleep 30",
        workingDirectory: scratch,
        environment: environment,
        onLaunch: { registry.register(recordID: "r1", process: $0) }
      )
    }

    var waited = 0
    while registry.count == 0 && waited < 500 {
      try? await Task.sleep(nanoseconds: 10_000_000)
      waited += 1
    }
    XCTAssertEqual(registry.count, 1, "the child never registered")

    XCTAssertEqual(registry.terminateAll(), 1)
    let outcome = await run.value
    XCTAssertNotEqual(outcome.status, 0, "the child was not signalled")
    XCTAssertEqual(registry.count, 0, "a terminated child is forgotten")
  }

  /// An empty registry is a no-op, and a child that ended on its own is not
  /// signalled after the fact.
  func testTerminateAll_signalsNothingItDoesNotHold() async {
    let registry = RunningSummaries()
    XCTAssertEqual(registry.terminateAll(), 0)

    let outcome = await NotaModel.runShellScript(
      "true",
      workingDirectory: scratch,
      environment: environment,
      onLaunch: { registry.register(recordID: "r1", process: $0) }
    )
    XCTAssertEqual(outcome.status, 0)
    // The record is still registered — `runSummaryProcess` unregisters, this
    // test does not — but the process is gone, so nothing is signalled.
    XCTAssertEqual(registry.count, 1)
    XCTAssertEqual(registry.terminateAll(), 0)
  }
}
