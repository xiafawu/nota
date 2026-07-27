# dictation-hud-zombie-selfheal

## Goal
Detect and self-heal the zombie-WindowServer state (2026-07-27 incident: panel
rendered/resized but `orderFrontRegardless()` never got it onscreen; AppKit
windowNumber stuck at 0; ~115 Hz OcclusionDetection churn on "Window 0x0"; only an
app restart fixed it). See `macos-app-lifecycle-traps` §12.

## Changes
- `DictationHUDPanel.show()`: after `orderFrontRegardless()`, assert
  `windowNumber > 0`. On failure: os_log error (this alone turns a silent day-long
  mystery into a one-line find).
- Self-heal in `DictationHUDController`: on detected failure, tear down and RECREATE
  the panel (fresh NSPanel → fresh server-side window), reposition, re-show once.
  Panel must therefore be replaceable (var, not let; content re-applied after swap).
- Watchdog: when hudState != .hidden and showHUD on, if the panel is still not
  visible ~1s after show, run the same self-heal path (covers failure modes that
  slip past the immediate check).
- Second consecutive failure after recreate: log fault + post a user notification
  ("Dictation HUD unavailable — restart Nota") via UserNotifications, once per run.
- Tests: pure-logic tests for the failure-detection/backoff state machine (no real
  WindowServer dependency — inject a `windowNumberProvider`).

## Non-goals
No root-cause hunt below AppKit (n=1, unreproducible); detection + heal + telemetry.

## Execution
Implementer: Claude Opus 5 via Workflow agent, isolation=worktree (lane A).
Verify: xcodegen generate; xcodebuild test.
