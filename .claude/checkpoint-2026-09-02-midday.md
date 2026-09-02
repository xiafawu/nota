# Checkpoint — 2026-09-02, midday (ground ↔ ink, paper transcript, merge)

Third checkpoint of the day. `checkpoint-2026-09-02.md` (05:08) is the
overnight polish run; `checkpoint-2026-09-02-morning.md` (07:58) is the
render gallery and the deploy. This one is 07:58 → 11:16: the owner's
gradient-vs-text critique, two score sheets, the paper-transcript change, and
the merge to master. Written 11:16 PDT.

## State right now (verified 11:16)

- **master = `f81af11`**, **pushed 11:24** at the owner's "push"
  (`523321f..f81af11 master -> master`; `origin/master == master`, 0 ahead,
  0 behind after `git fetch`). Was 38 ahead and unpushed from 11:12 to 11:24.
- **Checked out:** `ground/paper-transcript`, same commit as master. Working
  tree clean for tracked files (`git status --short` shows only the usual
  untracked `.claude/checkpoint-*.md`, `.claude/design-2026-08-09/`,
  `.claude/workflow-2026-08-10-field-background/`, `.trace/`,
  `hatch-pet-mochi/`).
- **How master moved:** `git merge-base --is-ancestor master
  ground/paper-transcript && git push . ground/paper-transcript:master` — a
  ref-only fast-forward chosen because the full test gate was running in the
  checked-out tree and a `git checkout master` would have rewritten files
  under the compiler. Owner's words at 11:12: "merge it". The polish branch
  `polish/overnight-2026-09-02` (37 commits) is an ancestor of master now and
  can be deleted; it was not.
- **Deployed:** `/Applications/Nota.app` is `f81af11` (polish + paper).
  `npm run deploy:macos` at 11:10: `** BUILD SUCCEEDED **`, `nota-app-smoke:
  ok`, `Signed with stable identity: "Nota Local Signing"`, `Deployed
  /Applications/Nota.app`. Binary mtime 11:10:39; the running Nota process
  started 11:10:45, so it is the new build.
- **Full gate on `f81af11`: PASSED** (11:10–11:18, `scratchpad/paper-gate.log`,
  both bundles, allowances 360/600). Dictation bundle: Executed 588 tests, 2
  skipped, 0 failures. UI bundle: Executed 687 tests, 0 failures (up from 640
  on the polish gate: the 7 paper tests plus the gallery-era additions). No
  restart line, `** TEST SUCCEEDED **`, EXIT 0. Zero `Test Case … failed`.
- **Targeted gate that preceded the merge** (11:0x, `scratchpad/paper-tests.log`):
  `GroundPaperTests` + `FieldBackgroundTests` + `GroundFamilyTests` +
  `ReadingColumnTests` = 61 tests, 0 failures, `** TEST SUCCEEDED **`, EXIT 0.
  The 7 new tests all passed.
