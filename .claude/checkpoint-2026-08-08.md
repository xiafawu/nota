# Checkpoint — 2026-08-08 02:00 PDT

## Where things stand

Master is `ec1026c`, local only. Nothing pushed, nothing deployed.
XIA-435, XIA-432, XIA-436 are merged and closed. XIA-421 map updated.

## XIA-441 — transcript ledger (NOT merged, parked)

Branch `xia-441-transcript-ledger`, in worktree
`.claude/worktrees/agent-a31d3744e39ca0b59`. Rebased clean onto `ec1026c`.

- `931fc6b` — Direction 1, typography (a speaker was a bold prefix, so a turn
  was never an object)
- `ad90c98` — Direction 2, the ledger rail (the diarization was in the text and
  nowhere on the page)

1533 insertions, 13 files. Pre-rebase these were `7841e72` / `ad917fb` — the
agent's report names those SHAs; same content, different SHAs.

### Verified (and HOW)

- Diff touches **0 files** under `macos/Nota/Dictation/` and **0** under
  `src/` or `tests/`. Checked with `git diff --name-only ec1026c..HEAD | grep -c`.
  So `NotaDictationTests`, `tsc` and `vitest` are *inapplicable*, not skipped.
- Full clean build from wiped DerivedData compiled all changed files, 0 errors
  (agent-measured, pre-rebase).
- `NotaUITests` 406 passed / 0 failures — **Direction 1 state ONLY**, measured
  before `TranscriptLedger.swift` and `TranscriptLedgerTests.swift` existed.
  This number CANNOT stand in for Direction 2.

### NOT verified

- **Direction 2's 17 tests in `TranscriptLedgerTests.swift` have never
  executed.** Not once, by the agent or by me. They compile; that is all.
- Eight total attempts died at
  `Nota (<pid>) encountered an error (The test runner hung before establishing
  connection.)` + `Timed out after 120.0s while initiating control session with
  daemon`. Zero tests ran, zero crash markers.
- **The diff IS exonerated** (control run completed 02:11, after the note
  below was first written). Master `ec1026c` — containing none of this branch —
  hangs identically: host `Nota[95485]` up at 02:11:55, same
  `linkd.autoShortcut` / Process Instance Registry errors, 0 tests in 8 min.
  My suspicion of `MainPaneView`/`Tokens` was wrong.
- **Likely mechanism, NOT proven:** `/Applications/Nota.app` has been running
  **18h51m** (pid 81410) under the same bundle id `com.xiafawu.nota` the test
  host launches with. Known racy single-instance-guard-vs-XCTest trap in this
  repo. Explains the intermittency (415/0 and 406/0 both landed earlier the
  same night). Cheap disproof: quit the app, re-run. Owner's app, owner's call.

### To finish this, on a quiet machine

Control on master is DONE (above) — do not repeat it.

1. **Quit `/Applications/Nota.app`** first, or confirm no `com.xiafawu.nota`
   instance is running. This is the prime suspect.
2. `cd macos && xcodegen generate` (REQUIRED — `Nota.xcodeproj` is gitignored;
   a stale one fails with `cannot find type 'StoredStorageSummary' in scope`,
   which looks like broken source and is not).
3. Run the lane from INSIDE the worktree (I reported master's numbers as a
   lane's once already this session — check `pwd`).
4. Merge on trailing `** TEST SUCCEEDED **` + 0 crash markers. Expect a count
   ABOVE 406 — the 17 ledger tests are new.

### Key numbers and their sources

- 415/0 NotaUITests — XIA-436 worktree, tonight. Proves the harness worked
  today. Measured in that worktree, not in master's tree.
- 406/0 — Direction 1 state, agent-measured.
- 687 passed / 1 skipped vitest — master with XIA-436. 637/1 is the pre-436
  baseline; the agent reported 637 because it branched pre-436. Both correct
  for their base. Irrelevant to this diff (0 TS files).
- Load was 14 at start of verification, **48** when I stopped. 21→41
  concurrent `xcodebuild` from ~10 other sessions.

## Traps confirmed this session

- `xcodebuild` reports "exit code 0" for a compound shell command even when the
  log says `** TEST FAILED **`. Trust the log.
- A test host process EXISTING is not a handshake. I claimed the handshake
  succeeded because `Nota[82941]` was alive; it sat at 0.1% CPU and never
  connected. Only a trailing `** TEST SUCCEEDED **` counts.
- `pkill -f 'xcodebuild test -project Nota'` matches OTHER sessions' runs.
  Kill by PID. Two runs here started at the identical second.
- The `FocusedTargetTests` crash in `NotaDictationTests` is FLAKY, not
  deterministic (established via XIA-436). A green run is luck.

## Open, not filed

- XCTest gate for the unguarded `CGEvent` session tap in `DictationController`
  (`HotkeyMonitor.swift:56`, `.cgSessionEventTap` + `.headInsertEventTap`).
  Diagnosed, never filed, never implemented — deferred because all three lanes
  were rewriting `NotaModel.swift` at the time. This is a candidate cause for
  launch-time test hangs and is still unfixed.
- Flaky `FocusedTargetTests` crash ticket.
- XIA-440 (2 semantic collisions: `.finalizing` unreachable; deleting a record
  whose `ProcessingLedger` job is in flight). Open, blocks XIA-438.
- XIA-439 (VoiceOver silence + placebo width test). Open, blocks XIA-438.
- 4 XIA-435 follow-ups, 2 XIA-432 follow-ups.
- iOS companion app: shape agreed (companion), subset of functions NOT decided.

## Owner decision waiting

⌘L drawer (380pt, `.topTrailing` overlay) sits directly on the new 288pt
session column. Three options in CLAUDE.md; implementer accepted the overlap
rather than reversing the locked visual direction. On the map under
"Not yet specified".
