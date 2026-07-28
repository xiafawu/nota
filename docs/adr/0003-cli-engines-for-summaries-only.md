# 0003 — Claude Code and Codex CLIs as summary engines, CLI path only

Date: 2026-07-27
Status: accepted

## Context

Nota is a personal tool whose owner holds Claude Code and Codex subscriptions;
long meeting summaries billed per-token are the main running cost. `claude -p`
and `codex exec` can produce the same summaries at zero marginal cost — but
they are local subprocesses with seconds of startup latency, not HTTP APIs.
The alternative reading of "Claude/Codex support" — those vendors' models over
HTTP via OpenRouter — is real but distinct, and is covered by the OpenRouter
provider (ADR 0002).

## Decision

`claude-code/*` and `codex/*` are registry entries with execution kind `cli`,
usable by the **CLI summary path only** (including its sectioned >100k-token
mode, which spawns once per section). They never appear in the macOS app:
dictation polish is latency-bound (per-sentence in streaming mode) and stays
`http` — enforced by the execution-kind filter, not convention.

CLI engines are **opt-in only**: they never join the key-aware summary default
chain. Their preconditions are a binary on PATH and an authenticated login,
not an API key; when unmet — or on timeout — the run fails hard with an error
naming the fix and how long it waited. There is no silent fallback to an HTTP
model: falling back would bill a provider the user did not configure. Cost
reporting shows "included w/ subscription" rather than a fake $0. `nota
config` reports binary presence alongside the API-key rows.

## Consequences

- "Free but slow" never wins a default; it is always an explicit choice.
- A subprocess engine in the summary path means the pipeline's failure modes
  now include process spawn/timeout, quoted-prompt hygiene, and CLI version
  drift — accepted for one bounded path, refused for dictation.
- If a future CLI ships a low-latency server mode, revisiting the polish-path
  exclusion means reopening this ADR.
