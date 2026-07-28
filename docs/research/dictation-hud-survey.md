# Dictation HUD survey (2026-07-27)

Research agent's field survey of live-dictation HUDs, gathered while designing
plan 10 (pill / bar / prompter styles). Flags: **[SRC]** exact, read from
source. **[DOC]** vendor docs or changelog. **[REV]** secondhand review/forum.
**[INF]** inference. VoiceInk references are `github.com/Beingpax/VoiceInk`
@ `ec61032`.

## Headline findings

**1. Nobody ships the volatile-vs-finalized distinction.** VoiceInk (the only
open-source product with a live draft) renders one flat
`@Published var partialTranscript: String` as a single `Text` in one color,
`.white.opacity(0.8)` (`RecorderComponents.swift:311`); its `.finalized` case
is end-of-session only (`TranscriptionSession.swift:128`). superwhisper is
undocumented on this point; Wispr Flow shows no text by policy. The prompter's
dimmed-tail styling is novel in this category — no prior art to copy values
from, so the dim ratio needs a real tuning pass.

**2. The market leader deliberately shows no live text.** Wispr Flow's support
article "Why Flow doesn't show words while you're speaking" argues live text
"favors speed over accuracy"; no setting enables it **[DOC]**. Raycast,
Willow, MacWhisper, Apple: no live text either. Validation for keeping the
pill (no big text surface) as default.

## Slim bar notes

- **Placement is the #1 documented complaint.** Wispr's bottom-center lock
  spawned a third-party mover (PillFloat); Wispr shipped left/right edge
  docking in June 2026 as the fix **[DOC]**. MacWhisper's model is the
  cleanest: a four-way position enum *center top / center bottom / textfield
  location / hidden* (v13.14 notes) **[DOC]** — "hidden" as a first-class
  option matters.
- Only size figure anywhere for Wispr: PillFloat's reverse-engineered
  "~440×300px transparent window, visible pill ~70px" **[REV — estimate, not
  spec]**. Flow resets pill position every ~400ms (PillFloat fights it).
- **Oversized-transparent-host pattern:** Wispr (~440×300 host) and VoiceInk
  (540×430 host for a 184pt pill, `MiniRecorderPanel.swift:34-56`) allocate a
  big fixed transparent window and pin content to an edge — window never
  resizes, SwiftUI is the sole animation authority. Mirror image of our
  choice (NSAnimationContext owns the frame). Both reach one-authority; never
  end up with both.

## Teleprompter card — VoiceInk exact values [SRC]

Container morphs instead of stretching (`MiniRecorderView.swift:14-19,96-104`):

| state | width | corner radius | height |
|---|---|---|---|
| idle / recording | 184 | 20 (stadium) | 40 |
| live transcript | 300 | 14 | 96 |
| assistant response | 520 | 14 | 360 |

Radius *shrinks* as it grows — pill geometry and readable text treated as
incompatible.

Transcript view (`RecorderComponents.swift:305-337`):

```swift
ScrollViewReader { proxy in
    ScrollView(.vertical, showsIndicators: false) {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 6)
            .id("bottom")
    }
    .frame(height: 56)
    .mask(LinearGradient(stops: [
        .init(color: .clear,  location: 0.0),
        .init(color: .black,  location: 0.18),
        .init(color: .black,  location: 1.0),
    ], startPoint: .top, endPoint: .bottom))
    .onChange(of: text) { proxy.scrollTo("bottom", anchor: .bottom) }
}
.transaction { $0.disablesAnimations = true }
```

Liftable values:
- Fixed 56pt viewport (~4.5 lines at 12pt) is the ONLY bound — no lineLimit,
  no truncation, no character cap anywhere.
- Top-only fade mask, clear→opaque at 0.18; newest text crisp at a hard
  bottom edge.
- Auto-scroll pinned to bottom on every change — newest words hold a fixed
  screen position (the actual fix for "text feels compacted").
- `.transaction { $0.disablesAnimations = true }` so per-token churn never
  animates (complements, does not replace, our draft-out-of-HUDState rule).
- 12pt at 80% white — draft subordinate to the control row.
- Dim-ratio advice: VoiceInk's whole draft is 0.8 opacity. If our finalized is
  1.0 the card shouts; prefer finalized ≈0.85–0.9, volatile ≈0.45–0.55.
- Gating: live transcript shows only while recording and non-empty; vanishes
  the moment recording stops.

