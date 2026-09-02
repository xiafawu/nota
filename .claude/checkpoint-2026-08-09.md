# Checkpoint — 2026-08-09 01:13 PDT

Supersedes nothing in `checkpoint-2026-08-08.md` — that file still holds the
XIA-441 verification recipe verbatim. This one records the design pivot and the
state at compaction #5.

## Current focus: gradient direction (design, not code)

Owner asked to borrow Pillowtalk's gradient look for Nota's recording surface,
then rejected two attempts, then asked the right diagnostic question: *"reproduce
the gradience from pillowtalk so we know if its because technical difficulties or
we don't align regarding the gradience design?"*

**Answer: it was technique.** Verified by pixel sampling, not by argument.

| | Pillowtalk reference | My attempts |
|---|---|---|
| Saturation | 6–47%, mostly 20–35% | ~95–100% |
| Value | 36–75%, **no true black** | 0% ground, 100% cores |
| Model | mid-luminance **field** | additive **glow on black** |
| Dominant mass | `#665e4c` neutral taupe | saturated ember |

**How verified:** PIL, 48-point 8×6 grid over the screen interior of
`~/Library/Application Support/CleanShot/media/media_dM1IbNRNwr/CleanShot Safari2026-08-09 at 00.19.26@2x.png`
(754×1536), printing hex + HSV per sample. Swatches surfaced: `#aa765e` s44,
`#9fb780` s30, `#8cb17e` s28, `#767066` s17, `#665e4c` s25, `#5b6057` s09.

Glow-on-black can never land there because its midpoint is black. Theirs has no
black in it at all.

### Artifacts

- `https://claude.ai/code/artifact/f3669f09-913b-4eb0-a48e-1db7853ea8a3` —
  reproduction, three panels: reference / repro from sampled palette / failed
  attempt. Built by `scratchpad/repro-build.py` → `scratchpad/mesh-repro.html`.
- `https://claude.ai/code/artifact/f2a51676-9638-41ce-98a9-0b9260196382` —
  earlier mesh exploration in Nota's colours (ember-only; ember + Craft Glass
  indigo). Superseded on technique, still the source for the two *readings*.

### Awaiting owner

Read of the middle panel. Close → I built the wrong thing, palette is fine.
Still off → we genuinely differ, worth knowing before any Swift.

### The unresolved design risk, named

Reference is a full-bleed phone background with its content deliberately dimmed.
Nota's session column is 288pt beside a transcript that must stay readable, so
the field needs damping — and **damping is the thing most likely to kill exactly
what the owner liked about it.** No decision on this yet.

### If it ships

Change is the colour array, not the mechanism: `MeshGradient(width: 3, height: 3)`,
drift the interior 4 points, corners fixed. s25–s35, v40–v70, largest mass
near-neutral.

**Trap, load-bearing:** do NOT drive the drift from `MicLevelFeed` or a
`TimelineView`. That reproduces XIA-432's 45 Hz whole-window rebuild. Use a slow
`.repeatForever` on a phase value.

**Constraint that survives any of this:** ember (`#d1662a` / `#e8823a`) means the
microphone is open. Nothing else may draw with it. A gradient that spends ember
on decoration spends the signal.

## Settled by the owner, 2026-08-09 evening

Four review units were put up one at a time. Three are closed.

### 1. Palette set — ALL SIXTEEN SHIP

Owner: *"all palette works for me. tbh. lets keep all of them"*. No cull. One
palette is drawn per launch and held for the process — never re-rolled on a
phase change (the morph depends on continuity) and never mid-session. Exclude
the previous launch's id from the draw, and take a `RandomNumberGenerator` so
snapshots can pin one.

Ids: meadow, tide, dusk, ink, orchard, harbour, heath, frost, kiln, fern,
tidepool, vellum, nocturne, lichen, quarry, bloom.

### 2. Recording layout — THE BAR, transcript centred

Owner: *"lets use the bar. and the transcript can have both left and right
margins so it sits at the center."* This **reverses** the 288pt trailing column
described in CLAUDE.md § The Recording Surface (B2). Session chrome — dot,
timer, meter, kind, Mark, Stop — floats in one Liquid Glass bar along the bottom;
the transcript is a single centred measure (~620pt, about 72 characters at
15.5pt) with equal margins on both sides.

What this deletes: `RecordingPaneMetrics.columnWidth`, `foldWidth` (809), the
`.strip` fold form and `SessionStripView` entirely — the bar is identical at
every width, so there is nothing to fold. The ⌘L drawer overlap question dies
with the column.

Three things the bar now owes, none blocking:
- **Markers lost their sidebar.** Proposed: a hairline drawn into the transcript
  at the marked point, plus a count in the bar opening a popover. A timestamp
  beside the words it marks means more than one in a list.
- **The scrim is load-bearing.** Glass over a moving ground shimmers; the bar
  sits on a soft vertical fade so the colour under it is calm while the field
  keeps flowing elsewhere.
- **The timer dropped 58pt → ~22pt.** Still mono and tabular. "Legible across a
  room" is gone; if it is wanted back, bloom the bar into a taller card on
  hover — not a permanent column.

