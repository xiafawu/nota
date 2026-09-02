# The voiceprint helper protocol (ADR 0008)

The macOS app has no ML runtime. Live speaker naming therefore runs in a Node
child process that loads the 27 MB WeSpeaker ONNX model **once** and answers
many requests over stdio for the length of a meeting.

This file is the **contract between the two halves** — `src/` (the helper) and
`macos/Nota/App/VoiceprintHelper.swift` (its owner). They were built in
parallel by separate agents, so this is the authority when they disagree.

## Spawn

`VoiceprintHelperProcess` tries, in order:

1. `$NOTA_VOICEPRINT_HELPER` — an absolute path to an executable, run as-is.
2. `node <projectDir>/dist/index.js voiceprint serve` — when `dist/index.js` exists.
3. `npx tsx <projectDir>/src/index.ts voiceprint serve`.

`projectDir` is `$NOTA_PROJECT_DIR`, defaulting to `/Users/xiafawu/Developer/Nota`
— the same resolution `EnrollQueue` already uses.

So the verb is **`voiceprint serve`**.

## Wire format

One JSON object per line, UTF-8, `\n`-terminated, in both directions. stdout is
the channel and carries nothing else; diagnostics go to stderr, which the Swift
side reads and logs and **never parses**.

**Readiness — one line, before anything else:**

```json
{"ready":true}
{"ready":false,"reason":"no enrolled voiceprints"}
```

`ready:false` makes the app terminate the helper immediately and draw no names
for the whole session. That is the intended cheap exit when `speakers.json` holds
nothing: send it rather than idling with the model loaded.

**Request** (at most one in flight at a time):

```json
{"id":1,"sampleRate":16000,"pcm":"<base64 of 16 kHz mono Int16 little-endian>"}
```

The slice is 1.0–12.0 s of a single finalized turn.

**Response** (echoes `id`):

```json
{"id":1,"name":"Kenny Kim","score":0.71}
{"id":1,"name":null}
{"id":1,"error":"insufficient_speech"}
```

The app treats a missing or null `name`, any `error`, and any `score` below
`MATCH_THRESHOLD` (0.65) as **no name** — the threshold is re-checked on the
Swift side, so sending a tentative-band score is harmless; it simply is not
drawn. A malformed request must be answered with an error, never crash the
process: a meeting may not lose naming because one turn was unreadable.

## Lifecycle

The helper **must exit on stdin EOF**. That is the only thing that stops it
leaking when the app is killed mid-meeting. The app also terminates it on Stop,
Discard, a mid-session failure, and deinit.

The per-request timeout is 10 s on the app's side. A timeout kills the helper and
the session finishes with no further names — degrading to no names is always
correct, and is why naming can never take a meeting down with it.
