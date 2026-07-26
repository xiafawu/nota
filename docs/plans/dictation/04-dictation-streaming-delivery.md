# dictation-streaming-delivery

## Goal
Trailing-append streaming: polished sentences typed into the target while the user speaks;
HUD shows the live rough draft. Behind a toggle, default OFF until owner validates.

## Design
```
mic → DictationTranscriber → volatile tail ────────────→ HUD rough-draft line
                └─ finalized sentence → L2 → L3 polish → append delta into target
                                        (serial async queue, deepseek-v4-flash)
```

## Changes
- `AppleSpeechStream` (`AppleSpeechStream.swift:260-297`): finality today is inferred only
  at teardown (`didFinalize`, `:265`). Use the `volatileRangeChangedHandler` init variant +
  result ranges to emit `Hypothesis(isFinal: true)` per finalized sentence mid-session;
  legacy behavior preserved when the toggle is off.
- `DictationController`: hypothesis loop (`DictationController.swift:205`) drives the
  per-sentence pipeline; `FocusedTarget.capture()` moves to session START; append-only —
  delivered text is never rewritten; final flush of the un-finalized tail on stop.
- `TextInjector`: append mode — keyEvents/paste strategies inject the delta string; AX
  strategy reads current value + appends (falls back to keyEvents delta on read failure).
  Secure-field refusal unchanged.
- HUD: `ListeningView` gains a rough-draft line (volatile tail, last ~60 chars) above the
  RMS bars.
- Setting: `streamingDelivery` toggle in `DictationSettingsView`, default OFF.
- Tests: sentence segmentation, append-delta computation, injection strategy extensions.

## Execution
Implementer: Claude Opus 5 (owner-selected) via Workflow agent, isolation=worktree,
forked only AFTER plans 01-03 merge to master. Verify: `xcodebuild test`; owner live-smoke.
