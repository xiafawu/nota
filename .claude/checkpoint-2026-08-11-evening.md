# Checkpoint — 2026-08-11 evening (XIA-445 shipped)

## Where things stand, verified

- `master` = **`316e64d`**, pushed to `origin/master` (verified: `git log --oneline -1 origin/master`).
- `/Applications/Nota.app` built from that commit and **running** (pid checked after `open -a Nota`).
- Signed with the stable identity "Nota Local Signing", so the Accessibility grant survives redeploys.
- Working tree clean apart from the usual untracked `.claude/checkpoint-*`, `.claude/design-*`,
  `.trace/`, `hatch-pet-mochi/`.
- Test state, **observed not assumed**: `NotaUITests/RecordingPaneTests` +
  `LiveMeetingViewTests` = **71 tests, 0 failures**. The full-branch run earlier in the
  evening (adding `RecordingAccentTests`, `FieldEngineTests`, `FieldBackgroundTests`) was
  **120 tests, 0 failures**; the field suites were not re-run after the badge fix because
  it touches neither the field engine nor its background.

## What shipped: XIA-445, the capsule cluster

The full-width session bar (XIA-444) is **deleted**. The live recording surface is now
three sibling Liquid Glass capsules floating over a full-width transcript:

**⏱ Timer** (clear glass: compact level meter + 30pt mono clock) · **🔖 Mark** (blue) ·
**⏹ Stop** (red)

Four commits, all on `master` now:

| sha | what |
|---|---|
| `af48437` | the cluster replaces the bar |
| `cef08e1` | the reserve the transcript never got + the Mark button nobody could press |
| `d682483` | back to three capsules; the tally moves onto Mark |
| `316e64d` | the tally becomes a badge, so Mark stops drawing twice Stop |

### Decisions the owner made tonight

1. **Three capsules, not four.** A Moments capsule (opening the marker list) was built and
   rejected: you are recording, not browsing. Hanging the list off a long-press of Mark was
   rejected too — it hides an affordance nothing on screen names. **Reviewing moments while
   recording is deliberately impossible**; that is XIA-433's job.
2. **The tally stays on Mark.** With no list to open, a Mark that did not visibly count
   would be a button with no observable effect.
3. **C·Essential timer**: no ember dot, no kind line. Meter and clock only.
4. **Red Stop**, chosen with the ΔE measurement in hand (systemRed→ember is 38.5 dark /
   33.1 light). C·Essential removing the ember dot independently defused the collision.
5. **Reserve space**: the transcript keeps the cluster's whole footprint clear at the bottom.

## The four defects worth remembering

An implementation agent built the cluster and reported **116 tests, 0 failures**. An
independent review of the same diff confirmed **eight real defects**. Every one shipped
under a green suite.

1. **BLOCKER — the bottom reserve bought nothing.** It was scroll *content* padding on the
   `LazyVStack`; `scrollToNewest` uses `proxy.scrollTo(id, anchor: .bottom)`, which aligns
   against the **visible region**, so the padding was simply scrolled off-screen. Fixed by
   putting `.padding(.bottom, reserve)` on the **ScrollView's own frame**.
   **`.safeAreaInset` was measured and rejected**: it left the backing `NSScrollView`
   frame, clip view and `contentInsets` all untouched at 400.0 — indistinguishable from
   the defect, and therefore unassertable. The frame inset reads 317 of 400.
2. **MAJOR — Mark was unreachable.** The visible Mark capsule opened the list; `onMark`
   lived on a 0×0, `opacity(0)`, `accessibilityHidden(true)` button. No mouse user could
   flag a moment; VoiceOver could not either.
3. **MINOR — the zero→one step slid Stop 11pt right.** The cluster is centred, so any
   widening splits across both sides. Observed as `456.0 vs 445.0pt`.
4. **The owner's eye caught what no test could.** Fixing (3) by reserving a two-digit plate
   *from zero* kept every test green and made Mark draw **44pt against Stop's 23pt**,
   permanently, glyph off-centre. The tests asked "does anything move" — nothing moved; it
   was simply the wrong shape the whole time. Now a **badge overlay**, which is outside the
   layout, so the rule holds by construction.

### The transferable lesson

**A passing test is evidence about the assertion, not about the behaviour.** Each of these
asserted the thing *adjacent* to what mattered: content height without ever driving the
scroll view; overall width on a centred row where the failure was a translation; "nothing
moves" where the defect was static asymmetry.

**The countermeasure that worked**: require the agent to write the test that FAILS on the
current commit, RUN it, and report the failing numbers. That produced `0.0 vs 83.0`,
`456.0 vs 445.0` and `351.0 vs 275.0` — three defects caught by their own numbers.

Recorded in memory as `swiftui-scroll-reserve-and-adjacent-assertions.md`, and on Chaotica
at `wiki/entities/nota.md` + a `wiki/log.md` entry.

## Linear

XIA-442 field engine (Done) · XIA-443 ground ink (Done) · XIA-444 session bar superseded
(Done) · **XIA-445 capsule cluster — needs closing, it is shipped.** The XIA-423 amendment
comment records the two rejected layouts.

## Open, in the order they unblock

1. **XIA-429 — re-ask it.** Its decision was "the column stays at Stop and changes subject",
   and the column no longer exists. **XIA-437 (the landing beat) is blocked on this.**
   Never explained to the owner; it was the pending item when the design pivot took over.
2. **XIA-433 — moment markers end to end.** Now unblocked: Mark and its badge exist.
   `SessionMarkerList` is kept in `RecordingPane.swift` with no caller, deliberately,
   with a comment saying it is waiting for this ticket.
3. **XIA-434** — floating island + menu-bar presence. Ready.
4. **XIA-438** — audit + a11y + owner smoke. Cannot be done AFK by design.
5. Carried: XIA-441; XIA-439/440 blocking XIA-438; flaky `FocusedTargetTests` SIGSEGV;
   XCTest gate for the unguarded CGEvent tap; `.interpolation(.high)` ringing means the
   contrast bars describe the buffer, not the pixels.

## Unmeasured / untested, stated plainly

- **Click routing has no rendered-UI test.** SwiftUI publishes no accessibility tree for an
  unhosted hosting view in this bundle (measured 2026-08-11 — every label came back empty,
  Stop's included). So "the Mark capsule flags a moment" is asserted through
  `SessionCapsuleCluster.perform(_:)` and the `SessionClusterAction` table, which is
  structural, not observed. This is exactly the shape of gap that produced defect 2.
- The ⌘K accessibility hint is set but not asserted against a live tree.
- The badge has been deployed but **not yet looked at by the owner** under a real session.

## Traps re-confirmed tonight

- A **full-target** `NotaUITests` run **wedges forever** while `/Applications/Nota.app` is
  running — both carry bundle id `com.xiafawu.nota`. Always `-only-testing`.
- `-only-testing:NotaDictationTests/…` for a `UI/Tests` class silently reports
  "Executed 0 tests". `Nota/UI/Tests` → `NotaUITests`.
- `macos/Nota.xcodeproj` is gitignored, generated by `xcodegen generate --spec project.yml`
  from directory globs. SourceKit errors in the editor for files inside agent worktrees are
  noise from the missing generated project, not real.
- All network git/gh ran under `env -u GH_TOKEN` (bot token vs personal).
- Workflow worktrees must be `git worktree remove`d before another agent can check out the
  same branch.
