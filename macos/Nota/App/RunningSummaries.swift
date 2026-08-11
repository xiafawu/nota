import Foundation

/// The summary subprocesses that are alive right now (XIA-435).
///
/// ⌘Q's prompt says: *"Quitting now leaves it unsummarized — you can retry the
/// summary from History at any time."* A Foundation child survives its parent,
/// so with nothing here that sentence was wrong, in one benign way and one
/// harmful one. Benign: the orphan finishes and writes `done` plus the summary,
/// so the record is not unsummarized after all. Harmful: the owner quits and
/// relaunches inside the summary window, the launch sweep stamps the record
/// `failed:summarizing` + `interrupted`, the drawer offers Retry — and pressing
/// it spawns a **second** `nota history summarize <id>`. That is a second paid
/// model call and two uncoordinated read-modify-write cycles on the same
/// `<id>.json`, both appending to `usage`. The ledger cannot see the orphan:
/// it lives in memory and the quit destroyed it.
///
/// So the child is killed on the way out and the prompt becomes true. The
/// record is left saying `summarizing`, which is precisely the state the launch
/// sweep resolves to "Interrupted · transcript saved" with its Retry — the
/// sentence the prompt already promises.
///
/// Deliberately **not** in `BackgroundProcessing.swift`: that file is the part
/// of this lane with no AppKit, no model and no subprocess in it. This is the
/// one piece that owns a `Process`.
///
/// Keyed by record id like everything else on this path, so a record whose
/// summary ends normally takes its own handle out and no other.
final class RunningSummaries: @unchecked Sendable {
  /// The app's registry. A singleton for the same reason `ProcessingLedger` is
  /// one: `AppDelegate.applicationShouldTerminate` has no route to `NotaModel`.
  static let shared = RunningSummaries()

  private let lock = NSLock()
  private var processes: [String: Process] = [:]

  init() {}

  /// How many summaries are alive. Bookkeeping only — ⌘Q asks the *ledger*
  /// whether to prompt, because a job that has not spawned yet is still work.
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return processes.count
  }

  func register(recordID: String, process: Process) {
    lock.lock()
    defer { lock.unlock() }
    processes[recordID] = process
  }

  func unregister(recordID: String) {
    lock.lock()
    defer { lock.unlock() }
    processes.removeValue(forKey: recordID)
  }

  /// Kill every live summary and forget them all. Returns how many were sent a
  /// signal, which is what a test can watch.
  ///
  /// `isRunning` is checked first: `terminate()` on a process that was never
  /// launched raises, and one that has already exited has nothing to receive.
  /// The script ends in `exec node …`, so the signal reaches node itself rather
  /// than a shell that would leave it orphaned.
  @discardableResult
  func terminateAll() -> Int {
    lock.lock()
    let live = processes
    processes.removeAll()
    lock.unlock()

    var signalled = 0
    for process in live.values where process.isRunning {
      process.terminate()
      signalled += 1
    }
    return signalled
  }
}
