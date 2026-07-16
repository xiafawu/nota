# PI/omp Handoff — Dictation P4.5 (session feedback HUD)

Self-contained. Assume no prior conversation. Repo: `/Users/xiafawu/Developer/Nota`.
Branch off **master** (green at PR #54 or later). One reviewable PR. No other
feature branches in flight.

## Context

Dictation (P1–P4 merged) works but is invisible: during a hold/toggle session
nothing appears on screen, so users can't tell listening from dead. Polish
failures and secure-field refusals are also only visible in the menu bar.
User picked a Wispr-Flow-style floating pill HUD.

## Hard constraints

- Swift/macOS only, under `macos/Nota/**`. No `src/**`, no TS, no deploy/
  signing scripts, no CLI settings JSON.
- **The HUD must NEVER take key focus or activate Nota.** Injection captures
  `FocusedTarget` from the frontmost app — a HUD that becomes key window makes
  dictation inject into Nota itself. Use a non-activating `NSPanel`
  (`.nonactivatingPanel`, `hidesOnDeactivate = false`, `level = .statusBar`,
  `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`,
  `ignoresMouseEvents = true`), content via `NSHostingView`.
- No new TCC permissions. Do not touch `AppleSpeechStream` internals
  (Int16 `convertBuffer` path stays as-is).

## Task (single `sequential` lane — one agent; HUD view-model, panel, and
controller state all interlock; do not split)

1. **HUD panel** — small pill, bottom-center of the screen with the focused
   window (fall back to main screen). States driven by `DictationController`:
   - listening: mic glyph + live level meter (compute a simple RMS level in
     `MicCapture`'s tap and publish it; a 5–8 bar meter is enough, no FFT)
   - processing: spinner + "Transcribing…" / "Polishing…" (distinguish the
     polish step so slow LLM calls read as alive)
   - success: injected-text snippet or checkmark, fade out ~1s
   - warning/error: `lastPolishWarning` / `lastSecureFieldNotice` / `.failed`
     message, auto-hide ~3s
   - hidden when idle.
2. **View-model** — pure `HUDState` mapping from controller state + warnings,
   unit-testable without AppKit (this mapping is the REQUIRED test surface).
3. **Settings** — "Show dictation HUD" toggle (default ON) in the existing
   Dictation tab, persisted via `DictationSettings` (add a field; the store
   round-trip test must be extended — required test, part of the fence).
4. **Menu bar** — keep existing status text in sync; no redesign.

## Stop-fence

P4.5 ONLY. No P5 (AssemblyAI realtime), no history UI, no formatter changes,
no new polish behavior.

## Verify (non-negotiable; named tests are part of the fence)

- `npm run build:macos` prints `** BUILD SUCCEEDED **`.
- `cd macos && xcodebuild test … -destination 'platform=macOS'` green,
  including NEW: `HUDStateTests` (controller-state → HUD-state mapping incl.
  warning precedence) and the extended `DictationSettingsStoreTests`
  round-trip with the HUD toggle field.
- `npm test` untouched/green.
- Acceptance (user validates live): pill appears on hold within ~100ms;
  waveform moves with voice; polish step visibly distinct; dictating into
  TextEdit with the HUD visible still injects into TextEdit (focus not
  stolen); HUD toggle off = old behavior.

## Dev-machine notes

- Deploys signed with "Nota Local Signing"; do not alter signing.
- Controller state enum + `lastPolishWarning`/`lastSecureFieldNotice` already
  exist (see `DictationController.swift`, `TextInjector.lastSecureFieldNotice`).

## Required reply

Reply using exactly these sections:

```
## Branch & commits        (branch name, one line per commit)
## Per-lane outcomes       (what each lane/fix delivered)
## Verification evidence   (commands run + REAL output, not summaries —
                            build:macos BUILD SUCCEEDED + xcodebuild test tail)
## Deviations from spec    (anything skipped, worked around, or changed — say so plainly)
## Cannot-verify-here      (what needs the user's machine — live HUD behavior, focus check)
## Orchestrator signals    (state changes, what this unblocks, suggested next dispatch —
                            written for a FRESH orchestrator session)
```
