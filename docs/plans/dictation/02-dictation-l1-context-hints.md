# dictation-l1-context-hints

## Goal
Bias `DictationTranscriber` toward dictionary + ambient identifiers via
`AnalysisContext.contextualStrings`; capture app + window-title context at recording start.

## Facts
- `AppleSpeechStream` already uses `DictationTranscriber` (`AppleSpeechStream.swift:233`) —
  the class Apple documents `contextualStrings` for. Hard cap: 100 short (1-2 word) phrases.
- Plain `SpeechAnalyzer(modules:)` takes no context → `try await analyzer.setContext(ctx)`
  before `start(inputSequence:)`.

## Changes
- `macos/Nota/Dictation/ContextSnapshot.swift` — struct {appName, bundleID, windowTitle};
  `capture()` via `NSWorkspace.frontmostApplication` + AX `kAXFocusedWindowAttribute` →
  `kAXTitleAttribute` (guard `AXIsProcessTrusted()`, nil-safe). `harvestIdentifiers()`:
  tokenize title for code-ish tokens (case-mix / digits / `._-` / file extensions).
- `DictationController.beginCaptureAndSpeech` (`DictationController.swift:192-202`): capture
  snapshot at START (VoiceInk pattern — latency hides under speech), store on session.
- `AppleSpeechStream`: accept hint list; `contextualStrings[.general]` = starred+manual
  first, then harvested, cap 100; `setContext` before start. Debug-log the hint count.

## Non-goals
No custom LM; no clipboard / selected-text / screen capture (owner declined 2026-07-26).

## Execution
Implementer: Claude Opus 5 (owner-selected) via Workflow agent, isolation=worktree.
Verify: `xcodebuild test`; manual A/B with owner's genc2rust clip after merge.
