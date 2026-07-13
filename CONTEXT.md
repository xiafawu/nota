# Nota — Ubiquitous Language

Glossary of domain terms. Definitions only — no implementation details.

## Terms

**Task** — One of the two AI-powered stages a user can configure: *Transcription*
(audio → speaker-labeled text) or *Summary* (transcript → structured meeting notes).

**Model** — A specific AI model id (e.g. `slam-1`, `gpt-5-mini`). The unit the
user selects per Task. Every Model belongs to exactly one Provider.

**Provider** — The API service that hosts a Model (AssemblyAI, OpenAI, Gemini).
Never chosen directly by the user; always derived from the chosen Model.

**Model Registry** — The curated, closed list of Models Nota supports, mapping
each Model to its Provider, endpoint, and required API key. Only registered
Models are selectable (strict — no free-text model ids).

**Settings** — Non-secret, persistent user preferences (which Model per Task).
Distinct from Config. Precedence: per-run flags override Settings, which
override built-in defaults.

**Config** — The secret store: API keys only. Never holds preferences.

**Built-in default** — The Model used for a Task when neither a flag nor a
Setting specifies one: Transcription `universal`, Summary `gpt-5-mini`.
