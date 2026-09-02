# 0008 — A speaker column, and live names only when they are known

Date: 2026-09-02
Status: accepted

## Context

`MarkdownRender.appendSpeakerLine` drew `**Name:**` inline, in the speaker's
identity hue, immediately before the words. So the text's left edge moved with
the length of the name — "Brian Demsky:" against "Freya Wu:" — and a wrapped
paragraph ran back underneath the name. The owner's words (2026-09-02, marked
on a screenshot): *"verbatim and names should separate out. words should left
align, names right align"*.

Separately, the live transcript has carried a speaker slot since XIA-445 that
has never been filled: `LiveTranscriptLine.speaker` is hardcoded `nil`. That is
not unfinished plumbing. The engine is AssemblyAI **streaming v3**
(`wss://streaming.assemblyai.com/v3/ws`), whose turn payload carries the
transcript text and an end-of-turn flag and **no speaker label at all**.

## Decision

**Two columns.** Speaker names are right-aligned in their own column; the words
are left-aligned on one shared edge and wrap to that edge, never under a name.
In TextKit: a right-aligned tab stop at the name column's trailing edge, a left
tab stop and a matching `headIndent` at the text edge. The outer 48pt gutter is
untouched and still belongs to the hover timestamps and the marker rules.

**The column is measured, not typed** — one pass over the document's speaker
lines finds the longest name — and clamped to a maximum. A name over the cap is
**abbreviated, never truncated**: full name → `Brian D.` → `B.D.` → ellipsis
only when a single word is absurd. The full name is always available on hover.
Measuring follows the precedent of `RecordingPaneMetrics.capsuleHeight`: derive
the number from the tallest/longest thing it must hold, never type a literal.

**Live names are built** (owner, over parking them), and they are best-effort:

- A single **long-running helper process** is started with the session. It
  loads the 27 MB WeSpeaker ONNX model once, takes a finalized turn's PCM on
  stdin, and returns the best match against the enrolled voiceprints. Rejected:
  a fresh process per turn — the existing spawn-per-operation pattern
  (`EnrollQueue`) would reload 27 MB every few seconds, trailing the
  conversation and burning CPU for the length of the meeting.
- A name is drawn **only for a confident match** (≥ 0.65 cosine, the existing
  `MATCH_THRESHOLD`). Nothing on screen may be a guess, so there is no live
  "Speaker 1 / Speaker 2" clustering of unmatched voices, and a tentative-band
  match shows nothing live.
- The **seal is authoritative.** It re-runs diarization and identification over
  the whole audio, so a live name may be added or corrected at Stop. That is
  content arriving, which ADR 0007 permits; it may not move the text, which is
  why the live transcript reserves the name column even while it is empty.

## Consequences

- In a meeting where nobody is enrolled, the live name column stays empty for
  the whole session and the finished document gets its labels at Stop. Accepted
  as the price of never guessing on screen.
- Turns too short to embed (`InsufficientSpeechError`) stay blank live.
- The helper is a child process the app now owns: start, health, kill on Stop,
  and no leak if the app quits mid-meeting.
