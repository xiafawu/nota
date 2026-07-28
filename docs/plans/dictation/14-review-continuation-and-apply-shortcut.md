# 14 — review-continuation-and-apply-shortcut

User feedback 2026-07-28, review delivery mode. Two problems.

## 1. Bug: ⌘↩ does not insert; the Apply button does

Symptom: with the review card open, pressing ⌘↩ visibly accepts (card goes
away) but nothing lands in the target app; clicking Apply inserts fine.
Investigate the local-key-monitor path vs the button path in
`DictationReviewPanel.swift` / `injectReviewed` — candidate causes: the
monitor's apply reading stale/empty editor text (binding not yet flushed),
the ⌘↩ keyDown being consumed differently so the key-restore settle
(`reviewKeyRestoreSettleNs`) starts too early, or the synthetic keystrokes
racing the still-held Cmd modifier (user's ⌘ is physically down when CGEvent
posts — a Cmd-tagged paste/typing stream is a real suspect). Root-cause with
a test or a reproduction note, then fix; both paths must share one code path.

## 2. Feature: pressing the trigger again grows the review, never discards it

Today a new session cancels an open review and its text is lost (plan 07
rule). New behavior: with a review open, the trigger starts a *continuation*
— the card stays (shows a listening state), the new session recognizes and
polishes as usual, and its text is APPENDED to the card's buffer (one space
or newline separator; owner edits preserved untouched). ⌘↩ applies the whole
batch once; Escape discards the whole batch. Target pid: re-captured at each
press, newest capture wins (documented). Auto-learn budget stays per-session.
Escape/apply during an active continuation recording is refused until stop.

## Non-goals

No change to immediate/streaming modes; no panel redesign.

## Execution

Bundled with plan 13 in one Claude Opus 5 workflow (implementer worktree →
2 reviewers → fixer). Gates: xcodegen + xcodebuild test.
