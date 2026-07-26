# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Nota is a TypeScript CLI tool that transcribes and diarizes audio files using AssemblyAI (default) or OpenAI Whisper, then summarizes with an OpenAI or Gemini model (default `gpt-5-mini`). It outputs structured markdown with narrative summary, key topics, decisions, and action items.

Transcription and summary models are chosen from a curated **model registry** (`src/registry.ts`, the single source of truth). Each model id maps to a task, a provider, and the API key it requires — the provider is always derived from the model id, never stored or chosen directly.

## Naming

- Canonical product name: **Nota**
- Canonical CLI command: `nota`
- Canonical share handler: `scripts/nota-share.sh`
- Default share output folder: `~/Documents/Nota`
- Persistent speaker profiles: `~/.nota/speakers.json`
- Legacy `meetingsum` names are compatibility aliases only. Keep `scripts/meetingsum-share.sh`, the `meetingsum` bin alias, `MEETINGSUM_*` env fallbacks, and `~/.meetingsum/speakers.json` fallback unless intentionally doing a breaking cleanup.
- The repository path is `/Users/xiafawu/Developer/Nota`. Treat that as a filesystem location, not the product name.
- `docs/superpowers/` contains historical implementation plans/specs from the old name. Do not use those files as the source of truth for current branding.

## Build & Run Commands

- `npm run dev -- <audio-file>` — run Nota in development mode via tsx
- `npm start -- <audio-file>` — run compiled Nota after `npm run build`
- `npm run build` — compile TypeScript to `dist/`
- `npm test` — run all tests (vitest)
- `npm run test:watch` — run tests in watch mode
- `npx vitest run tests/pipeline/validate.test.ts` — run a single test file

## Architecture

Two pipeline paths controlled by `--provider`:

**AssemblyAI (default):** `Audio → Validate → Transcribe+Diarize (AssemblyAI) → Summarize (registry model) → Write`

**Whisper (fallback):** `Audio → Validate → Chunk → Transcribe (Whisper) + Diarize (pyannote) → Merge → Align → Summarize (registry model) → Write`

