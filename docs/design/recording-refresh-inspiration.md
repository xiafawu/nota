# Recording experience refresh — design inspiration research

Asset for Linear ticket XIA-422 (closed 2026-08-05) (wayfinder map XIA-421, "recording experience
refresh"). Researched 2026-08-05 via five Mobbin sweeps (iOS + web): live
voice-capture screens, focus-session timers, background-processing states,
session-completion screens, meeting-notes web apps, and persistent minimized
recorders. Every screen cited links to its Mobbin page.

Two source families, deliberately different. **Capture apps** (Fabric, Granola,
Grain, Amie, ChatGPT, Notion, stoic., ABY Journal) answer "what does a live
transcription surface actually contain." **Session apps** (Opal, Brick, TIDE,
Breathwrk) answer "how does a timed session get a beginning, a middle and an
end that feel like an event." Nota is the first and wants to feel like the
second.

## Beat 1 — Entering

1. **A deliberate start gesture, not a state flip.** Opal's session sheet ends
   in a **"Hold to Start"** button
   ([Opal](https://mobbin.com/screens/0395a1d1-e5c4-4fa6-a969-3e02f90b2e7f)) —
   a press-and-hold, not a tap. What it buys: the session begins because you
   meant it, and the gesture itself is the ceremony. Nota's meeting card is one
   click and ⌘M is one keystroke; neither can grow a hold gesture without
   costing speed, but the *transition* after the click can carry the same
   weight.
2. **The pre-session sheet states the terms.** Opal shows duration, blocked
   apps, and a sound mix before starting; Character AI states the constraints
   ("Record a clip 3–15s long. Avoid background noise.")
   ([Character AI](https://mobbin.com/screens/35729bb9-2534-422b-bb12-fabb7e21dea7)).
   What it buys: everything decided at start time is visible at start time.
   Directly relevant — Nota's engine and diarization are start-time decisions
   (map decision 2) and are currently invisible.
3. **Presets before precision.** Opal offers `∞ / 15m / 30m / 1h` chips above a
   fine ruler slider
   ([Opal](https://mobbin.com/screens/649f9e92-3d9e-421f-8346-610bcbecd27d)).
   What it buys: the common case is one tap and the rare case is still
   reachable. A meeting has no set duration, so this is a pattern to *note and
   not adopt* — Nota's equivalent choice is meeting-vs-memo, already made by
   which entry point you used.

## Beat 2 — Recording

4. **The session gets an object, and the object is the timer.** Opal renders an
   LCD desk clock as a physical thing, centered, alone, on an immersive
   backdrop
   ([Opal](https://mobbin.com/screens/179136a8-0a93-4eee-a0b3-b6321b72c8bc)).
   What it buys: the running state is unmistakable from across a room, and the
   screen is *about* the session rather than about controls. The strongest
   structural takeaway in this sweep — and see the palette warning below,
   because Opal's execution of it is skeuomorphic and photographic.
5. **The transcript is the page; controls are a strip.** Fabric puts the
   transcript full-bleed and collapses language, mic, waveform, a red dot,
   `00:00:30` and Stop into one bottom capsule
   ([Fabric](https://mobbin.com/screens/325b348f-5710-41f7-a879-dd9e18c494b3)).
   Grain does the same on desktop: a thin top bar (red dot + "Recording", a red
   "Stop Recording" button) over a full-width transcript
   ([Grain](https://mobbin.com/screens/d2cca56d-fc5b-4127-997f-d5cd5aabf2b3)).
   What it buys: the thing being produced dominates; the chrome is one row and
   one lane. Confirms Nota's current instinct (header + transcript) while
   arguing the header should be thinner and denser than today's three-item
   spread.
6. **A live waveform is the "we are hearing you" signal — not the text.** ABY
   Journal, Character AI and Fabric all run a waveform beside the timer
   ([ABY Journal](https://mobbin.com/screens/d818141b-7c83-40e2-b1ad-28e86e9cbc36)).
   What it buys: silence still looks alive, and a dead microphone is visible
   immediately. Text alone cannot do this: a recognizer that has stopped
   producing looks identical to a speaker who paused.
7. **The volatile tail is styled, and it is where the eye rests.** ABY Journal
   bolds the last recognized words inside the dimmed partial line; Fabric
   dims the whole in-flight block. What it buys: a reading line that does not
   move — the newest text is always in the same place, so the eye is not
   chasing a scroll. Nota already dims the tail (`style: .tertiary`); the
   missing half is pinning where it appears.
8. **Speaker turns, not a wall of text.** Grain and Amie both break the
   transcript into per-speaker blocks with a colored initial and a timestamp
   ([Amie](https://mobbin.com/screens/c660e4c0-f122-428b-949d-8980d57b4527)).
   What it buys: a meeting transcript becomes skimmable while it is still being
   written. Note for scope: Nota's realtime speaker labels are a known
   unresolved follow-up, so the *layout* should leave room for a speaker column
   the pipeline may not fill yet.
9. **Markers exist and they live on the timeline.** stoic. draws tick marks
   along the waveform timeline during capture
   ([stoic.](https://mobbin.com/screens/25b9ae16-6b2c-4dd3-9c4b-ae7f7836b029)).
   What it buys: flagging a moment is spatial rather than a list entry, and the
   density of marks tells you where the meeting got interesting. The closest
   thing in this sweep to Nota's planned moment marker (map decision 5).
10. **One large, unmissable stop.** ABY Journal's full-width black pill,
    Character AI's full-width "Stop", stoic.'s big round button. What it buys:
    the one thing you will definitely do is the one thing you cannot miss.
    Grain's desktop equivalent is the only red-filled button on the screen.
11. **In-session settings do not take the screen away.** Opal's blocked-apps
    sheet slides over the running timer, which stays visible behind it
    ([Opal](https://mobbin.com/screens/24ea6194-b80c-4e36-8d53-80802f03c64d)).
    What it buys: nothing during a session ever hides the session.

## Beat 3 — Stopping

12. **Leaving early is a decision, and the app says so once.** Opal intercepts
    an early exit with "Leave Early? Don't give up, there's a reason you started
    this." / Done / Never Mind
    ([Opal](https://mobbin.com/screens/79907546-7636-46f8-be47-1e15ba99cbe4)).
    What it buys: a destructive-feeling action gets one beat of friction. For
    Nota the analog is **Discard**, not Stop — stopping is normal and must stay
    frictionless; discarding destroys audio the retention decision (map
    decision 7) exists to protect.
13. **Processing is a line of text, not a screen.** Grain footers the live
    transcript with "Processing transcript… last updated 10 secs ago". What it
    buys: the work is visibly ongoing without a modal, and a *staleness*
    figure ("last updated 10 secs ago") is more reassuring than a spinner
    because it proves the pipeline is still alive.
14. **Named stages beat an indeterminate bar.** Veriff/Monese lists the stages
    with checks and one spinner on the current one
    ([Monese](https://mobbin.com/screens/2c41541b-7189-4107-8b92-de7f6e2698d4));
    IKEA states an estimate up front ("Estimated processing time — 8 Minutes")
    with two named stages under it
    ([IKEA](https://mobbin.com/screens/6106d815-e660-402a-8503-73c907b3bf02)).
    What it buys: a multi-minute wait becomes legible, and the user can judge
    whether to wait or leave. Directly applicable — Nota's post-stop work is
    genuinely two stages (transcribe, summarize) and a CLI-engine summary is
    minutes long.
15. **Per-item status in a list is enough.** GoPro Quik and Dropbox both show a
    queue where each row carries its own state — Complete / a progress bar and
    "00:27 remaining" / Waiting
    ([GoPro Quik](https://mobbin.com/screens/d9d1710a-5585-42da-ae77-c4811a8ed7b0),
    [Dropbox](https://mobbin.com/screens/0344b16a-a8e5-442b-a8f9-efddae1ab159)).
    What it buys: the list you already have becomes the progress UI, with no
    new surface. This is the cheap, correct answer for Nota's ⌘L drawer.
16. **Anti-pattern, named.** GoPro Quik's banner reads "Stay on this screen with
    the app open to ensure your downloads complete." That is precisely the
    experience map decision 6 exists to eliminate — if the work needs the
    window open, the work is not really in the background.

## Beat 4 — Landing

17. **The finish is a small ceremony with real numbers.** Brick's "First tap
    complete. You reclaimed your time." over Mode / Apps blocked / Duration
    ([Brick](https://mobbin.com/screens/eb2562e9-5f2c-4e6a-87da-8ca18fdc29eb));
    Breathwrk's count plus streak
    ([Breathwrk](https://mobbin.com/screens/2d2dda84-d138-4fbe-a887-50ab50504879));
    TIDE's duration and tags under a quote
    ([TIDE](https://mobbin.com/screens/390d64f4-3b90-4189-9de0-9845e46442fa)).
    What it buys: the session ends as an accomplishment with a *shape* —
    two or three facts, one continue action. Nota's equivalent facts are
    duration, word count, speakers, and cost.
18. **One button out.** Every completion screen in the sweep ends in a single
    "Continue" / "Done". What it buys: no decision at the moment of relief.
19. **The artifact is the reward.** Amie's finished record leads with title,
    time range, an audio scrubber, share targets, then Private notes / Summary /
    Transcript tabs. What it buys: the celebration and the document can be the
    same screen — the "ceremony" is the record itself arriving well-formed,
    which suits Nota better than a separate congratulation card.

## Beat 5 — Out of the window

20. **Granola is the model.** Its Dynamic Island shows the app glyph, "Taking
    notes…", `1:39`, and two buttons — camera and **End**
    ([Granola](https://mobbin.com/screens/68a8fed7-ea39-426f-8353-f114d87780dd)).
    What it buys: identity, state, elapsed time, and the one destructive-ish
    action, in a strip the width of a sentence. This is the exact content list
    for Nota's floating mini-recorder and menu-bar item.
21. **Minimal is the norm, and the timer is the payload.** Brick shows glyph +
    `1h 14m`; Strava shows glyph + `0:06`; Grok shows glyph + a mic icon
    ([Brick](https://mobbin.com/screens/1c1526cf-ff13-411c-a366-64933cd8651e),
    [Strava](https://mobbin.com/screens/4d997324-6142-486d-aa73-05bd6948e52f)).
    What it buys: at a glance, "still running, this long." None of them show
    content — which is the evidence against putting a live transcript in the
    mini-recorder.
22. **Except when the waveform is the point.** Journal puts a live animated
    waveform in the island where the label would go
    ([Journal](https://mobbin.com/screens/71538161-0f89-4e20-a575-5276efcd7cc9)).
    What it buys: proof the mic is live, in the smallest possible space — the
    one piece of content that earns its place out of window.
23. **In-call clients keep the transcript in a side panel, not a floating
    window.** Dialpad docks "Transcripts / Notes" as a panel beside the call
    with a "Transcribing" chip on the video tile
    ([Dialpad](https://mobbin.com/screens/b9242e5f-643e-4b87-b753-a874882220d3)).
    What it buys: reading the transcript during a call is a *docked* activity,
    not a floating one. Worth weighing in XIA-424 — the argument for a floating
    transcript is weaker than it looks.

## Palette warnings — patterns that do not survive the translation

Craft Glass is closed (map decision 8). These are the specific things that make
the reference screens attractive and that must **not** be copied:

1. **Opal's photographic and gradient backdrops** — a full-bleed sunset or cave
   photograph behind the timer. Nota's ground is the Craft Glass wash. What
   translates is *immersion* (chrome recedes, one element dominates), not the
   imagery.
2. **Opal's skeuomorphic LCD device** — a rendered plastic clock with segment
   digits and a bezel. What translates is the timer's *scale and centrality*,
   in SF with monospaced digits.
3. **Celebratory illustration and mascots** — (Not Boring) Vibes' animated
   spirit, Breathwrk's bloom ring. Nota's finish is a document, and the app's
   register is quiet.
4. **Saturated per-mode color fields** — Opal's mode-colored gradients. Nota
   gets **one** contained accent, confined to recording surfaces, and it does
   not vary by kind: meeting and memo differ by label alone (map decision 2).
5. **Streaks and gamification** — Breathwrk's streak counter. Nota's numbers
   are duration, words, speakers, cost; nothing about consecutive days.

## Do / don't for the recording surfaces

**Do**

1. Make the timer big, centered-ish, monospaced, and the single most legible
   thing on the surface.
2. Run a live level meter or waveform next to it, always, as proof the
   microphone is alive.
3. Give recording one contained expressive accent that appears in no other
   state — it *is* the "we are capturing" signal.
4. Keep the transcript full-bleed and the controls to one strip.
5. Pin the reading line: newest text in a fixed place, older text moving away
   from it, dimmed volatile tail.
6. Leave room in the transcript layout for a speaker column even before
   realtime labels exist.
7. Put markers on the timeline, not only in a list, and confirm each one
   visibly.
8. Make Stop the largest, most obvious control.
9. Name the post-stop stages ("Transcribing" → "Summarizing") and show
   freshness ("updated 10s ago") rather than an indeterminate bar.
10. Use the ⌘L drawer row as the progress UI — per-row state, no new surface.
11. Out of window, show identity + state + elapsed + End, and nothing else,
    except a waveform if space allows.
12. Let the finished record be the reward: it lands well-formed with duration,
    words, speakers, cost.

**Don't**

1. Don't ask the owner to stay on a screen for work to complete (GoPro Quik).
2. Don't put friction on Stop — put it on Discard, once, and never again.
3. Don't animate the transcript's scroll position and the panel's size with two
   different authorities; the recording surfaces sit next to a HUD where that
   already read as jitter.
4. Don't put a live transcript in the mini-recorder without deciding it beats a
   docked panel (Dialpad) — the minimized-recorder norm is timer-only.
5. Don't introduce photographic backdrops, skeuomorphic timer objects, mascots,
   streaks, or per-mode color fields.
6. Don't let the accent vary by meeting-vs-memo; the kind is a label, and it is
   relabelable after the fact.
7. Don't build a separate celebration screen that stands between the owner and
   the document.