- **Agents / background:** no agents running. Five critic agents ran and are
  idle (`ink-critic`, `map-retrofit`, `board-critic`, `surface-critic`, plus
  the morning's gallery critic). One background Bash: the full gate above.
  No cron, no Monitor, no loop.
- **18 worktrees** in `git worktree list` — all older codex/wf_ ones that
  predate this session; none of mine remain.

## What happened since 07:58

1. **Owner (07:58, screenshot of the transcribing screen):** "feels like the
   gradient and the text color should be better coordinated throughout the UI
   (including transcript)". Diagnosis: `GroundInk.light` `#1C1A16` is warm
   (HSL hue 40°, a hint of brown) over a cool violet/pink launch.
2. **Ink sheet** (four ink hues over the real gradient, one axis):
   https://claude.ai/code/artifact/9a885a71-05fd-41e9-a481-c9376ad1b6ab
   — never scored; superseded by 3. An independent critic found 14 defects in
   the first draft (a wrong hue number, a colour not in the gradient, HSL
   saturation called "chroma", `pt` vs `px`, a status-quo cue in A's tag,
   an unmeasured rail tier); all fixed before publish.
3. **Owner (08:25):** "thinking if we could use white/black for the text
   heavy page? and gradience only on the home page?" → **surface sheet**
   (A field as today · B plain white/black · C paper tinted from the launch
   · D reading plate over the field; light and dark per column; home fixed
   at the top): https://claude.ai/code/artifact/0cf960ea-4b7a-4b9c-a4c9-94ce9c970a99
   Critic found 9 defects, chiefly anchoring toward the owner's own idea
   ("as today", "your proposal", "why your instinct is right") — removed.
   The measured basis is memory `three-lanes-for-text-on-colour`
   (2026-08-15, eight apps): long text sits on one strong hue, or on a
   **dark** multi-hue field, or on neutral with colour at the edges — never
   on a pale multi-hue field.
4. **Owner (11:03): "i actually like C for light and A for dark."** Then
   "C it is" (11:11). Built as `ground/paper-transcript` off the polish
   branch, one commit `f81af11`:
   - `macos/Nota/UI/Field/GroundPaper.swift` — `wears(role:light:)` is
     `.transcript && light` only; `color(for:)` = transcript palette's
     `baseHue` at HSV saturation 0.024 / value 0.973 (the sheet's
     `hsl(h, 30%, 96%)`).
   - `FieldBackground` draws the paper in place of `FieldImageLayer` when
     `wearsPaper`; a paper surface adds **no viewer** and **never sets
     `engine.role`** (`reconcileViewer()`, `@State isViewing`), so the clock
     stops when only a light document is up and home morphs back from its
     own ground. Scheme flips move it both ways.
   - The transcribing screen wears paper too (same `.transcript` role).
   - Tests: `GroundPaperTests` (truth table; every tier clears its bar on all
     16 palettes at both contrast settings; hue tracks the base hue,
     saturation ≤ 0.03, value ≥ 0.97 so ember needs no Lab proof) and four
     hosted `FieldBackgroundTests` (light transcript = no clock, no frame,
     role untouched; dark transcript = field; scheme flip both ways; home
     both themes). Hosting is an offscreen borderless `NSWindow` +
     `RunLoop.run(until:)` — `onAppear` fires there and not in an unhosted
     `NSHostingView`.
   - CLAUDE.md "The Ground" gained the paragraph "The light transcript wears
     paper, not the field".
5. **Deployed 11:10, merged 11:12** (above).
6. **Session map** (board, republished after each step; the renderer gained a
   "N things need you" subtitle and a legend — patched in
   `~/.claude/skills/session-map/scripts/render.py`, backup beside it):
   https://claude.ai/code/artifact/0fcf2638-5406-4386-80ee-254771ab7ba6
   Zero `yours` nodes at 11:16; one `active` (the full gate).
7. **Skills touched:** `score-kit` (three rules: no thumb on the scale in tag
   rows/copy; animate a mock when motion is the axis; equal insets; and §6
   corrected — the ship-critic gate is a **90-minute window per path**, not
   per login; the next call passes), `git-workflow-traps` (ref-only
   fast-forward via `git push . <branch>:master`). Memory
   `project-overnight-polish-2026-09-02.md` updated to "merged, not pushed".

## Open / next action

- **Home-screen ink hue** — the ink sheet is now a home-only question and was
  never scored. Parked (`dormant` on the board).
- **~15 implementer follow-ups** from the overnight run — list under "Owner
  notes" in `checkpoint-2026-09-02.md`. Unchanged.
- **The polish gallery's Keep/Revert answers** were never given; the branch
  merged whole. A surface can still be reverted by its commit
  (`git log --oneline origin/master..master`).
- Optional cleanup: `git branch -d polish/overnight-2026-09-02
  ground/paper-transcript` after checking out master (both are ancestors of
  master now).

## Lessons (new since 07:58)

- A score sheet drifts toward the owner's own proposal without anyone
  intending it: "as today", "your proposal", a verdict label in one tag row,
  a subhead answering the question. Two sheets in one morning; a critic
  caught both before the owner saw them. Now in `score-kit`.
- When the axis is motion, a still mock scores the still. Animate it
  (`@keyframes`, off under `prefers-reduced-motion`).
- `ship-critic-gate.sh` stamps a path for 90 minutes; a republish after that
  blocks once and the retry passes. Do not re-run a critic for a one-card
  delta.
- `git push . <branch>:master` fast-forwards master without touching the
  working tree — the safe merge while a gate is compiling in it.
- Hosting a SwiftUI view in an offscreen borderless `NSWindow` and spinning
  the run loop for ~80 ms makes `onAppear` fire in a unit test; viewer
  refcounts and role pushes live there, so that is where they are testable.