- **src/index.ts** — CLI entry point (commander). Parses args, calls orchestrator; hosts `nota settings`, `nota config`, and `nota models` verbs; runs background catalog freshness check on startup.
- **src/config.ts** — Resolves transcription + summary models (CLI > settings.json > key-aware default chain) via the registry, requires only the needed API keys, and derives the pipeline branch.
- **src/registry.ts** — Model registry: transcription models are statically curated; summary models are sourced dynamically from the catalog (`src/catalog.ts`).
- **src/catalog.ts** — Self-updating model catalog: fetches models.dev/api.json, filters through allowlist predicates, validates, and atomically caches to `~/.nota/models-catalog.json`. Baked snapshot fallback. Provides cost computation helpers.
- **src/cli/settings.ts** — `nota settings list|get|set|unset` verbs.
- **src/constants.ts** — Shared constants: `SEGMENT_DURATION`, `OVERLAP_DURATION`, `CHUNK_THRESHOLD_BYTES`.
- **src/orchestrator.ts** — Branches on `provider` to run AssemblyAI or Whisper pipeline.
- **src/pipeline/** — One module per pipeline stage:
  - `assemblyai.ts` — single API call for transcription + diarization, handles .qta conversion
  - `validate.ts` — checks file exists, format supported, ffmpeg installed
  - `chunk.ts` — splits audio >20MB into ~10min segments with 30s overlap (whisper only)
  - `transcribe.ts` — parallel Whisper API calls, exports `TranscriptSegment` interface (shared)
  - `merge.ts` — concatenates transcripts, deduplicates overlap regions (whisper only)
  - `summarize.ts` — sends transcript to the resolved summary model (OpenAI or Gemini via the OpenAI-compatible endpoint); for >100k tokens, does section-by-section then roll-up
  - `diarize.ts` — calls Python pyannote script, aligns speaker labels (whisper only)
  - `embed.ts` — computes ONNX WeSpeaker d-vectors in Node and compares them by cosine similarity
  - `speakers.ts` — loads the persistent v4 voiceprint store and matches diarized labels to enrolled speakers
  - `write.ts` — generates markdown output file; header carries **Captured** (recording time from container metadata, fs-birthtime fallback) and **Transcribed** (processing time) dates
- **src/utils/** — Shared helpers: ffmpeg wrapper (`ffmpeg.ts`), PCM decoding/slicing (`pcm.ts`), ONNX model download/cache (`model.ts`), token estimation (`tokens.ts`), capture-date resolution (`capture-date.ts`).

## CLI Flags

- `--provider <name>` — back-compat alias that seeds the transcription model: `assemblyai` (default → `universal`) or `whisper` (→ `whisper-1`). Yields to an explicit `--transcribe-model` or a `transcription.model` setting.
- `--transcribe-model <id>` — transcription model id from the registry (overrides settings.json and `--provider`)
- `--num-speakers <n>` — expected speaker count (assemblyai only)
- `--no-diarize` — skip pyannote diarization for whisper-path transcription
- `--identify` — identify and remember recurring speakers by voice
- `-o, --output <path>` — output file path
- `-l, --language <lang>` — audio language hint
- `-m, --model <model>` — summary model id. Precedence: this flag > `settings.json` > key-aware default chain (`deepseek-v4-flash` > `gpt-5.4-mini` > `gemini-3.6-flash` based on available API keys).
- `--no-history` — do not save this transcript to `~/.nota/history` (also disables duplicate detection, which relies on the history store)
- `--force` — reprocess even if an identical audio file is already in history (overrides duplicate detection)

- `-v, --verbose` — show progress spinners

Duplicate detection is automatic whenever history is enabled (the default): an
identical file (same bytes) that was already transcribed reuses the prior
summary instead of re-running paid transcription. See Key Design Decisions.

### Model Management

- `nota models list` — print the effective summary catalog as tab-separated rows (id, provider, label, source, fetchedAt)
- `nota models refresh` — force a fetch from models.dev, showing added/removed ids vs the previous cache

## Speaker Management

Manage enrolled speaker voiceprints (`~/.nota/speakers.json`, with legacy
fallback to `~/.meetingsum/speakers.json`):

- `nota speakers list` — print one tab-separated row per voiceprint (name, voiceprint id, enrolledAt, source, embedding dimension) on stdout
- `nota speakers show <name>` — print profile JSON with each voiceprint's metadata and embedding dimension (not the full vector)
- `nota speakers rename <old> <new>` — rename a profile key
- `nota speakers delete <name>` — remove a profile
- `nota speakers merge <src> <dst>` — concatenate `<src>`'s voiceprints into `<dst>` (dedup by id), drop `<src>`
- `nota speakers reassign <vp-id> <new-name>` — move one voiceprint to another speaker profile
- `nota enroll <history-id> <speaker-label> <name>` — enroll a stored per-speaker history clip

Commands exit non-zero if a referenced profile is missing. Confirmation lines
are written to stderr so stdout stays scriptable.

## Custom Dictionary

Shared custom-vocabulary store at `~/.nota/dictionary.json` (schema v1), read
and written by both the CLI and the macOS dictation app:

```json
{ "version": 1,
  "terms": [ { "term": "genc2rust", "spokenForms": ["gency to rust"],
               "source": "manual", "starred": false, "addedAt": "<ISO>" } ] }
```

- `nota dictionary list` — one tab-separated row per term (term, spoken forms, source, starred, addedAt) on stdout; header on stderr
- `nota dictionary add <term> [--spoken <form>]... [--star]` — add, or merge into the existing case-insensitive match
- `nota dictionary remove <term>` — case-insensitive; exits non-zero when the term is absent

`term` is unique case-insensitively; re-adding merges spoken forms, keeps the
original `addedAt`, and leaves `starred` sticky once set. `starred` terms win
the cut when the term list is later capped for context hints. Set
`NOTA_DICTIONARY_FILE` to point both the CLI and the app at a different path
(the test suites pass an explicit path instead, so they never read it).

TypeScript: `src/utils/dictionary.ts` (store) + `src/cli/dictionary.ts` (verbs).
Swift: `macos/Nota/Dictation/DictionaryStore.swift`. The two must stay in
lockstep on field names, `version`, and the uniqueness rule.

### How dictation uses the dictionary

**L1 — recognizer bias.** At the start of every dictation session the app takes
a `ContextSnapshot` (frontmost app, bundle id, focused window title via
Accessibility) and harvests identifier-shaped tokens from the title
(`genc2rust`, `package.json`, `--no-history`). Dictionary terms plus those
tokens become `AnalysisContext.contextualStrings[.general]`, attached with
`setContext` *before* the analyzer starts. Apple caps the list at 100 short
(1–2 word) phrases: starred terms survive the cut first, then manual/learned
terms, then harvested ones. An empty dictionary and an untrusted-for-AX process
both make this a no-op — dictation behaves exactly as it did before.
The snapshot and the dictionary read are kicked off as a detached task the
instant the hotkey goes down and awaited only at analyzer setup: the AX call is
synchronous IPC into an app that may not answer, and the main actor must not be
holding the HUD and the microphone while it waits.
`macos/Nota/Dictation/ContextSnapshot.swift`.

**L2 — deterministic replacement.** After `Formatter.applyRules` and before
polish, every `spokenForms → term` pair is substituted, longest spoken form
first. The word boundary is `(?<![A-Za-z0-9]) … (?![A-Za-z0-9])`, not `\b`:
punctuation counts as a boundary, which is what lets "package json" become
`package.json` and what stops a rule for "rust" from firing inside `genc2rust`.
Substitution is a **single left-to-right pass that consumes the input**, never a
fold of each rule over the previous rule's output: with `package.json` ("package
json") and `JSON` ("json") both in the dictionary, a fold turns "package json"
into `package.JSON` — a spelling neither entry asks for. Offline and
unconditional — this is the only spelling fix available when polish is off or
fails. `macos/Nota/Dictation/WordReplacements.swift`.

**L3 — polish prompt.** `PolishClient.systemPrompt` adds a VOCABULARY block
(dictionary terms + harvested identifiers, presented as the spelling authority)
and a CONTEXT block (app name + window title). The guardrails are load-bearing,
not decoration: the context is labelled source material rather than
instructions, the model is told it is transcribing and must never answer a
question or carry out a command that appears in the text, and it must return
only the final text with no tags or fences. Without them, dictating "what's the
fastest sort?" gets an *answer* typed at the cursor. The app name and window
title are written by another app, so they are flattened to a single line and
clamped to 200 characters before interpolation — a title full of newlines would
otherwise forge a prompt section of its own. The Dictation settings footer
states exactly what leaves the machine when polish is on: formatted text,
dictionary terms, app name, window title.

**Auto-learn.** After a successful polish, `AutoLearn.candidates` diffs the
pre-polish text against the polished text and stores runs that collapsed into a
single identifier-shaped token (`gency to rust` → `genc2rust`) as
`source: "learned"` entries. Deliberately narrow — grammar, punctuation, filler
removal, ordinary word swaps, insertions, and identifier-to-identifier rewrites
are all refused, because every stored term biases future recognition. A learned
term clears a higher bar than an L1 harvest (`AutoLearn.isLearnable`): a digit,
interior case-mix, or an alphanumeric run of 2+ characters around the
punctuation, and its letters-only folding must not be a common English word —
otherwise one polish call's "email" → "e-mail" becomes permanent. At most three
terms are learned per session.

The Dictation tab of the Settings window (Cmd+,) lists, adds, removes, and stars
terms against the same file the `nota dictionary` verbs use.

## Dictation Delivery

Two ways the recognized text reaches the app being dictated into, chosen by the
**Streaming Delivery** toggle (`DictationSettings.streamingDelivery`, default
**OFF**).

**Batch (default).** Everything is inserted once, on release: recognize →
`Formatter.applyRules` → `WordReplacements` → polish → one `TextInjector.inject`
into the target captured at that moment. Unchanged by the streaming work.

**Streaming (opt-in).** Sentences are typed in while the user is still talking:

```
mic → DictationTranscriber → volatile tail ───────────→ HUD rough-draft line
        └─ finalized delta → SentenceSegmenter → refine → ordered append
                                                (per sentence, concurrent)
```

- **Finality mid-session.** `AppleSpeechStream(streaming: true)` builds the
  analyzer with the `volatileRangeChangedHandler` initializer and reads each
  result's own `isFinal` instead of the teardown-time `didFinalize` flag.
  Finalized results are **deltas to append**; volatile results **replace** the
  tail — swapping those duplicates text into the user's document. Segments
  reach the controller as `Hypothesis(isSegment: true)`; every other producer
  keeps the original two-field contract, so `isSegment` defaults to false.
- **Apple engine only.** AssemblyAI realtime reports whole formatted turns
  rather than deltas, so it ignores the request and
  `SpeechStream.deliversSegments` stays false. A session that falls back to
  `SFSpeechRecognizer` also reverts to batch delivery — which is why
  `deliversSegments` is only meaningful *after* `start()` returns.
- **Sentences, not chunks.** `SentenceSegmenter` accumulates finalized deltas
  and releases only complete sentences (terminator + whitespace or end of
  finalized text; abbreviations and initials guarded). Whatever never reaches a
  boundary is released once, at stop, through the same pipeline. A 240-char
  overflow valve cuts at the last word boundary so a speaker who never lands a
  period is not silently held.
- **A fragment is not a sentence.** Each release carries how it was cut
  (`StreamingDelivery.Segment.startsSentence` / `.endsSentence`). The valve's
  mid-sentence chunk gets neither a terminal period nor a capital on the chunk
  that continues it, and it never reaches polish — polish is a sentence-level
  rewriter and hands back a sentence, capital and full stop included, for text
  that is already promised to a live document. Fragments still get the offline
  dictionary pass. The tail flushed at stop *does* end a sentence, so it is
  punctuated exactly as batch delivery would have punctuated it.
- **In order, always.** Refinement (rules → dictionary → polish) runs
  concurrently per sentence, so sentence 2's network call routinely returns
  before sentence 1's. `OrderedDeliveryBuffer` holds completions until their
  predecessors land and a single pump task serializes the writes. Text is in a
  live document and cannot be reordered afterwards.
- **Append-only.** Delivered text is never rewritten. `StreamingDelivery.appendDelta`
  computes exactly what to add (one separating space, or none if the target
  already ends in whitespace). `TextInjector.inject(_:target:mode: .append)`
  changes only the AX strategy — it reads the field's value and writes it back
  with the delta on the end, and a failed *read* falls through to CGEvent with
  the same delta rather than writing the delta as the whole value.
- **Fixed target, in every strategy.** `FocusedTarget.capture()` moves to
  session **start** and records the target's **pid**. All three strategies
  honor it: AX writes the captured element, CGEvent typing is posted to that
  pid, and the synthetic Cmd-V is posted to that pid instead of the HID tap.
  Without the pid the last two follow whatever is frontmost at *delivery* time,
  so a sentence the user started in Slack would land in whatever they clicked
  while it was being polished — and every paste- and keyEvents-forced app in
  `defaultOverrideTable` (Chrome, Slack, VSCode, terminals) takes one of those
  two paths.
- **Secure fields are re-checked per write.** A streaming session writes many
  times against one captured target, so `TextInjector.inject` re-asks
  `FocusedTarget.isSecureInputNow()` every time instead of trusting the
  start-of-session snapshot: focus inside the target app can move into a
  password field between two sentences. It can only get stricter — an already
  secure target stays refused, and an unreadable element falls back to the
  captured answer. A target that is *already* secure at session start skips
  streaming for the whole session.
- **One paste at a time.** The paste strategy's clipboard save → Cmd-V →
  restore runs through a serializing actor (`PasteInjector`) and awaits its own
  restore. Batch delivery pasted once per session so the pairs could not
  overlap; streaming delivers back to back, and unserialized the second paste
  snapshots the clipboard while it still holds the first sentence's dictated
  text and then restores *that* as the user's clipboard.
- **Degradation.** A sentence whose polish fails is delivered as its own offline
  (rules + dictionary) text and the queue keeps moving; the warning surfaces
  through the normal HUD path. With polish disabled the pipeline is still
  streaming, just rules + dictionary. Auto-learn gets a per-*session* budget
  (`AutoLearn.maxCandidatesPerSession`) because streaming polishes once per
  sentence rather than once per session.
- **A finished session stops talking.** Polish outlives the session that started
  it, and every piece of state it writes — the in-flight polish count, the
  last-result diagnostics, the auto-learn budget — belongs to the controller,
  not the session. So teardown bumps a session epoch and cancels the delivery
  queue: a stale refinement is dropped rather than surfacing session A's polish
  failure on session B's HUD, and it can never deliver into a target that is
  no longer the one the user is looking at.
- **HUD.** `ListeningView` gains a rough-draft line above the RMS bars showing
  the last ~60 characters of the volatile tail. It is deliberately not part of
  `HUDState`: the auto-hide bookkeeping compares states for equality, and a
  line that changes on every syllable would make every comparison miss.

`macos/Nota/Dictation/StreamingDelivery.swift` holds the pure core
(`SentenceSegmenter`, `OrderedDeliveryBuffer`, `StreamingDeliveryQueue`,
delta/rough-draft/refine helpers) so the invariants are tested without a
recognizer, a network call, or an Accessibility target.

## Model Settings

Non-secret model preferences live in `~/.nota/settings.json` (schema exactly
`{ "transcription": { "model": "..." }, "summary": { "model": "..." } }`).
Secrets never go here — API keys stay in `~/.nota/config`. Precedence for each
model is **CLI flag > settings.json > key-aware default chain**.

Summary models are auto-admitted weekly from `models.dev/api.json` through an
allowlist (mainline chat models only: gpt-5.x, gemini flash/pro, deepseek v4+).
Transcription model ids remain statically curated.

- `nota models list` — print the effective summary catalog (id, provider, label, source) as tab-separated rows
- `nota models refresh` — force a fetch from models.dev, showing added/removed ids
- `nota settings list` — effective model + source (settings.json vs default); tab-separated rows on stdout, header on stderr
- `nota settings get <path>` — print the effective value for a dot-path (`transcription.model` or `summary.model`)
- `nota settings set <path> <value>` — validate against the registry and persist; invalid model exits non-zero listing valid ids
- `nota settings unset <path>` — remove the key, reverting to the default

The summary default is key-aware: `deepseek-v4-flash` if `DEEPSEEK_API_KEY` resolves → `gpt-5.4-mini` if `OPENAI_API_KEY` → `gemini-3.6-flash` if `GEMINI_API_KEY` → error listing the three options. If a configured summary model is absent from the catalog (retired), it warns once and falls back to the chain.

Transcription model ids (static):
- `universal`, `whisper-1`, `gpt-4o-transcribe`, `gpt-4o-mini-transcribe`

Summary model ids (auto-admitted; run `nota models list` for the current set):
- Example: `gpt-5-mini`, `gpt-5`, `gpt-5.1`, `gpt-5.4-mini` (OpenAI); `gemini-2.5-flash`, `gemini-2.5-pro`, `gemini-3.6-flash` (Gemini); `deepseek-v4-flash`, `deepseek-v4-pro` (DeepSeek)

The macOS Settings window (Cmd+,) exposes the same pickers plus masked API-key
management; it mirrors the registry in `macos/Nota/App/ModelRegistry.swift`.

## Model Catalog (self-updating)

Summary model ids, labels, limits, and pricing are sourced from a local cache
(`~/.nota/models-catalog.json`) that is auto-refreshed from `models.dev` weekly
in the background. A baked snapshot ships in-repo as the fallback. To see the
current catalog: `nota models list`. To force a refresh: `nota models refresh`.
The cache feeds cost computation for usage tracking.

## Key Design Decisions

- Nota is the primary name; MeetingSum references exist only for backward compatibility.
- Model registry (`src/registry.ts`) is the single source of truth: model id → task, provider, required API key env, base URL. Transcription models are statically curated; summary models are sourced dynamically from the auto-refreshed catalog (`src/catalog.ts` + `~/.nota/models-catalog.json`) with a baked in-repo fallback. Only the API keys the resolved models actually need are required.
- Summary model ids are auto-admitted weekly: mainline chat models (gpt-5.x, gemini flash/pro, deepseek v4+) matching allowlist predicates. Run `nota models list` for the current set.
- Summary default is key-aware: `deepseek-v4-flash` > `gpt-5.4-mini` > `gemini-3.6-flash` based on which API key is set. A hint is printed when DeepSeek is skipped despite being the cheapest option.
- Pricing for summary models comes from the catalog via `computeSummaryCost` (tier-aware, ×1e-6 unit assertion). Pricing for transcription models remains a static table in `src/pricing.ts`.
- AssemblyAI as default provider: transcription + diarization in one API call ($0.15/hr)
- Whisper retained as fallback via `--provider whisper`
- `.qta` files auto-converted to `.m4a` via ffmpeg before AssemblyAI upload
- Speaker identity is a pure-Node ONNX d-vector pipeline: `onnxruntime-node` runs the WeSpeaker ResNet34-LM model over JavaScript-computed Kaldi fbank features, and stored L2-normalized embeddings are matched by cosine similarity. It needs no Python, hosted API, or identity-specific API key. The pinned model is downloaded on first use, checksum-verified, and cached at `~/.nota/models/wespeaker_en_voxceleb_resnet34_LM.onnx`; if the model or native runtime cannot load, identity no-ops with a clear message while the rest of the pipeline continues.
- Voice audio is captured **during** the pipeline run (the source audio is often a temp file deleted afterward): a short per-speaker PCM clip is saved under `~/.nota/history/<id>.assets/<label>.pcm`, and naming a speaker later enrolls an ONNX embedding from that stored clip, so enrollment works without the original audio. Speaker store schema v4 holds numeric d-vector arrays under `~/.nota/speakers.json`; incompatible v3 Eagle voiceprints are dropped with a warning and must be re-enrolled.
- Optional `--identify` recognizes enrolled speakers automatically and prompts for unknown ones (interactive TTY); freshly-typed names are enrolled inline from the captured clip
- Long transcripts (>100k tokens) are summarized in sections then rolled up
- Output saved as markdown file next to input by default
- Byte-level (SHA-256) duplicate detection: when history is enabled (the default), Nota hashes the raw audio once in `runPipeline` and, if an identical file already has a *completed* history record whose output `.md` still exists, reuses that summary and skips transcription. `--force` overrides; a hash failure warns but still transcribes. This gates the common case (same file shared twice) cheaply before any paid call; it is a byte hash, not an acoustic fingerprint, so a re-encoded copy of the same recording is not detected. Legacy records (pre-feature) have no `contentHash` and never match. Example: `nota recording.m4a --force` reprocesses a file already in history.
- The custom dictionary (`~/.nota/dictionary.json`, schema v1) is one file with two writers — `src/utils/dictionary.ts` and `macos/Nota/Dictation/DictionaryStore.swift`. Both write atomically (temp file + rename) and both *read* a missing or corrupt file as an empty dictionary with a warning, never a hard failure: dictation must not be blocked by a bad dictionary. Decoding is tolerant per entry on both sides (one damaged entry costs only itself; unknown `source` degrades to `manual`, missing optionals default), so a hand-edited typo or a file written by a newer version still loads. Reading-as-empty is safe only for reads: before a *write*, a wholly unparseable file is copied to `dictionary.json.corrupt-<epoch>` and the store starts over, because auto-learn calls `add` unattended and would otherwise replace every unreadable term with the one it just learned. In-process writers (Settings pane, auto-learn) are serialized by a lock in `DictionaryStore`; the CLI is a separate process and stays last-write-wins.
- `DictationSettings` decodes field by field (`init(from:)` in
  `DictationTypes.swift`), never through the synthesized `Decodable`. The
  synthesized one ignores property defaults and throws on a missing key, and
  `DictationSettingsStore.load()` turns any throw into factory defaults — so
  every new setting would silently wipe the user's engine, trigger, polish and
  HUD preferences on first launch after an upgrade. Tolerance is per field: a
  payload that is not a keyed container at all still resets, which is what
  should happen to a corrupt one. Add new settings with a default value **and**
  a line in `init(from:)`.
- Streaming dictation delivery is opt-in and default OFF, because it is the one
  part of the pipeline that cannot be undone: text appended to a live document
  while the user talks is already in their file. With the toggle off every path
  behaves exactly as it did before it existed — no target is captured at session
  start, no segment hypothesis is ever produced, and injection stays in
  `.standard` mode. With it on, the guarantees are append-only delivery, spoken
  order regardless of polish completion order, a target fixed at session start,
  and per-sentence fallback to offline text when polish fails. See Dictation
  Delivery.
- ESM-only project (`"type": "module"` in package.json)

## External Requirements

- `ffmpeg` and `ffprobe` must be installed and in PATH
- Node.js 18+
- Environment variable: `OPENAI_API_KEY` — required only when a resolved model is an OpenAI model (any `gpt-*`/`whisper-1` transcription or summary model). Not needed for, e.g., AssemblyAI transcription + Gemini summary.
- Environment variable: `ASSEMBLYAI_API_KEY` — required when the resolved transcription model is an AssemblyAI model (`universal`/`whisper-1`/`gpt-4o-transcribe`/`gpt-4o-mini-transcribe` — the default is `universal`)
- Environment variable: `GEMINI_API_KEY` — required when the resolved summary model is a Gemini model
- Environment variable: `DEEPSEEK_API_KEY` — required when the resolved summary model is a DeepSeek model (`deepseek-v4-flash`/`deepseek-v4-pro`). Note: `deepseek-v4-flash` is the cheapest default and is selected first when `DEEPSEEK_API_KEY` is set.
- Speaker identity (`--identify` and `nota enroll`) needs no API key or Python. It uses `onnxruntime-node` and auto-downloads its checksum-pinned ONNX model on first use.
- For `--provider whisper` with diarization only: Python 3.8+ with `pyannote.audio`, plus `HUGGINGFACE_TOKEN` (pyannote is not used for speaker identity)

### API-key config file

Instead of exporting env vars, keys may be placed in `~/.nota/config` as a
dotenv-style file (`KEY=VALUE`, one per line; `chmod 600`). Every `KEY=VALUE`
line is loaded generically (no allowlist), so future providers like
`GEMINI_API_KEY` work with zero code change. Real environment variables always
override file values (the file only fills unset keys). Set `NOTA_ENV_FILE` to
point at a different path. Run `nota config` to see which keys resolve and from
where (values are masked; secrets are never printed).
