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

## Amendment — 2026-07-28: scope of "never in the macOS app"

Status: accepted. The Decision above is unchanged in substance; this narrows
one sentence that was written wider than its own rationale.

"They never appear in the macOS app" is replaced by **"they never appear in any
dictation-polish surface."** The rationale given was latency, and it is a claim
about polish: a per-sentence network call in a streaming session cannot wait
minutes for a subprocess. It is not a claim about the app as a whole.

The app's *summary* path is not an in-app HTTP call at all — it shells out to
the TS pipeline (`nota-app-run.sh`), which is the CLI path this ADR already
permits. So the Models tab's summary picker may offer the seven CLI engines and
persist one to the shared `~/.nota/settings.json`, exactly like any other pin;
the run that follows is the same subprocess the `nota` command would spawn.

What does not change:

- The polish picker stays `ModelRegistry.httpModels(for:)`, filtering on the
  execution kind and never on an id prefix. CLI engines are not `ModelEntry`
  values in the app at all, so there is no row for that filter to miss.
- CLI engines still never join the key-aware default chain, in either process.
- The app still probes no binaries and shows no CLI rows in API Keys: a
  subscription login is not an API key, and there is nothing for that tab to
  hold. A missing binary or a stale login fails at the summary step with the
  error the CLI path already raises.
