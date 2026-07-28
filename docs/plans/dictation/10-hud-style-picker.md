# 10 — hud-style-picker

User picked prototype directions A/C/D (docs: artifact "four directions"): keep
the pill, add a slim bar and a teleprompter card, chosen in Settings.

## Changes

1. **Setting.** `DictationSettings.hudStyle: HUDStyle` enum — `.pill` (default,
   today's UI), `.bar`, `.prompter`. Tolerant decode line in `init(from:)` +
   encode; new key, no migration. Picker in the Dictation tab's HUD section
   with one-line descriptions. Plumb through `DictationHUDController`.
2. **Bar (C).** Fixed 520×40pt, never resizes (no growth animation at all).
   Mic dot + RMS meter left, single 13pt draft line right, tail-anchored,
   older words slide left under a leading fade mask. Same material/level/
   positioning rules as the pill.
3. **Prompter (D).** 600pt wide card: header row (mic dot, meter, "Dictating",
   live word count), body shows the whole session — finalized text solid,
   volatile tail dimmed (55% white) — min 3 lines, grows downward to a 6-line
   cap (maxY fixed, one NSAnimationContext authority), then inner-scrolls,
   auto-following the newest text.
4. **Draft feed.** Controller exposes finalized + volatile as separate strings
   (pill/bar keep using the merged 120-char tail; prompter renders both, full
   length). No change to HUDState equality — draft stays out of it.

## Non-goals

Prompter does NOT morph into the review card (stop → existing card, unchanged).
Immediate mode still shows no live draft. Pill behavior bit-for-bit unchanged.

## Execution

Claude Opus 5 subagents via Workflow: implementer (worktree) → correctness +
integration reviewers → fixer. Gates: xcodegen + full xcodebuild test.