Artifact: `https://claude.ai/code/artifact/7dabe2f9-87b5-46d8-b0f5-bdcabf5dd491`
(A and B both live over the real field; `scratchpad/layout.html`).

### 3. Warming curve — ASYMPTOTIC

`warmth(t) = 1 - exp(-t / 540)`, t in seconds, 9-minute time constant. Warmth
rotates seed hues toward a 40° warm anchor (62% of full pull) and the base wash
toward it at a third that rate, plus a small saturation lift. Monotonic, a
function of elapsed time alone, never resets mid-session, and it never reaches
ember (22°/30°) — the ground getting warm may not be mistaken for the microphone
being open.

**The first prototype read as broken and the measurement is why it wasn't.**
Owner: *"dont feel like so much different to me visually. a bug?"* Measured mean
ΔE (Frost, light, 12×12 grid, CIE76):

```
  min   asym  lin  step |  A-L   A-S   L-S
    5   0.43 0.11 0.00  |   9.3  12.3   3.1
   10   0.67 0.22 0.00  |  13.3  18.8   6.3
   30   0.96 0.67 0.66  |   9.3   9.6   0.2
   45   0.99 1.00 0.66  |   0.2  10.4  10.6
   60   1.00 1.00 1.00  |   0.0   0.0   0.0
```

Three facts worth keeping:
- The curves are identical at minute 0 and identical again from minute 60. The
  whole decision lives in minutes 3–45, and the prototype was animating 0–90 —
  two thirds of it was three identical panes. **A comparison prototype must be
  bounded to the interval where the options actually differ.**
- Linear and stepped were never a real choice (ΔE 0.1–6.3, mostly under the 2.3
  JND). The choice was asymptotic or not.
- **Dark mode halves every delta** — 10.0 average against 20.8 in light, because
  the band is compressed down there and warming has less room. Not fixed; if
  warming reads weak in dark, the lever is a larger hue pull in that theme, not
  a different curve.

Artifact: `https://claude.ai/code/artifact/c4055e8b-ae34-4af1-9686-7dd5f023a0df`
(frozen 5/15/30 grid with per-tile ΔE; `scratchpad/warmcurve.html`,
measurement scripts `scratchpad/warmdelta.mjs` + `scratchpad/pair.mjs`).

### 4. Contrast constants — FLATTEN 40 / PUSH 90

Owner first said "both 90 looks good"; measuring that pick is what produced the
finding below, and they took the revised recommendation ("ok yours is better").

**Push does the readability work. Flatten is a tax.** Worst body contrast across
the entire flatten range, push held at 90, light, all sixteen grounds,
full-frame:

```
flat    worstBody   V-range   reads as
  0%       8.83      15.5pt   soft but thin
 40%       8.70       9.3pt   soft but thin      <- shipped
 82%       8.57       2.8pt   flat paint
 90%       8.54       1.5pt   flat paint
100%       8.51       0.0pt   flat paint
```

Contrast moves **0.32 across the whole slider** while luminance variation falls
from 15.5 points to zero. The mechanism: pushing the band to 90 already narrows
it to ~10 points of luminance, so flatten is squeezing something already
squeezed. An earlier note in this file and in the `soft-field` skill called
flatten "the whole trick" — that was wrong and both are corrected.

**Text hierarchy, fixed alphas over one fixed ink per theme** (`#1C1A16` light,
`#EEEAE2` dark). Minimum alpha each tier needs on every cell of every ground,
against what ships:

```
tier        target   needs light   needs dark   ships
Body         7.0:1       89%           78%       100%
Speaker      4.5:1       70%           57%        78%
Timestamp    3.0:1       54%           40%        56%   <- was 52%, failed
Rail         1.2:1       10%            7%        12%
```

Timestamp at 52% landed 2.81–2.94:1 on Tidepool and Meadow — under its bar in
both the old settings and the new. Raised to 56%.

One fixed ink clearing every ground is what kills the derived-text-palette idea:
MusicKit derives per artwork because Apple cannot constrain album art; a
generated ground is the opposite case, so the constraint goes in at generation
time. Control the ground or derive the ink, not both.

Still open: **hue collision**. Flattening fixes luminance, not hue — two tinted
speaker labels, or a label against a seed of the same family, still need a
minimum hue separation enforced separately. Not designed.

Artifact: `https://claude.ai/code/artifact/c8de3ee2-5c87-45cf-a8f0-d2a537cbd629`
(flatten 40 vs 90 side by side, live contrast + luminance-variation readouts;
`scratchpad/contrast.html`, measurement scripts `scratchpad/knobs.mjs`,
`knobs-full.mjs`, `sweep.mjs`).

### The ground is fully specified — next is Swift

All four decisions are closed. Nothing about the background is waiting on the
owner. What is NOT designed: hue collision between speaker labels (above), and
the marker affordance the bar owes (§2).

## Handoff to the implementation session

**Start here:** `~/.claude/plans/xia-442-field-engine.md` — plan 1 of 4, the pure
field engine. Opus 5, `isolation: "worktree"`, branch `xia-442-field-engine`.

### Code seams, verified by grep this session (not recalled)

