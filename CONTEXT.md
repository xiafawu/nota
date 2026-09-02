# Nota — Ubiquitous Language

Glossary of domain terms. Definitions only — no implementation details.

## Terms

**Task** — One of the two AI-powered stages a user can configure: *Transcription*
(audio → speaker-labeled text) or *Summary* (transcript → structured meeting notes).

**Model** — A specific AI model id (e.g. `universal`, `gpt-5-mini`). The unit the
user selects per Task. Every Model belongs to exactly one Provider. Ids are flat
(`gpt-5-mini`) or namespaced (`openrouter/anthropic/claude-sonnet-4.6`) — one
string fully names the model either way.

**Provider** — The service that serves a Model (AssemblyAI, OpenAI, Gemini,
DeepSeek, OpenRouter, Claude Code, Codex). Never chosen directly by the user;
always derived from the chosen Model — namespace prefix for namespaced ids,
the registry's lookup for legacy flat ids.
_Avoid_: vendor, backend

**Execution kind** — How a Model runs: `http` (OpenAI-compatible endpoint,
requires an API key) or `cli` (local subprocess, requires a binary on PATH and
a login). Surfaces filter on it — dictation polish is `http`-only.
_Avoid_: engine type

**CLI engine** — A `cli`-execution summarizer (`claude-code/*`, `codex/*`)
billed through a subscription rather than per token. Opt-in only; never joins
the default chain; reported as "included w/ subscription", never $0.
_Avoid_: local model (it is not local inference)

**Curated shortlist** — The hand-picked set of OpenRouter Models admitted to
the catalog, edited in code — as opposed to the weekly auto-admitted mainline
chat models. CLI engines are admitted the same way and marked separately, so a
reader can tell an HTTP shortlist entry from a subprocess at a glance.

**Model Registry** — The curated, closed list of Models Nota supports, mapping
each Model to its Provider, execution kind, endpoint, and required API key or
binary. Only registered Models are selectable (strict — no free-text model ids).

**Settings** — Non-secret, persistent user preferences (which Model per Task).
Distinct from Config. Precedence: per-run flags override Settings, which
override built-in defaults.

**Config** — The secret store: API keys only. Never holds preferences.

**Built-in default** — The Model used for a Task when neither a flag nor a
Setting specifies one; for Summary, chosen by the key-aware chain. CLI engines
are never a Built-in default.

## Dictation

**Delivery mode** — When dictated text becomes the user's problem: `immediate`
(once, on release), `streaming` (sentence by sentence while talking), `review`
(held in a card until Apply).
_Avoid_: insertion mode

**HUD style** — The shape of the dictation feedback panel: `pill`, `bar`, or
`prompter`. Independent of Delivery mode.

**Volatile tail** — The most recent recognized text, still subject to revision
by the recognizer; rendered dimmed. Finalized text is a delta that only appends.
_Avoid_: partial transcript

## Recording

**Live meeting** — A session that records the microphone and streams a
real-time transcript into the app window; stopping it persists the audio and
transcript as a meeting record. Distinct from importing an audio file, which
runs the offline pipeline.
_Avoid_: live dictation, dictation session (dictation injects text into other
apps)

**Preflight verdict** — The overall readiness outcome that gates recording:
`Ready`, `Blocked`, or `Unverified`. Ready and Unverified allow starting a
Live meeting; Blocked makes the record entry inert until the failing check is
fixed.
_Avoid_: status, health

**Record entry** — The single start point for a Live meeting: the "Ready to
record" hero on the home screen. The main window deliberately has no other
record button.
_Avoid_: record button (there is only one, and it is the hero)

## Reading

**Reading surface** — The one surface a transcript is read on, whether it is
still arriving from a Live meeting or has been sealed into a document. It is
one thing in two states, not two views: pressing Stop changes what the surface
holds, never how it reads.
_Avoid_: transcript view, document pane (each names only one of the two states)

**Name column** — The column holding a speaker's name, set apart from the words
they said. Names are right-aligned in it; the words are left-aligned on one
shared edge and never wrap beneath a name. Reserved on the Reading surface even
where no name is known, so no line moves when one arrives.

**Live name** — A speaker's name shown while the meeting is still running.
Best-effort: it appears only when the voice is a confident match for someone
already enrolled, and is absent otherwise rather than guessed.
_Avoid_: speaker label (that is what the Sealed label carries)

**Sealed label** — The speaker attribution written into the record when a Live
meeting is sealed, produced by diarizing the whole recording. Authoritative: it
may add or correct a Live name.
