# dictation-hud-pill-redesign

## Goal
Fix owner-reported pill problems: left-aligned mic+meter, tiny truncated rough draft,
awkward per-word width jumps, non-fluid frame animation.

## Owner requirements (2026-07-27)
- Mic + waveform centered, not left-aligned.
- Rough draft readable: larger type, more of the sentence visible.
- Pill must NOT jump wider word-by-word while speaking.
- Motion must feel smooth/fluid.

## Changes (macos/Nota/Dictation/DictationHUDPanel.swift, DictationHUDController.swift)
- Listening layout: draft text block above a CENTERED mic+meter group; whole pill
  content center-aligned.
- Draft text: `.callout` (up from `.caption`), up to 2 lines, head-truncated so the
  newest words always show; fixed content width (~420pt) whenever a draft exists, so
  the pill widens ONCE when text starts, then stays put — only height animates after.
- Frame animation: single animation authority. Today NSAnimationContext (0.22 easeOut)
  fights SwiftUI's own animations → jitter. Pick one path (prefer: panel frame set
  from a spring-timed NSAnimationContext for height; SwiftUI handles content-only
  transitions), verify no double-animation.
- Level bug: `isFloatingPanel = true` (init :40) silently resets `level = .statusBar`
  (:36) to `.floating` — observed live as CGWindowLayer 3. Set level AFTER, or drop
  `isFloatingPanel`; pill must stay above fullscreen apps (verify layer 25 via
  CGWindowListCopyWindowInfo).
- Update HUDStateTests + add a fitting-size stability test (same draft width for
  successive longer strings once past the cap).

## Execution
Implementer: Claude Opus 5 via Workflow agent, isolation=worktree (lane A).
Verify: xcodegen generate; xcodebuild test -project macos/Nota.xcodeproj -scheme Nota.
