# The voiceprint helper protocol (ADR 0008)

The macOS app has no ML runtime. Live speaker naming therefore runs in a Node
child process that loads the 27 MB WeSpeaker ONNX model **once** and answers
many requests over stdio for the length of a meeting.

This file is the **contract between the two halves** — `src/cli/voiceprint-serve.ts`
(the helper) and `macos/Nota/App/VoiceprintHelper.swift` (its owner).

They were built in parallel by agents that could not talk to each other, and
they landed with **two incompatible protocols**. This file originally pinned the
Swift one. That was reversed at integration on 2026-09-02 and the shapes below
are the helper's: it carries a `protocol` version to bump, an explicit `ok`
discriminant rather than "an error key is present", and an `op` field that
leaves room for a second request type — all three of which the Swift draft
lacked. Nothing was deployed, so there was no compatibility to protect, and the
Swift side's wire logic is six pure statics, the cheapest surface in the feature
to move. The helper also serves a `reload` op, which the app does not use yet.

## Spawn

`VoiceprintHelperProcess` tries, in order:

1. `$NOTA_VOICEPRINT_HELPER` — an absolute path to an executable, run as-is.
2. `node <projectDir>/dist/index.js voiceprint-serve` — when `dist/index.js` exists.
3. `npx tsx <projectDir>/src/index.ts voiceprint-serve`.

`projectDir` is `$NOTA_PROJECT_DIR`, defaulting to `/Users/xiafawu/Developer/Nota`
— the same resolution `EnrollQueue` already uses.

So the verb is **`voiceprint-serve`** — one hyphenated command, not two words.

## Wire format

One JSON object per line, UTF-8, `\n`-terminated, in both directions. stdout is
the channel and carries nothing else; diagnostics go to stderr, which the Swift
side reads and logs and **never parses**.

**Readiness — one line, before anything else:**

```json
{"type":"ready","protocol":1,"ok":true,"speakers":2,"voiceprints":3}
{"type":"ready","protocol":1,"ok":false,"reason":"no enrolled voiceprints"}
```

Anything the app cannot parse as a `type:"ready"` line is treated as a decline:
a helper whose very first line is unreadable is not one to send a megabyte of
somebody's meeting to.

`ready:false` makes the app terminate the helper immediately and draw no names
for the whole session. That is the intended cheap exit when `speakers.json` holds
nothing: send it rather than idling with the model loaded.

**Request** (at most one in flight at a time):

```json
{"id":"7","op":"match","pcm":"<base64 of 16 kHz mono Int16 little-endian>"}
```

The id is a **string** and is echoed verbatim. The slice is 1.0–12.0 s of a
single finalized turn. The sample rate does not cross: 16 kHz mono is the only
thing the capture path produces and the helper asserts it on its own side, so a
field naming it would be a second place for one fact to be wrong.

**Response** (echoes `id`):

```json
{"id":"7","ok":true,"name":"Kenny Kim","score":0.71}
{"id":"7","ok":true,"name":null,"reason":"tentative"}
{"id":"7","ok":false,"reason":"unavailable"}
```

`ok:true` with a null `name` is the ordinary "nobody we know" answer, not an
error — `reason` distinguishes `insufficient-speech`, `tentative`, `no-match`
and `no-voiceprints`, and the app reads none of them. `ok:false` is a refusal.

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
