## Verdict: not correct. Nine findings, across six of the seven categories.

---

### 1. The 45 Hz trap — **NOT reproduced** (say so explicitly), but a new per-frame cost was added

Ownership traced and it is clean. `FieldEngine.shared` (`FieldEngine.swift:76`) is reached only by `FieldBackground.init(engine:)` (`FieldBackground.swift:39`), which stores it in `@ObservedObject` on `FieldBackground` itself. `HomeDashboardView.swift:136` puts `FieldBackground()` as a sibling in a `ZStack`; `LiveMeetingView.swift:179` puts it in `.background(...)`. In both cases the observing View struct is `FieldBackground`, so a published `image` invalidates only that struct's body — not `ContentView`, not `LiveMeetingView`. `grep -rn "FieldEngine" macos | grep -v Field/` returns nothing outside the Field directory and its tests. **This is not XIA-432 returning.**

**But** — `FieldBackground.swift:58-63` — what does get rebuilt 20×/sec is the whole of `FieldBackground.body`, which includes `.overlay(CraftNoiseLayer(...))`. `CraftNoiseLayer` is a `Canvas` (`CraftGlass.swift:187-211`) whose renderer closure is not comparable, so SwiftUI re-runs it on every body evaluation: 28 columns × ~17 rows ≈ 476 `context.fill(Path(ellipseIn:))` calls plus 1,428 SplitMix64 draws, full-window, twenty times a second, on the main actor — the same actor as the hotkey tap, the HUD and the recording pane. Previously it ran once, ever, because `CraftWashBackground.body` never changed. The comment at `FieldBackground.swift:22-23` ("deterministic and static, so it never shimmers over a field that moves") describes a property that is now bought and paid for and then thrown away.

**Trigger:** open the app on the home screen and leave it there.

---

### 2. Timer leaks — two, one certain

