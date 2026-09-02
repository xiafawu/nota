# 0007 — One reading surface, from the first word to the last read

Date: 2026-09-02
Status: accepted
Amends: 0005 (global vs local chrome — the recording pane's chrome is unchanged;
what moves is the text under it)

## Context

The recording pane and the finished document were described everywhere in this
repo as one surface — "a run is the transcript arriving, and the pane becomes
the document without the window changing" (CLAUDE.md, The Ground). Measured on
2026-09-02 they were not:

| | live (recording) | finished (transcript) |
|---|---|---|
| body | `.system(size: 14)` | `NSFonts.readingBody` 18.5pt |
| measure | full window width | `Metrics.readingMeasure` = 34em ≈ 629pt, centred |
| gutter | 52pt (`RecordingPaneMetrics.gutterWidth`) | 48pt (`Metrics.gutterWidth`) |
| timestamps | drawn on every turn start | hover only |
| ground (light) | the moving field (`.recording`) | tinted paper (`.transcript`) |
| speaker names | never — `speaker: nil`, RecordingPane.swift:764 | drawn |

So Stop swapped one reading surface for a materially different one, in place,
and every one of those six rows changed at the same instant. The claim in the
docs was the design; the code was five accidents.

## Decision

The live transcript and the finished document are **one surface with two
states**. The live side adopts the document's reading column (34em, centred),
its 18.5pt body, its 48pt gutter, and its hover-only timestamps. In light mode
the recording page wears the same tinted paper the transcript wears — and the
**same** paper: `GroundPaper` is tinted from the *transcript* palette for both
roles, because two different tints either side of Stop is the visual event this
ADR exists to remove. Dark mode is unchanged: both keep the field.

Nothing may change at Stop except **content arriving**. A title appears because
none existed before a record was sealed. Speaker names appear or are corrected
because the seal runs the authoritative diarization. Neither moves the text.

## Considered options

**Keep the live pane at 14pt full width.** A live feed is scanned ("is it
hearing me?"), not read, and 14pt full width fits far more of a meeting on
screen. Rejected by the owner: the continuity is worth the density, and the
alternative required rewriting the design claim rather than the code.

**Converge timestamps the other way** — always-visible on both sides. Rejected:
the document's 48pt gutter is reserved for moment pips, and always-on
timestamps in a document being read are noise.

## Consequences

- The live gutter narrows 52 → 48pt and draws nothing at rest. It is still
  **reserved**, because the hover timestamp and the ember marker rules live in
  it and a row that stepped left at Stop is the defect this ADR removes.
- The live transcript reserves the speaker **name column** (ADR 0008) whether
  or not a name is known, for the same reason.
- In light mode the `recording` palette of the launch's `GroundFamily` goes
  undrawn. Home keeps its own field. That is a real loss of colour variety,
  accepted for continuity.
- The Liquid Glass capsules refract less in light mode, because flat paper has
  nothing moving behind it. Accepted; the ember meter still carries liveness.
- The measured lane rule (`three-lanes-for-text-on-colour`, eight apps,
  2026-08-15) now applies to the live pane too, and is what makes the light
  paper mandatory rather than merely tidy: a 629pt reading column **is**
  long-form text, and long-form text may not sit on a pale multi-hue field.
