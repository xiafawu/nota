# 12 — cli-summary-engines

Decisions: ADR 0003 (CLI engines, summary path only), grilling 2026-07-27.
Builds on plan 11's namespaced ids + execution kinds.

## Changes

1. **Registry entries (TS only).** `claude-code/sonnet|opus|haiku` and a
   curated Codex set (implementer verifies current `codex exec -m` model ids)
   with `execution: "cli"`, no API key env. Never admitted to the Swift
   catalog's polish surface (plan 11's execution filter already excludes).
2. **Subprocess engine.** `src/pipeline/summarize.ts` branches on execution:
   `cli` spawns `claude -p` / `codex exec` with the same prompt content the
   HTTP path sends, transcript on stdin (never argv — size and quoting),
   plain-text output contract, per-call timeout scaled to input size.
   Sectioned >100k-token mode spawns once per section through the same path.
3. **Failure contract.** Binary missing from PATH, unauthenticated, non-zero
   exit, or timeout → hard error naming the fix and the wait; no fallback to
   HTTP models. CLI engines never join the key-aware default chain.
4. **Diagnostics.** `nota config` gains `claude` / `codex` rows: binary path +
   version, or "not found". Cost lines print "included w/ subscription".
   `nota models list` marks these entries' source as `cli`.

## Non-goals

No CLI engines in the macOS app or any dictation path. No output streaming.
No auto-selection ever.

## Execution

Claude Opus 5 subagents via Workflow: implementer (worktree) → correctness +
integration reviewers → fixer. Gates: npm test (Swift gate only if Swift
files change — they should not).
