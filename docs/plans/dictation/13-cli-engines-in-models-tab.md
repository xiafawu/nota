# 13 — cli-engines-in-models-tab

User decision 2026-07-28. The app's processing shells out to the TS pipeline
(`nota-app-run.sh`), so a CLI-engine summary pin works for app-processed
recordings too — ADR 0003's exclusion was scoped wider than its rationale.

## Changes

1. **Models tab summary picker** offers the seven CLI engines (from
   `ModelRegistry.cliEngineModelIDs`, labels like "Claude Sonnet
   (subscription)"), appended after the catalog entries. Footer notes they
   need the `claude` / `codex` binary installed and logged in, and bill the
   owner's subscription.
2. **Polish picker untouched** — still `httpModels(for:)`, structurally.
3. **ADR 0003 scope amendment** (appended note, not a rewrite): "never in the
   macOS app" narrows to "never in any dictation-polish surface"; the Models
   tab summary pin is allowed because the app's summary path is the TS
   pipeline itself.
4. Zombie check already treats these ids as valid (b624d20) — no change.

## Non-goals

No binary-presence probing from the app UI. No CLI-engine rows in API Keys.

## Execution

Bundled with plan 14 in one Claude Opus 5 workflow (implementer worktree →
2 reviewers → fixer). Gates: xcodegen + xcodebuild test.
