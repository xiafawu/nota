# 0001 — Model-only settings; provider derived from a strict registry

Date: 2026-07-12
Status: accepted

## Context

Users need to choose which model runs transcription and which runs
summarization, and which API serves each. Three shapes were considered:

1. Store `{provider, model}` pairs per task, with a `custom` provider
   (arbitrary base URL + free-text model id) as an escape hatch for
   OpenRouter/Ollama-style endpoints.
2. Store `{provider, model}` pairs, known providers only.
3. Store only `model` per task; derive provider, endpoint, and required API
   key from a curated in-code Model Registry. No custom endpoints, no
   free-text model ids.

A free-text/custom design cannot be validated (any string is "valid"), and a
stored provider field admits invalid states (`provider: openai` +
`model: gemini-2.5-flash`) that need cross-validation everywhere the pair is
read (CLI, macOS Settings UI, share handler).

## Decision

Shape 3. `~/.nota/settings.json` stores one model id per task:

```json
{ "transcription": { "model": "universal" }, "summary": { "model": "gpt-5-mini" } }
```

The Model Registry is the single source of truth mapping model id → provider,
endpoint, required key. Model ids are strict: only registry entries are
settable (CLI `nota settings set` and macOS pickers both validate against it).
Provider is never stored and never chosen directly; `--provider` remains a
back-compat alias that resolves to a registry model.

Secrets stay separate in the dotenv-style `~/.nota/config`; settings.json is
non-secret and safe to sync.

## Consequences

- No invalid provider/model combos can exist on disk; a single `-m` flag fully
  specifies summarization.
- New models (and new providers) require a code release to appear — accepted
  cost of strictness; the registry is one constants module shared by CLI and
  macOS app.
- OpenRouter / local-model endpoints are out of scope; supporting them later
  means reopening this ADR (likely by adding registry entries or a new
  provider, not by adding free-text).
- Built-in summary default modernized to `gpt-5-mini` (was `gpt-4o`) — a
  deliberate behavior/cost change for flag-less runs.
