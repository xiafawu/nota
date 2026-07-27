# dictation-review-before-insert

## Goal
Third delivery mode: talk → polish → OWNER EDITS the text → apply → the app LEARNS
from the owner's manual corrections (highest-quality dictionary signal).

## Design
- `DeliveryMode` enum replaces the `streamingDelivery` bool: `immediate` | `streaming`
  | `review`. Settings migration: stored `streamingDelivery: true` decodes as
  `.streaming`; absent/false → `.immediate`. Tolerant decode per CLAUDE.md rule.
- Review flow (mode == .review): capture + polish exactly as `.immediate`, but instead
  of injecting, show a small floating REVIEW PANEL near the pill position: editable
  text (NSTextView/TextEditor), polished text pre-filled, buttons Apply (⌘⏎) and
  Discard (esc). Panel CAN become key (unlike the pill) — user types in it; activating
  Nota is acceptable here since the target was captured at session start and injection
  posts to the stored pid.
- Apply: inject the EDITED text via existing TextInjector (.standard mode) into the
  session-start target; close panel. Discard: close, inject nothing.
- Learning: diff polished → user-edited via the existing AutoLearn candidate machinery
  (before = polished, after = edited). User edits are high-confidence: same
  identifier-shaped gate (no prose learning — feedback-loop guard stays), but ALSO
  record the replaced wrong form into the term's `spokenForms`, so next time L2 fixes
  it deterministically. Store via DictionaryStore.add(source: .learned).
- HUD: pill hides when the review panel opens; review panel is the feedback.
- Streaming + review are mutually exclusive by construction (single enum).

## Changes
`DictationTypes.swift` (enum + migration), `DictationController.swift` (branch on
mode), NEW `DictationReviewPanel.swift`, `DictationSettingsView.swift` (mode picker
replaces the streaming toggle), tests: migration, apply/discard paths, edit-diff
learning (incl. spokenForms recording), no-injection-on-discard.

## Execution
Implementer: Claude Opus 5 via Workflow agent (lane B, same worktree as lane A).
Verify: xcodegen generate; xcodebuild test. Owner live-smoke after merge.
