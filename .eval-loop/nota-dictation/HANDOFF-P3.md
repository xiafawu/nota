# PI/Codex Handoff — Dictation Phase 3 (hybrid injection)

Self-contained. Repo: `/Users/xiafawu/Developer/Nota`. Read
`.eval-loop/nota-dictation/CODEX-SPEC.md` §5 "P3" first — it is the authoritative
spec; this handoff adds context P3 inherits from the P1/P2 review.

## Where things stand

- P1 (residency/hotkey/capture) and P2 (Apple speech + paste-only injection) are
  **merged to master** (PR #44 + hotfix #47). Master is green; the app builds,
  deploys, and dictates via paste.
- Branch off **master**. One reviewable PR for P3.

## Your task: PHASE 3 ONLY (spec §5 "P3 — Hybrid injection")

- Extend `TextInjector` (macos/Nota/Dictation/TextInjector.swift) with AX
  (`AXUIElementSetValue`/insert) and CGEvent keystroke strategies; fallback
  chain AX → CGEvent → paste, plus a per-bundle-id override table (force paste
  for Electron/Chrome family, CGEvent for terminals).
- `FocusedTarget` capture immediately before injection (bundle id, secure-input
  flag, AX element) per spec §4.
- Secure/password fields must no-op with a user-visible notice.
- Do NOT start P4 (no formatting rules, no settings pane, no toggle mode).

**Lane manifest:** single `sequential` lane — one agent. The strategies, the
override table, `FocusedTarget`, and all three inherited debts converge on
`TextInjector.swift` + `DictationController.swift`; a team would collide on the
same files. Do not split.

**Hard constraints:** Swift/macOS only — do NOT touch `src/**` (TypeScript CLI,
pipeline, `usage-stats.ts`, `pricing.ts`), `tests/**` (TS), `src/registry.ts`,
or `~/.nota/settings.json`. New code stays under `macos/Nota/Dictation/` unless
an existing app file is named above. Full fence: CODEX-SPEC §2.

## Debts inherited from P2 — fix in this phase

1. **Main-thread block**: `TextInjector.inject()` runs on the MainActor and
   sleeps (~80ms + 10ms + 30ms ≈ 120ms UI freeze per dictation). Move injection
   off the main thread / use async delays.
2. **Clipboard-restore race**: paste strategy restores the pasteboard 80ms after
   Cmd-V; slow apps may read post-restore contents. Make the delay per-app
   tunable in the override table and/or verify with a changeCount check.
3. **NSLock in async context** (Swift 6 warnings): migrate the flagged state to
   `OSAllocatedUnfairLock` or an actor as encountered.

## Build gate (non-negotiable)

The TS test suite says NOTHING about Swift. Before declaring done:
`npm run build:macos` must print `** BUILD SUCCEEDED **`. (PR #46 merged
uncompilable Swift because only `npm test` was run; hotfix #47 repaired it.)

## Dev-machine notes

- Local deploys are signed with the stable identity "Nota Local Signing"
  (`scripts/create-signing-cert.sh`, one-time) so TCC grants persist. Do not
  ad-hoc sign or alter the deploy signing block.
- Accessibility + Input Monitoring + Microphone are already granted to the
  deployed app; `scripts/deploy-macos-app.sh` handles kill-first, stray-bundle
  deregistration, and launch.

## Acceptance (spec §5 P3)

Dictation lands text in TextEdit, Chrome (address bar + textarea), Slack,
Terminal, VS Code; password fields safely refused; document which strategy each
app resolved to; injection no longer blocks the main thread. Manual matrix runs
on the user's machine — implement + unit-test the strategy table and state
machine; the user validates live apps.

## Required reply

Reply using exactly these sections:

```
## Branch & commits        (branch name, one line per commit)
## Per-lane outcomes       (what each lane/fix delivered)
## Verification evidence   (commands run + REAL output, not summaries —
                            must include `npm run build:macos` → BUILD SUCCEEDED)
## Deviations from spec    (anything skipped, worked around, or changed — say so plainly)
## Cannot-verify-here      (what needs the user's machine — e.g. the live app matrix)
## Orchestrator signals    (state changes, what this unblocks, suggested next dispatch —
                            written for a FRESH orchestrator session)
```