Animation (`NotchRecorderView.swift:112-117,169`): expand
`.spring(response: 0.42, dampingFraction: 0.80)`, collapse
`(0.45, 1.00)`, content fades in on a **0.09s delay** so the container is
already wide before contents appear — the delayed fade-in is worth stealing.

Material: VoiceInk uses flat opaque `Color.black`, zero shadows; Raycast's
system likewise (surface ladder `#0d0d0d → #101111 → #121212`, 1px hairlines,
no drop shadows) **[REV]**. At teleprompter size a large translucent panel
over arbitrary content invites legibility complaints — consider a more opaque
fill for the card than the pill.

Meter (`AudioVisualizerView.swift:8-45`): 15 bars, 3pt wide, 2pt gap (73pt
total), height 4→28, r=1.5, `opacity(0.85)`, `TimelineView` at 60fps.

```swift
amplitude   = max(0, min(1, pow(audioMeter.averagePower, 0.7)))
wave        = sin(time * 8 + phases[index]) * 0.5 + 0.5   // phases[i] = i*0.4
centerBoost = 1.0 - (centerDistance * 0.4)
height      = max(4, 4 + amplitude * wave * centerBoost * 24)
```

RMS clamped −60…0 dB, EMA `0.6*prev + 0.4*new` (`Recorder.swift:271-312`).
Traveling sine = bars never still while recording (liveness cue independent of
input). Idle: identical geometry fixed at 4pt, `opacity(0.5)` — a flat dotted
rule. Cheap idle/active distinction.

## States and errors

- superwhisper: one status dot, mirrored in recorder + menu bar — yellow
  loading, red recording, blue processing, green complete **[DOC]**. Cleanest
  vocabulary in the survey; candidate for the bar.
- VoiceInk: six engine states collapsed to three visuals, cross-faded 0.2s;
  processing label deliberately sized to the meter it replaces
  (`// matches AudioVisualizer maxHeight to prevent layout shift`) — copy
  that. Dot chase: 5 dots, 3pt, 2pt gap, lit 0.85 vs 0.25, 2-tick pause.
- VoiceInk has NO error case in the overlay (issues #360/#361/#362: no timer,
  unclear phase, ESC undiscoverable). Wispr does it right: "Taking longer than
  usual" toast on overrun; "Microphone is not working" with a *Select
  microphone* action, fired from waveform silence detection **[DOC]** —
  detect failure from the signal you already have (we have RMS), put the fix
  in the error.

## Complaints to design against

1. "It's in my way" — the #1 complaint everywhere (PillFloat's existence;
   VoiceInk #225 asking for size options, never shipped). Keep "hidden"
   reachable.
2. Live text distracts some users (VoiceInk #802: revision churn pulls
   attention; toggle shipped, regressed in 2.0, restored). The volatile tail
   makes churn MORE visible — dim it deep enough that revisions don't pull
   the eye.
3. Overlay stealing focus corrupts delivery (VoiceInk PR #616: paste missed
   target while panel visible) — same hazard class as our
   `reviewKeyRestoreSettleNs`; the bigger, longer-lived card must stay
   non-key.
4. Unverified window presentation: VoiceInk never checks
   `orderFrontRegardless()`; open issue #813 is exactly our zombie-window
   bug, unfixed there. Both new styles must route through
   `HUDVisibilityMonitor` / `verifyWindowDevice`, not around.
5. HUD redesigns break muscle memory (macOS Tahoe volume-HUD backlash) —
   keeping the current pill as an option is correct.

## Corrections

The claim that macOS Tahoe dictation shows a "Liquid Glass overlay with
confidence levels" appears only on two AI-generated SEO blogs — treat as
fabricated. Apple's real indicator is a pulsing caret in the focused field,
no separate window, auto-stop after 30s silence **[DOC]**.

## Our own numbers, for reference

`HUDPillMetrics.draftWidth = 420`, `draftLineLimit = 2`, `.callout`,
`.truncationMode(.head)`, on top of `StreamingDelivery.roughDraftLimit = 120`.
The draft is clamped twice (120-char tail, then 2-line head truncation) — the
double clamp is mechanically the "compacted" feeling. VoiceInk clamps zero
times; a fixed viewport plus a gradient mask does the bounding. For the
prompter, neither clamp should survive; for the pill (kept as baseline), the
120-char limit deserves a future look.
