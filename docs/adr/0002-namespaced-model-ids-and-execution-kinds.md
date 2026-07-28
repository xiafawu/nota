# 0002 — Namespaced model ids; execution kind on every registry entry

Date: 2026-07-27
Status: accepted (extends 0001)

## Context

OpenRouter support and CLI-engine support (ADR 0003) both add models whose
provider cannot come from today's flat-id lookup table, and one of them is not
an HTTP API at all. ADR 0001 predicted this moment and prescribed the shape:
new registry entries / a new provider, never free-text. Three shapes were
considered: namespaced ids (provider as the id's first path segment), flat ids
with provider suffixes, and a separate `summary.engine` setting beside
`summary.model`.

## Decision

Provider stays derived from the model id, with the derivation generalized:
ids may be namespaced (`openrouter/anthropic/claude-sonnet-4.6`,
`claude-code/sonnet`, `codex/gpt-5.4-codex`) and the first path segment names
the provider; legacy flat ids (`gpt-5-mini`, `deepseek-v4-flash`) keep the
lookup-table derivation unchanged. One string still fully specifies a
summarizer; the CLI-flag > settings.json > default precedence chain is
untouched.

Every registry entry also carries an **execution kind** — `http` (OpenAI-
compatible endpoint, per-provider base URL and API key) or `cli` (local
subprocess, no key). Surfaces filter on the kind structurally: the dictation
polish picker shows `http` only, so a catalog refresh can never leak a
subprocess engine into a per-sentence streaming path.

OpenRouter's admitted models are a hand-curated shortlist (a personal tool
uses a handful; 300+ auto-admitted ids would drown the pickers), and Nota
stores no OpenRouter pricing — cost lines defer to OpenRouter's own dashboard.

## Consequences

- A `summary.engine` knob was rejected: two settings that must agree, a
  doubled Settings surface, and a broken single-value precedence chain.
- Namespaced ids appear in settings.json, `nota models list`, and the Swift
  catalog; both registries parse the prefix the same way.
- The `execution` flag is the load-bearing exclusion mechanism — string
  matching on id prefixes is explicitly not the mechanism.