- **`CraftWashBackground` has exactly two production call sites**:
  `UI/HomeDashboardView.swift:136` and `UI/LiveMeetingView.swift:179`. Every
  other hit (`RecordingPane.swift:989`, `RecordingAccent.swift:336/371/386/401/
  415/429/444`, `CraftGlass.swift:359+`) is a `#Preview`. The swap surface is
  two lines.
- **The column/fold lives in four places**: `RecordingPaneMetrics.columnWidth`
  (`UI/RecordingPane.swift:32`), `.transcriptMinWidth` (:45), `.foldWidth` (:57),
  and `RecordingPaneLayout.form(width:)` (:152). `SessionStripView` is
  `RecordingPane.swift:835`, used at `LiveMeetingView.swift:207` and its own
  preview at :1013.
- **`LiveMeetingView.swift:162–189`** is where the form is chosen and the pane
  built — the whole layout swap for plan 3.
- **One test file rewrites**: `UI/Tests/RecordingPaneTests.swift` is the only
  test touching `SessionStripView` / `foldWidth` / `RecordingPaneLayout`.
- File sizes: `RecordingPane.swift` 1046, `RecordingAccent.swift` 457,
  `LiveMeetingView.swift` 365, `CraftGlass.swift` 510, `ContentView.swift` 383.

### The remaining three plans, not yet written

2. The `FieldBackground` view + the two call-site swaps. One phase value, never
   an `RMS`/`TimelineView` driver (XIA-432's 45 Hz whole-window rebuild).
3. The bar rewrite: bottom glass bar, 620pt centred transcript; deletes
   `columnWidth`, `foldWidth`, `transcriptMinWidth`, `RecordingPaneLayout.form`,
   `SessionStripView`, and rewrites `RecordingPaneTests`.
4. Text tiers + ink tokens; then the two undesigned pieces (speaker hue
   collision, the marker affordance).

### Prototypes that are the spec

- Layout: `https://claude.ai/code/artifact/7dabe2f9-87b5-46d8-b0f5-bdcabf5dd491`
- Warming: `https://claude.ai/code/artifact/c4055e8b-ae34-4af1-9686-7dd5f023a0df`
- Contrast: `https://claude.ai/code/artifact/c8de3ee2-5c87-45cf-a8f0-d2a537cbd629`
- Sources + measurement scripts are **copied into the repo** at
  `.claude/design-2026-08-09/` (they were in a session temp dir that does not
  survive): `layout.html`, `warmcurve.html`, `contrast.html`, `gallery.html`,
  `knobs.mjs`, `knobs-full.mjs`, `sweep.mjs`, `pair.mjs`, `warmdelta.mjs`.
  **These are the reference implementation** — the JS `target()` and `step()` in
  `contrast.html` are what the Swift must reproduce, and the `.mjs` files are
  runnable (`node .claude/design-2026-08-09/sweep.mjs`) to re-derive any number
  in this checkpoint.

### Skill changes landed this session

`~/.claude/skills/soft-field/SKILL.md` — four corrections: hue rule is overlap
not count; don't reach for a shader (CPU table); flatten-and-push replaces the
plate; and push (not flatten) is the readability mechanism. Generator dry-run
passed.

### Owed to the skills, not yet written

Two corrections to `~/.claude/skills/soft-field/SKILL.md`, gated on the palette
pick and now unblocked: (a) the hue rule is about **overlap, not count** — the
Pillowtalk reference has terracotta *and* sage *and* taupe, so "2 families,
never 3" was wrong; (b) don't reach for a shader — the CPU path was measured at
115 µs/frame for 64×36 advection plus 1 µs for the CGImage, 0.35% of a 33 ms
frame.

## XIA-441 — unchanged, still parked

Branch `xia-441-transcript-ledger` in worktree
`.claude/worktrees/agent-a31d3744e39ca0b59`, rebased onto master `ec1026c`.
`931fc6b` (typography) + `ad90c98` (rail), 1533 insertions, 13 files.

Direction 2's 17 tests in `TranscriptLedgerTests.swift` have **never executed**.
Diff is exonerated of the test-host hang — clean master hangs identically.
See `checkpoint-2026-08-08.md` § "To finish this, on a quiet machine" for the
exact recipe; do not re-derive it.

Prime suspect still untested: `/Applications/Nota.app` running under the same
bundle id `com.xiafawu.nota` as the test host. Quitting it is the owner's call.

## Open, unchanged

- XIA-440 (2 semantic collisions), XIA-439 (VoiceOver silence) — both open,
  both block XIA-438.
- Unfiled: XCTest gate for the unguarded `CGEvent` session tap
  (`HotkeyMonitor.swift:56`); flaky `FocusedTargetTests` crash; 4 XIA-435
  follow-ups; 2 XIA-432 follow-ups.
- Owner decision: ⌘L drawer (380pt `.topTrailing` overlay) sits on the 288pt
  session column. Three options in CLAUDE.md.
- iOS companion: shape agreed, function subset not decided.

## Session hygiene

Compaction #5 (manual). Past the audit stop signal — next task domain should
start a fresh session. Compacted conclusions count as unverified until
re-checked.
