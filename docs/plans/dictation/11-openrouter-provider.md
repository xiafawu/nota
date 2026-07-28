# 11 — openrouter-provider

Decisions: ADR 0002 (namespaced ids + execution kinds), grilling 2026-07-27.

## Changes

1. **Id namespacing (TS + Swift).** Provider derivation generalizes: first
   path segment of a namespaced id names the provider; flat ids keep the
   lookup table. Every `ModelEntry` gains `execution: "http" | "cli"`
   (everything existing is `http`).
2. **OpenRouter provider (TS).** `openrouter` provider: base URL
   `https://openrouter.ai/api/v1`, key `OPENROUTER_API_KEY`, same OpenAI
   client. Curated static shortlist of ~6 frontier summary models
   (Claude Sonnet + Haiku, Kimi, Qwen, GLM, one Llama flagship) — implementer
   verifies the exact live ids against `GET /api/v1/models`, does not trust
   training data. Shortlist entries merge into the effective catalog with
   `source: "curated"`; no pricing stored — cost lines print
   "refer to OpenRouter".
3. **Swift mirror.** `ModelProvider.openrouter` (+ key env), catalog decode of
   namespaced ids and the execution field (unknown kinds dropped per-entry),
   `PolishClient` base URL, polish picker filters `execution == .http`,
   API Keys tab gains an OpenRouter row.
4. **`nota config`** shows the OpenRouter key row. Settings validation and
   `nota models list` handle namespaced ids unchanged (they are ordinary
   registry entries).

## Non-goals

No CLI engines (plan 12). No auto-admit predicates for OpenRouter. No
transcription models via OpenRouter.

## Execution

Claude Opus 5 subagents via Workflow: implementer (worktree) → correctness +
integration reviewers → fixer. Gates: npm test + xcodegen + xcodebuild test.