**2a (certain). No `deinit`.** `FieldEngine.swift:104` holds `timer`; nothing invalidates it on deallocation (`grep -n deinit macos/Nota/UI/Field/` → empty). There is no *retain cycle* — the scheduled closure at `:242-244` captures only `[weak self]` inside the `Task`, so the engine can deinit — and that is exactly the problem: `RunLoop.main` retains the `Timer` independently (`:248`), so an engine deallocated with `viewers > 0` leaves a 20 Hz run-loop wakeup firing forever into a nil `self`, unreachable and unstoppable. Affects the `#Preview` at `FieldBackground.swift:84`, any test that builds an engine and calls `addViewer()` without a matching `removeViewer()` (`FieldBackgroundTests.swift:104` — `testAnExtraRemoveCannotWedgeTheClockOff` ends with the count at 0 so it's fine, but `:86-89` leaves one running mid-test), and any future per-window engine.

**2b (certain, and the bigger one). `onDisappear` is not visibility.** There is no occlusion, hide, or scene-phase handling anywhere in the app — `grep -rn "occlusionState\|didHideNotification\|scenePhase" macos` returns one unrelated `deminiaturize` at `NotaApp.swift:244`. `onDisappear` does not fire when the window is minimized, occluded by another app, on another Space, or when the app is hidden with ⌘H. So the refcount reads "mounted", not "on screen", and the clock keeps running: `FieldSimulation.step` (~115 µs per the file's own note) + `FieldImage.makeImage` + a re-run of the noise Canvas, 20×/sec, indefinitely.

**Trigger:** launch Nota, then ⌘H (or just click another app so its window covers Nota's). Nota is a menu-bar-resident dictation app the owner leaves running all day; this burns main-actor time for a surface nobody can see, forever, and it is exactly the class of cost the CLAUDE.md bullet is about.

**2c (`.background()` lifecycle — the specific thing you asked about).** I could not confirm a difference. `.background(_:)` content participates in the normal appearance lifecycle and `onDisappear` should fire on removal of `LiveMeetingView`. What I *can* confirm is that **nothing tests it**: `grep -rn "FieldBackground(" macos` finds the view constructed only in its own `#Preview` and the two production call sites. No test ever renders it. So the `.background` call site's lifecycle is an untested assumption in a file whose sibling suite is *named* `FieldBackgroundTests`.

---

### 3. Refcount — the clamp is the wrong repair

`FieldEngine.swift:208` — `viewers = max(0, viewers - 1)`. This makes the count non-negative and makes the *desync permanent and silent*.

- **Undercount → frozen ground.** One unbalanced `removeViewer` while a viewer is still mounted drives the count to 0, `syncTimer` invalidates the timer, and nothing ever calls `addViewer` again because the view is already mounted. The ground freezes on its last frame. There is no symptom: a frozen field is pixel-indistinguishable from Reduce Motion, and `isRunning` is `@Published` but rendered nowhere.
- **Concrete sequence (PLAUSIBLE, not confirmed — I cannot run it):** on the home screen press Start; `ContentView.phase` flips `.home → .liveMeeting` under `.animation(Tokens.animFast, value: phase)` with `Self.swapTransition` (`ContentView.swift:128`, `:90-93`). Before that transition completes, the session fails to open the mic and `phase` returns to `.home`. SwiftUI's `_ConditionalContent` branch removal fires `onDisappear` for the home subtree; the re-insertion of the *same* branch identity does not re-fire `onAppear`. Count: 1 → 0, viewer still on screen, clock dead until the app is relaunched.
- **The clamp also masks the opposite:** if `onDisappear` is ever missed (2b), the count only ever climbs, and the engine can never be quiesced.

`testAnExtraRemoveCannotWedgeTheClockOff` (`FieldBackgroundTests.swift:99-107`) asserts the clamp arithmetic and nothing about the failure the clamp exists to survive.

---

### 4. Contrast — the measured bars do not reach the screen. Two independent failures.

**4a (certain, and the headline). `GroundInk` has zero production callers.**

```
$ grep -rn "GroundInk" macos | grep -v /Tests/
macos/Nota/UI/Field/GroundInk.swift:31:enum GroundInk {
<...only project.pbxproj build-file entries...>
```

The whole justification — `GroundInk.swift:19-25`'s solved table (body 7.0 needs 89% light / 78% dark, speaker 4.5 needs 70/57, timestamp 3.0 needs 54/40, rail 1.2 needs 10/7) and `FieldEngineTests.testEveryTierClearsItsBarOnEveryGroundInBothThemes` — measures an ink constant that no view in the app draws with. The two surfaces that got the new ground use system colours: `HomeDashboardView.swift:177,182,239-240,276-277,300-318,381-384` and `LiveMeetingView.swift:237,258,301` are all `.primary` / `.secondary` / `.primary.opacity(0.5)` / `.secondary.opacity(0.5)`.

Compose that against the solve's own numbers: macOS `labelColor` in light mode is black at **0.85** alpha, against a body requirement of **0.89** for 7.0:1 on the worst cell of the worst ground. `secondaryLabelColor` is **0.50**, against a timestamp requirement of **0.54** for a mere 3.0:1. And `.secondary.opacity(0.5)` (the gated rows at `HomeDashboardView.swift:240,277`) lands near **0.25**, less than half the timestamp bar and well under the *rail* tier's semantics for something that is real, readable text. Every one of these was measured safe at an alpha the app does not use. (Confirm the exact system alphas with a pixel probe before quoting them, but the direction is not in doubt: the solve says "needs 89%" and nothing in the app draws at 89%.)

**4b (certain). Most of the app's text is not on the ground at all — it is on glass over the ground.** `craftGlassPanel` (`CraftGlass.swift:236-256`) is `.liquidGlass(.regular)`, a translucent material whose output luminance is a function of what is behind it. The field now moves behind every card on the home dashboard, and `FieldEngineTests` measures ink-directly-on-ground. There is no measurement of ink-on-glass-on-field for any of the sixteen grounds, in either theme.

**4c. The noise overlay — quantified, and it is NOT the suspect.** `CraftNoiseLayer` draws 28 × ⌊h/w·28⌋ ellipses whose *diameter* (`CraftGlass.swift:199-205` uses `radius` as both `width` and `height`) is uniform on 0.4–1.0 pt. Mean area = (π/4)·E[d²] = 0.785 · 0.52 ≈ 0.408 pt². On a 1280×800 window that is 28×17 = 476 dots ≈ 194 pt² of 1,024,000 pt² = **0.019% coverage**, at `opacity` 0.025 light / 0.045 dark (`CraftGlass.swift:37`). Mean luminance shift ≈ 0.019% × 0.025 ≈ 5·10⁻⁶ — five parts per million, i.e. zero effect on any contrast ratio. So the overlay clears category 4. The corollary is unflattering, though: at 0.019% coverage and one dot per ~2,150 pt², the grain also cannot be doing the anti-banding job `FieldBackground.swift:19-22` credits it with. That docstring's claim is unmeasured and, by this arithmetic, false.

**4d (unmeasured gap).** `FieldBackground.swift:49` sets `.interpolation(.high)` on a 64×36 image upscaled ~20× to a window. High-quality resampling is not a convex combination — it rings, and produces displayed luminances outside `[min, max]` of the source cells. `FieldEngineTests` measures `sim.color(x:y:)` at cell centres. The contrast bars are therefore statements about the buffer, not about the pixels. On a field this smooth the overshoot is small, but it is nowhere bounded and nowhere measured — and `.high` is described at `FieldBackground.swift:14` as load-bearing.

---

### 5. The nil-image window — the documented promise is false at the view level

`FieldBackground.swift:44-56` is an `if let image = engine.image { … } else { CraftWashBackground() }`. `addViewer()` (`FieldEngine.swift:199-205`) paints before returning — but it is called from `.onAppear` (`:75`), and `onAppear` fires *after* the body evaluation that installed it. At that first evaluation `engine.image` is nil, so the `else` branch (the cool periwinkle/indigo `CraftWashBackground`) is what enters the render tree. The first frame then flips the `_ConditionalContent` branch — a hard subtree swap with no crossfade — to a randomly-drawn ground that may be Kiln (orange), Bloom (magenta) or Fern (green).

`FieldBackground.swift:24-27` claims "`engine.image` is nil for exactly one moment"; `FieldEngine.swift:201-202` claims "A viewer that arrives to a nil image would draw the fallback wash for a frame, which is a visible cut between two different grounds. Paint first." The paint is in the wrong place to prevent it.

**Trigger:** cold-launch Nota to the home screen and watch the first ~16 ms.

Whether the wash actually reaches glass depends on whether the `@Published` write coalesces into the same `CATransaction` — which raises the second half: `addViewer()` and the `engine.light` setter at `:73` both mutate `@Published` state **from inside `onAppear` of the view that observes that object**, twice on a dark-mode cold launch (the shared engine is built `light: true` by the default at `FieldEngine.swift:153`, so `:118-119` re-primes and repaints). That is the shape that produces "Publishing changes from within view updates is not allowed" and forces a second update pass. Not black, not clear — but a flash, and one the code claims cannot happen.

---

### 6. Reduce Motion — **clean.** No finding.

`FieldBackground.swift:74` sets `engine.reduceMotion` before `addViewer()`. With the setting on at launch, `true != false` passes the guard at `FieldEngine.swift:132`, `syncTimer()` is a no-op (no viewers), and `paintOneFrame()` at `:134` runs: `drawsFrames` is true, `simulation.step(dt: 0)` with `primed == false` paints the target outright at `mix = 1.0` (`FieldSimulation.swift:371`), and `image` is set. `addViewer()` then finds a non-nil image and starts no clock. A single frame really is painted, the ground is not blank, and `tick` refuses to advance it (`:217`). The one path where it could have failed — `light` changing under Reduce Motion, where no later tick would ever repaint — is covered by the setter calling `paintOneFrame()` directly (`:119`). Correct.

---

### 7. Tests that cannot fail — five, and one structural

1. **`FieldBackgroundTests.swift:82-95` `testTheClockRunsWhileAnyViewerIsOnScreen`** and every other `isRunning` assertion. `isRunning` is a `@Published Bool` assigned at `FieldEngine.swift:250`, adjacent to the timer but not derived from it. Delete `RunLoop.main.add(timer, forMode: .common)` (`:248`), or empty the body of `tickFromClock()` (`:259-264`), and the entire suite stays green. The file's own docstring at `:12-13` — "None of it waits on a run loop … so a timer that never fires cannot make a green suite lie" — is exactly backwards: nothing in either suite asserts that a scheduled timer ever produces a tick (`grep -n "tickFromClock\|expectation" FieldBackgroundTests.swift FieldEngineTests.swift` → empty).

2. **`:161-167` `testAViewerArrivingIsPaintedBeforeTheFirstTick`.** Asserts the engine half of a two-part claim and is documented ("A viewer never sees the fallback wash") as proving the whole. The view half is false — finding 5. This test passes against the shipped, broken behaviour.

3. **`:277-289` `testTheSharedEngineDrawsNothingInATestBundle`.** Asserts `image == nil` and `elapsed == 0` on an engine constructed with `drawsFrames: false`, where `tick` (`FieldEngine.swift:217`) and `paintOneFrame` (`:230`) both `guard drawsFrames else { return }` on their first line. It asserts a compile-time constant. The one thing that could actually break — `isUnderTest` no longer seeing its bundle — is asserted separately at `:278`, so the remaining four assertions add nothing.

4. **`:129-139` `testATickAdvancesTheFieldByItsOwnDtAndPublishesThatFrame`.** The only thing checked about the published frame is `image.width`/`image.height`. It passes against an all-black image, an all-white one, or one built from an uninitialized buffer.

5. **`:144-148` `testALongStallIsClampedRatherThanJumped`.** One sample, `dt = 30`. Passes against `fieldClamp` replaced by `{ _,_,_ in FieldEngine.maxStep }`, and against a clamp with no lower bound. No test covers `dt = 0` or a negative `dt`.

**Structural, and worse than any of the five:** the file is called `FieldBackgroundTests` and contains no test of `FieldBackground`. The view is never rendered, never hosted, never probed — so the `.background()` lifecycle (2c), the noise overlay's presence over the field (4c), the branch-swap flash (5), and the `onAppear`-ordering bug that causes it (5) are all outside the suite's reach by construction. Contrast that with the precedent this repo already set: `RecordingPaneTests.testTheIdlePaneDrawsNoEmber` renders the real view and scans pixels, because "there is no ember on screen" is not a claim a constant can carry. Neither is "no viewer ever sees the wash."