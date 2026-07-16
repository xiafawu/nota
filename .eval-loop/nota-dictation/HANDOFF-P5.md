# PI/omp Handoff — Dictation Phase 5 (AssemblyAI realtime engine)

Self-contained. Assume no prior conversation. Repo: `/Users/xiafawu/Developer/Nota`.
Read `.eval-loop/nota-dictation/CODEX-SPEC.md` §5 "P5 — AssemblyAI realtime"
first — authoritative spec (types in §4: `SpeechStream` protocol,
`EngineChoice`). Branch off **master** (green at `5a92289` or later). One
reviewable PR. No other feature branches in flight.

## Context

P1–P4.5 merged: hold/toggle capture, Apple SpeechAnalyzer engine (Int16
negotiated input), hybrid injection, formatter + optional LLM polish, floating
HUD. `EngineChoice.assemblyAIRealtime` already exists in `DictationTypes.swift`
and the engine picker in `DictationSettingsView` — today it falls through to
Apple. This phase makes it real: `AssemblyAIRealtimeStream` behind the
`SpeechStream` seam. Apple stays default; AssemblyAI is opt-in cloud.

## Hard constraints

- Swift/macOS only, under `macos/Nota/**`. Never modify
  `src/pipeline/assemblyai.ts`, any `src/**`, TS tests, deploy/signing
  scripts, or the CLI settings JSON.
- API key ONLY via `ApiKeyStore.value(for: "ASSEMBLYAI_API_KEY")` — do not
  parse env/config yourself (locked; a P4 review fix removed exactly such a
  duplicate parser from PolishClient).
- Do not touch `AppleSpeechStream` behavior; shared controller/capture/
  injection paths change only where the engine factory selects a stream.
- Missing key, network loss, malformed messages, or WS close must fail
  VISIBLY (controller `.failed` → HUD error) and never inject stale text.

## Current provider contract (verified 2026-07-16 against AssemblyAI docs —
do not build against the deprecated v2 `api.assemblyai.com/v2/realtime/ws`)

- Connect: `wss://streaming.assemblyai.com/v3/ws?sample_rate=16000`
  (+ optional `speech_model`). Auth: `Authorization: <key>` header, NO
  `Bearer` prefix. `URLSessionWebSocketTask`.
- Send: binary frames of **mono 16-bit PCM**, ~50ms chunks (800 samples @
  16kHz). NOTE: `MicCapture` emits **Float32** — convert to Int16 the same
  way `AppleSpeechStream.convertBuffer` does (extract/share the helper rather
  than duplicating it, if clean).
- Receive JSON: `{"type":"Begin","id":...,"expires_at":...}`;
  `{"type":"Turn","transcript":"...","end_of_turn":Bool,
  "turn_is_formatted":Bool,...}` (map to `Hypothesis`, final when
  `end_of_turn`); `{"type":"Termination","audio_duration_seconds":...}`.
- Graceful end: send `{"type":"Terminate"}` JSON, then close. Always send it
  in `finish()`/`cancel()` — otherwise the session bills until provider
  timeout.
- Close codes 4xxx = auth/quota/protocol errors — surface the reason.

## Task (single `sequential` lane — one agent; stream, factory, and
controller error paths interlock. Do not split.)

1. `AssemblyAIRealtimeStream: SpeechStream` — one WebSocket per dictation
   session; `start()` fails fast (thrown error) when the key is missing or
   the socket cannot open; accumulate `Turn` transcripts; `finish()` sends
   Terminate, waits (bounded — reuse the 5s-watchdog pattern from
   `AppleSpeechStream.finish()`) for the final formatted turn, returns final
   text; `cancel()` terminates + closes without injecting.
2. Engine factory in `DictationController`: `settings.engine` selects the
   stream per session (evaluate at session start, not at init, so a settings
   change applies to the next hold).
3. HUD/status: distinct "AssemblyAI" processing label is NOT required; the
   existing states suffice, but provider errors must reach the HUD error
   state with a human-readable message (e.g. "AssemblyAI: missing API key").
4. Do NOT add partial-text live typing (spec non-goal; final-on-release).

## Stop-fence

P5 ONLY. No diarization, no history records for dictation, no CLI `dictate`
command, no automatic Apple→cloud fallback (explicit opt-in only), no
notarization/distribution work (spec §6 is a later effort).

## Verify (non-negotiable; named tests are part of the fence)

- `npm run build:macos` prints `** BUILD SUCCEEDED **`.
- `cd macos && xcodebuild test … -destination 'platform=macOS'` green,
  including NEW `AssemblyAIStreamTests`: provider-message → `Hypothesis`
  mapping (Begin/Turn partial/Turn final/Termination/malformed JSON), close-
  code → error mapping, and missing-key fast-fail. Design the message decoder
  as a pure function so these need no network.
- Engine-factory test: `EngineChoice` → concrete stream type.
- `npm test` untouched/green; `git diff` shows no `src/**`.
- Cannot-verify-here: live WS session (needs key + mic + network) — the user
  validates: switch engine in settings, dictate, network-drop mid-session,
  missing-key case, then switch back to Apple.

## Dev-machine notes

- `ASSEMBLYAI_API_KEY` exists in `~/.nota/config` on the user's machine.
- Deploys signed "Nota Local Signing"; do not alter signing.

## Required reply

Reply using exactly these sections:

```
## Branch & commits        (branch name, one line per commit)
## Per-lane outcomes       (what each lane/fix delivered)
## Verification evidence   (commands run + REAL output, not summaries —
                            build:macos BUILD SUCCEEDED + xcodebuild test tail)
## Deviations from spec    (anything skipped, worked around, or changed — say so plainly)
## Cannot-verify-here      (what needs the user's machine — live WS matrix above)
## Orchestrator signals    (state changes, what this unblocks, suggested next dispatch —
                            written for a FRESH orchestrator session)
```
