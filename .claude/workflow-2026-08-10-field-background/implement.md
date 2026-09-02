Verified: second dictation-bundle run is 575/575 green with exit 0, so that crash is a pre-existing flake, not mine.

## Files

**Created**
- `/Users/xiafawu/Developer/Nota/macos/Nota/UI/Field/FieldEngine.swift` — `@MainActor final class FieldEngine: ObservableObject`, matching `MicLevelFeed`'s classic-`ObservableObject` shape. Publishes `image: CGImage?` and `isRunning`; `addViewer()`/`removeViewer()` refcount a 50 ms `Timer` on `RunLoop.main` in `.common` (the `BackgroundProcessing.syncTicker` pattern); `tick(dt:)` is internal and takes real elapsed time from `ProcessInfo.systemUptime`; `light` and `reduceMotion` are pushed in by the view; `static let shared`; injected-simulation init that starts nothing.
- `/Users/xiafawu/Developer/Nota/macos/Nota/UI/Field/FieldBackground.swift` — `Image(decorative:)` → `.resizable().interpolation(.high).scaledToFill()` inside a `GeometryReader` + `.clipped()`, `CraftNoiseLayer` overlay, `CraftWashBackground()` fallback, `.allowsHitTesting(false)`, `.ignoresSafeArea()`, viewer add/remove on appear/disappear, `.onChange` for both environment values. No `.drawingGroup()`.
- `/Users/xiafawu/Developer/Nota/macos/Nota/UI/Tests/FieldBackgroundTests.swift` — 15 tests in `NotaUITests` (same target as `FieldEngineTests`), all green.

**Modified**
- `macos/Nota/UI/HomeDashboardView.swift`, `macos/Nota/UI/LiveMeetingView.swift` — the two swaps.
- `macos/Nota/UI/CraftGlass.swift` — `private struct CraftNoiseLayer` → `struct CraftNoiseLayer` (plus a comment saying why). Unavoidable: it was file-private and the grain is required. `SplitMix64` stays private — the test target declares its own top-level `SplitMix64`, and promoting the app's would collide.

```diff
-      CraftWashBackground()
+      FieldBackground()
       ScrollView {                                   # HomeDashboardView.swift:136

-    .background(CraftWashBackground())
+    .background(FieldBackground())                    # LiveMeetingView.swift:179
```

## The one thing the brief did not settle — and it was a real defect

**`FieldEngine.shared` is inert under XCTest.** `RecordingPaneTests.testTheIdlePaneDrawsNoEmber` renders `LiveMeetingView` through `RenderProbe`, and I measured that `onAppear` **does** fire under `cacheDisplay` — so the shared ground really is painted under that pane. Measured 2026-08-10: **11 of the 16 grounds register on `RenderProbe.emberPixels`**, up to 51,974 pixels of a 600×420 render (kiln 51974, dusk 41951, heath 36590, meadow 29079, quarry 28070, nocturne 23154, fern 11149, orchard 10684, tidepool 9908, lichen 2318, bloom 362; tide/ink/harbour/frost/vellum 0). With the palette drawn at random per launch, that assertion became a coin flip — it passed on my first run by luck.

I tried to fix the probe and **could not**: the ring's darkest pixel is ΔE 39.7 from ember (Lab), and `FieldEngineTests`' own sweep reports the warmed ground reaching **ΔE 41.3** (dusk light @7200s). Hue, saturation and lightness all overlap too. No threshold separates a 55–90%-opacity ember stroke from a warm ground, so the fix had to be structural, not numerical.

So `shared` is built with `drawsFrames: !isUnderTest` (the `XCTestConfigurationFilePath`/`XCTestBundlePath` idiom already used by `DictationSettingsStore` and the single-instance guard). Under test it paints nothing, starts no clock, steps for nobody — `image` stays nil, so `FieldBackground` draws the wash, and every existing view test looks at exactly the ground it was written against. It also **does not read or write `notaFieldGroundID`**, which matters on its own: that key lives in the real `com.xiafawu.nota` domain and a test run would otherwise decide the owner's next launch — the same leak CLAUDE.md records as "Nota forgets my settings on every redeploy". Two new tests pin both halves. `FieldBackgroundTests` builds its own engines, so it is unaffected.

## Smaller decisions

1. **`maxStep = 0.25 s`.** The tick asks the clock, so a stalled main thread cannot slow the drift — but the other end needs a rail, or a sleep/off-screen minute advects the whole frame in one step. Past the cap the field loses the time rather than jumping.
2. **One painted frame is `step(dt: 0)`**, not a second render path — `step` is the simulation's only mutator, and at zero the advection, seed motion and `elapsed` are all no-ops. That is what makes the Reduce Motion frame and the light/dark repaint safe.
3. **`addViewer()` paints if `image == nil`** so a viewer never renders the fallback wash for a frame (a visible cut between two different grounds).
4. **`light` repaints immediately** rather than waiting for a tick — a Reduce Motion engine never ticks again and would hold a light band under a dark app until relaunch.
5. **Left unfixed, flagged:** at launch the very first body evaluation runs *before* `onAppear`, so there is one frame of wash before the field appears. Painting eagerly in `init` would be worse — the scheme has not been pushed yet, so it would flash light-field→dark-field instead.

## Test results

- `NotaUITests`: **445/445 pass** (includes the 15 new ones and `testTheIdlePaneDrawsNoEmber`, now deterministic).
- `NotaDictationTests`: 575/575 pass, exit 0.
- One whole-suite run hit `SIGSEGV` in `PasteInjector.capture` (`NSPasteboard._typesAtIndex`, `TextInjector.swift:401`, on a background thread) during `FocusedTargetTests`. **Pre-existing and unrelated** — nothing in my diff is in that stack, no dictation test constructs `FieldEngine`, the test passes alone, and a second full dictation-bundle run was clean. It looks like a race between a prior test's in-flight paste task and the pasteboard read. Worth a ticket; I did not touch it.

Nothing committed; all changes are in the working tree. `macos/Nota.xcodeproj` was regenerated by `xcodegen` (no `project.yml` edit needed — the test dir is globbed).