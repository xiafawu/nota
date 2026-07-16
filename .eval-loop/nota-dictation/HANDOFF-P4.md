# PI/omp Handoff — Dictation Phase 4 (formatting + settings + polish)

Self-contained. Assume no prior conversation. Repo: `/Users/xiafawu/Developer/Nota`.
Read `.eval-loop/nota-dictation/CODEX-SPEC.md` §5 "P4 — Formatting + settings +
polish" first — it is the authoritative spec (types in §4: `DictationSettings`,
`ActivationMode`, `TriggerKey`). Branch off **master** (green at `a53b0fc` or
later). One reviewable PR. No other feature branches are in flight.

## Context

- P1–P3 merged: menu-bar residency, Fn/Globe hold-to-talk, Apple SpeechAnalyzer
  (Int16-negotiated input, PR #50) with SFSpeechRecognizer fallback, hybrid
  AX → CGEvent → paste injection with per-app overrides (PR #49), finalize/
  zero-result hang fixes + 5s watchdog in `finish()` (PR #51).
- DeepSeek summary models just landed in `ModelRegistry.swift` (PR #52) — the
  polish model picker must stay registry-driven so they appear automatically.

## Hard constraints

- Swift/macOS only. Do NOT touch `src/**`, `tests/**` (TS), `scripts/deploy-*`,
  `scripts/create-signing-cert.sh`, or the CLI settings schema
  (`~/.nota/settings.json`) — dictation prefs are Swift-only via
  `NotaSettingsStore` + `UserDefaults` (spec §2).
- Secrets only through `ApiKeyStore`; never display or re-serialize key values.
- Do not change `LSUIElement`/Dock behavior, app icon config, or signing.

## Locked decisions (not re-openable)

Spec §3 table. Load-bearing for P4: tiered formatting (raw → local rules →
optional LLM polish, rules-only on any polish failure); hold + toggle
activation; settings/secrets Swift-only; polish model = existing summary
registry entry.

## Task + lane manifest (agent team OK — two lanes)

- **Lane A (parallel-safe)** — owns `macos/Nota/Dictation/Formatter.swift` +
  `macos/Nota/Dictation/Tests/FormatterTests.swift` ONLY. Pure local rules:
  whitespace normalize, capitalize first word, drop standalone "um"/"uh"/
  "you know", basic false-start cleanup, terminal punctuation only when
  absent. Deterministic, no I/O, no dependency on lane B.
- **Lane B (sequential, one agent)** — everything else, shared files:
  `DictationSettings` persistence in `NotaSettingsStore.swift`; toggle mode +
  configurable trigger in the hotkey path; `DictationController` pipeline
  order (finalize → rules → optional polish → inject); polish client using
  `ModelRegistry` + `ApiKeyStore` (OpenAI-compatible chat call; respect
  per-entry `baseURL` semantics mirrored from `src/registry.ts`); Settings UI
  tab (activation mode, trigger, engine, polish toggle, polish model picker,
  privacy copy: polish sends final text to the provider, rules are the
  offline fallback).
- Lane B also pays two P3 debts: `tryPasteInject` restore `Task` captures
  `self` strongly in a `defer` — make it `[weak self]`; replace the 15 ms
  `usleep` in `tryCGEventInject` with a non-blocking delay if the helper
  becomes async (skip if it stays sync).
- One commit per lane minimum; lane B may split commits by concern
  (settings / toggle / polish).

## Stop-fence

PHASE 4 ONLY. Do NOT start P5 (AssemblyAI realtime), do NOT add new CLI
commands or TS changes, do NOT redesign existing settings tabs beyond adding
the dictation section.

## Verify (non-negotiable)

- `npm run build:macos` prints `** BUILD SUCCEEDED **` — the TS suite says
  nothing about Swift.
- `cd macos && xcodebuild test -project Nota.xcodeproj -scheme Nota
  -destination 'platform=macOS'` green, including new FormatterTests,
  settings round-trip tests, and polish-fallback tests (no key / model error
  → rules-only result + warning path).
- `npm test` still green (should be untouched).
- Acceptance (spec §5 P4): raw vs rules vs polished distinguishable in
  diagnostics/tests; rules output works with no API key; hold AND toggle both
  work; prefs survive relaunch; existing model settings tabs unaffected.
  Live relaunch/microphone checks run on the user's machine — implement +
  unit-test; the user validates live.

## Dev-machine notes

- Deploys are signed with stable identity "Nota Local Signing"; TCC grants
  persist. Do not ad-hoc sign or alter the deploy signing block.
- SpeechAnalyzer feeds must stay in the negotiated Int16 format
  (`AppleSpeechStream.convertBuffer`) — do not bypass it when reordering the
  pipeline.

## Required reply

Reply using exactly these sections:

```
## Branch & commits        (branch name, one line per commit)
## Per-lane outcomes       (what each lane/fix delivered)
## Verification evidence   (commands run + REAL output, not summaries —
                            must include `npm run build:macos` → BUILD SUCCEEDED
                            and the xcodebuild test tail)
## Deviations from spec    (anything skipped, worked around, or changed — say so plainly)
## Cannot-verify-here      (what needs the user's machine — e.g. relaunch persistence, live mic)
## Orchestrator signals    (state changes, what this unblocks, suggested next dispatch —
                            written for a FRESH orchestrator session)
```
