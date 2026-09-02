export const meta = {
  name: 'xia-443-field-background',
  description: 'Plan 2: FieldBackground view + engine driver, swap the two CraftWashBackground call sites',
  phases: [
    { title: 'Scout', detail: 'read-only: feed patterns, pixel tests, tokens/noise' },
    { title: 'Implement', detail: 'FieldEngine + FieldBackground + 2 call-site swaps + tests' },
    { title: 'Verify', detail: 'build+test, and an adversarial review against CLAUDE.md' },
  ],
}

const REPO = '/Users/xiafawu/Developer/Nota'
const MAC = REPO + '/macos/Nota'

const SCOUT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['findings'],
  properties: {
    findings: {
      type: 'string',
      description: 'Dense prose+code notes an implementer can act on without re-reading the files. Quote exact symbol names, file:line, and short code excerpts.',
    },
  },
}

phase('Scout')

const scouts = await parallel([
  () => agent(
    `Read-only scout in ${REPO}. Do NOT edit anything.

Report exactly how this app builds a high-rate publisher that must NOT invalidate the whole window. Read:
- ${MAC}/App/LiveMeetingSession.swift (or wherever MicLevelFeed / MeterPublishGate live — grep for them)
- ${MAC}/UI/RecordingAccent.swift (SessionMeterFeedView and how it observes the feed)

Answer with exact code:
1. The exact declaration of MicLevelFeed (class kind, ObservableObject vs @Observable, @Published vs @Publisher, how it is held on the session: plain \`let\`).
2. MeterPublishGate's full logic (thresholds, the 66ms and 500ms rules) verbatim.
3. Which view observes the feed and HOW (@ObservedObject / @StateObject / .onReceive).
4. How the app reads Reduce Motion. Grep for accessibilityReduceMotion / RecordingMotion in ${MAC}/UI/RecordingAccent.swift and quote the exact environment key and usage.
5. Whether anything in the app already runs a repeating timer / CADisplayLink / Timer.publish for animation. Quote it if so.`,
    { label: 'scout:feeds', phase: 'Scout', schema: SCOUT_SCHEMA }),

  () => agent(
    `Read-only scout in ${REPO}. Do NOT edit anything.

Report how the macOS test target renders SwiftUI and inspects pixels, so an implementer can write the same kind of test.

Read ${MAC}/UI/Tests/RecordingAccentTests.swift and find the test named testTheIdlePaneDrawsNoEmber (grep it). Also skim ${MAC}/UI/Tests/FieldEngineTests.swift.

Answer with exact code:
1. The full body of testTheIdlePaneDrawsNoEmber, including the helper it uses to render a SwiftUI view to a bitmap and scan pixels. Quote the helper's full source and its file path.
2. Whether tests run on the main actor (@MainActor annotations) and what test framework (XCTest vs swift-testing).
3. The exact target layout: which .swift files under ${MAC}/UI/Tests belong to which test target. Read ${REPO}/macos/project.yml and quote the targets block.
4. Any existing test that constructs a SwiftUI View and asserts on it without a window server.`,
    { label: 'scout:pixeltests', phase: 'Scout', schema: SCOUT_SCHEMA }),

  () => agent(
    `Read-only scout in ${REPO}. Do NOT edit anything.

Report the ground/token surface a new background view must fit into.

Read ${MAC}/UI/CraftGlass.swift and whatever defines CraftTokens (grep 'enum CraftTokens' or 'struct CraftTokens').

Answer with exact code:
1. Full source of CraftWashBackground and CraftNoiseLayer.
2. The exact signatures + values of CraftTokens.washGradient(_:), CraftTokens.noiseOpacity(_:), CraftTokens.noiseColor(_:).
3. How CraftNoiseLayer generates its noise (is it a Canvas, an Image, a shader?) and whether it is expensive per render.
4. Whether the app pins NSApp.appearance (grep AppearanceSetting.apply) and how a SwiftUI view reads the effective colour scheme in this codebase.
5. Every PRODUCTION (non-#Preview) call site of CraftWashBackground with file:line and 5 lines of surrounding context.`,
    { label: 'scout:tokens', phase: 'Scout', schema: SCOUT_SCHEMA }),
])

const notes = scouts.filter(Boolean).map((s, i) => `--- SCOUT ${i + 1} ---\n${s.findings}`).join('\n\n')

phase('Implement')

const IMPL = `You are implementing plan 2 of the Nota animated-gradient work, in ${REPO} on branch xia-442-field-engine.

DO NOT COMMIT. Leave changes in the working tree. Do not touch git at all.

## What already exists (plan 1, committed as a23c676)

${MAC}/UI/Field/ contains a finished, tested pure engine:
- \`GroundPalette\` — struct, Equatable/Sendable/Identifiable, \`let id: String\`, \`let baseHue: Double\`, \`let familyHues: [Double]\`, \`static let all: [GroundPalette]\` (16), and
  \`static func pick<G: RandomNumberGenerator>(excluding excludedID: String?, using generator: inout G) -> GroundPalette\`
- \`CurlFlow\` — pure velocity field
- \`GroundWarmth\` — warmth(elapsed:), rotate(hue:amount:)
- \`FieldSimulation\` — \`final class\`, init(width: Int = 64, height: Int = 36, palette:, light: Bool, flatten: Double = 0.40, push: Double = 0.90); \`private(set) var buffer: [Float]\` (w*h*3, row-major, sRGB 0...255); \`private(set) var elapsed\`; settable \`palette\`/\`light\`/\`push\`/\`flatten\` which re-prime; \`func step(dt: TimeInterval)\` is the ONLY mutator. Measured 274 us/frame at 64x36 in Release.
- \`FieldImage.makeImage(from: FieldSimulation) -> CGImage?\` (about 10 us)
- \`GroundInk\` — fixed inks + tier alphas

READ those files before writing anything. Do not change any of them unless something is genuinely impossible without it — if you must, say so loudly in your report.

## Scout findings (trust these over your assumptions)

${notes}

## Deliverable

Two new files under ${MAC}/UI/Field/ plus two one-line call-site swaps plus tests.

### 1. \`FieldEngine.swift\` — the driver

A \`final class FieldEngine: ObservableObject\` (match whatever pattern MicLevelFeed uses — the scout quoted it).

Requirements, each of which is load-bearing:

- **One ground per launch.** It picks a \`GroundPalette\` with \`GroundPalette.pick(excluding:using:)\`, excluding the id it stored in UserDefaults last launch, then stores the new id. Use a dedicated defaults key (e.g. "notaFieldGroundID"). The pick happens ONCE for the process.
- **It is its own object, observed only by the background view.** It must never be a @Published property of anything ContentView or LiveMeetingView observes. This is XIA-432's exact trap: a feed on a widely-observed object rebuilt the whole window 45 times a second. Write a comment saying so.
- **It publishes a CGImage, not a buffer.** One \`@Published private(set) var image: CGImage?\`.
- **It ticks at ~20 fps (50 ms), not 60.** The field is blurred past recognition; a faster tick buys nothing and costs main-actor time. Use a repeating Timer on the main run loop (or match whatever the scout found the app already uses). \`step(dt:)\` gets the REAL elapsed time between ticks, not a hardcoded constant, so a stalled main thread does not slow the drift.
- **Refcounted start/stop.** \`retain()\` / \`release()\` (name them so they don't collide with ObjC memory semantics — prefer \`addViewer()\` / \`removeViewer()\`). The timer runs only while at least one viewer is on screen. Zero viewers -> invalidate the timer. The simulation state survives, so returning to a screen resumes the same ground mid-drift.
- **Reduce Motion stops the ticking, not the field.** When reduce-motion is on, the engine renders ONE frame (step once so the buffer is painted, then stop) and never ticks again. The skill's rule is literally "Reduce Motion is implemented by not calling step()". The view passes the flag in; the engine does not read the environment itself.
- **colorScheme drives \`light\`.** The view sets \`engine.light = (colorScheme == .light)\`; the simulation re-primes itself.
- **Testable without a timer.** Provide an initializer that takes an injected \`FieldSimulation\` and does not start a timer, plus an internal \`tick(dt:)\` the tests call directly. No test may need a run loop.
- A \`static let shared\` for the two call sites to share, but the class must be constructible independently for tests.

### 2. \`FieldBackground.swift\` — the view

\`struct FieldBackground: View\`. It replaces \`CraftWashBackground\` at the two production call sites and must be a drop-in: fills its container, \`.ignoresSafeArea()\`.

- Draws \`engine.image\` as \`Image(decorative:scale:orientation:)\` -> \`.resizable()\` -> \`.interpolation(.high)\` -> \`.scaledToFill()\`. A 64x36 image blown up to a window is the whole point; interpolation must be high or it will read as blocks.
- Keeps the grain: overlay \`CraftNoiseLayer\` exactly as \`CraftWashBackground\` does, same opacity and colour tokens. The soft-field skill is explicit that without grain the build bands on real displays and looks synthetic.
- Falls back to \`CraftWashBackground()\` when \`engine.image\` is nil (first frame, or CoreGraphics refused). Never a blank or black rectangle — this is a full-bleed ground behind text.
- \`.onAppear\` adds a viewer, \`.onDisappear\` removes one. Reads \`@Environment(\\.colorScheme)\` and \`@Environment(\\.accessibilityReduceMotion)\` and pushes both into the engine (\`.onChange\` for later changes too, not just onAppear).
- \`.allowsHitTesting(false)\` — it is a ground, it must not eat clicks.
- \`.drawingGroup()\` is NOT wanted; do not add it.

### 3. The two swaps, and nothing else

- ${MAC}/UI/HomeDashboardView.swift:136 — \`CraftWashBackground()\` -> \`FieldBackground()\`
- ${MAC}/UI/LiveMeetingView.swift:179 — \`.background(CraftWashBackground())\` -> \`.background(FieldBackground())\`

Leave every \`#Preview\` call site of CraftWashBackground alone. Do NOT delete CraftWashBackground — it is still the fallback and still the previews' ground.

### 4. Tests — \`${MAC}/UI/Tests/FieldBackgroundTests.swift\`

Put it in the SAME test target FieldEngineTests.swift is in (the scout confirmed which; getting this wrong makes the runner print "Executed 0 tests" and pass). No new project.yml entry is needed — macos/Nota.xcodeproj is XcodeGen-generated from directory globs.

Assert at minimum:
1. A fresh engine with a seeded RNG picks a palette whose id differs from the excluded one, and stores the new id.
2. \`addViewer\`/\`removeViewer\` refcounting: two adds and one remove leaves it running; the second remove stops it. Assert on an observable \`isRunning\`-style property, not on a timer.
3. \`tick(dt:)\` advances \`simulation.elapsed\` by exactly dt and publishes a non-nil image of the expected pixel dimensions.
4. Reduce Motion: with the flag set, the engine still produces an image (one painted frame) but \`elapsed\` does not advance on subsequent ticks.
5. Setting \`light\` re-primes: the published image changes between light and dark for the same palette (compare a sampled pixel, not the CGImage identity).
6. A nil image is possible only before the first tick — after one tick it is non-nil.

Write real assertions with real numbers. Do not write a test that cannot fail.

## Rules from this repo's CLAUDE.md that apply

- Never drive a background from an RMS level, a TimelineView, or a scroll offset (soft-field skill + XIA-432).
- A publisher's RATE and its observers' BREADTH multiply; neither is visible from the assignment.
- Comments in this codebase explain WHY a rule exists and what broke without it, in prose. Match that voice — read FieldSimulation.swift's comments and write like them. Do not write "// set the palette".

Report: the files you created/changed, the exact diff of the two call sites, and anything you had to decide that the brief did not settle.`

const impl = await agent(IMPL, { label: 'implement', phase: 'Implement' })

phase('Verify')

const verify = await parallel([
  () => agent(
    `In ${REPO}, verify the working-tree changes for the Nota field background build and pass their tests.

Do NOT commit. Do NOT use git except read-only (git status / git diff).

1. \`cd ${REPO}/macos && xcodegen generate --spec project.yml\` (the .xcodeproj is generated; new files under UI/Field and UI/Tests are picked up by directory globs).
2. Build the app target. Find the right scheme with \`xcodebuild -list -project Nota.xcodeproj\`. Build for macOS, Debug.
3. Run the test target that contains FieldEngineTests.swift and FieldBackgroundTests.swift. IMPORTANT: that is NOT NotaDictationTests — check which target owns the file before choosing -only-testing, or you will get a silent "Executed 0 tests" pass. Run FieldEngineTests, FieldBackgroundTests, RecordingAccentTests and RecordingPaneTests.
4. KNOWN TRAP: a full-target run wedges forever if /Applications/Nota.app is running (both share bundle id com.xiafawu.nota). Use -only-testing to scope to those four classes. If a run exceeds ~6 minutes with no output, kill only your own xcodebuild by resolved pid (never pkill/killall) and report the hang instead of retrying.

If anything fails, FIX IT — you may edit source. Re-run until green or until you are convinced the failure is real.

Report: the exact commands you ran, BUILD SUCCEEDED/FAILED, the test counts per class, and the verbatim first failure line of anything red.`,
    { label: 'verify:build', phase: 'Verify' }),

  () => agent(
    `Adversarial review, READ-ONLY, in ${REPO}. Do not edit anything.

New/changed files in the working tree implement a full-bleed animated gradient background (FieldEngine.swift, FieldBackground.swift under macos/Nota/UI/Field/, plus swaps in UI/HomeDashboardView.swift and UI/LiveMeetingView.swift and a new test file). Run \`git status\` and \`git diff\` to see them.

Your job is to REFUTE the claim that this is correct. Default to reporting a problem when uncertain. Check specifically:

1. **The 45 Hz trap.** Is the engine's @Published image reachable from any object that ContentView or LiveMeetingView observes? Trace the ownership. If FieldEngine.shared is touched by a widely-observed type, that is the XIA-432 defect returning — the repo's CLAUDE.md documents it at length. Read the "A feed that ticks does not belong on an object a window observes" bullet in ${REPO}/CLAUDE.md.
2. **Timer leaks.** Does the timer actually stop at zero viewers? Is there a retain cycle (Timer strongly holds its target; a closure capturing self strongly is a leak)? Does onDisappear fire reliably for a .background() modifier's content — check the LiveMeetingView call site specifically, since a view used as a .background may have different lifecycle from one in a ZStack.
3. **Refcount underflow.** Can removeViewer drive the count negative (double onDisappear, or onDisappear arriving after a new onAppear during a view swap)? What happens then?
4. **Contrast.** The whole engine was justified by measured contrast bars (body 7.0, speaker 4.5, timestamp 3.0, rail 1.2). Does the VIEW preserve them? Specifically: does any opacity, blend mode, material, or overlay applied to the field change its luminance from what FieldEngineTests measured? The noise overlay is the obvious suspect — quantify its effect if you can.
5. **The nil-image window.** Between onAppear and the first tick, what is on screen? Is it ever black, clear, or a flash?
6. **Reduce Motion.** Is a single frame actually painted, or does reduce-motion leave the ground blank?
7. **Tests that cannot fail.** Read the new test file and name any assertion that would pass against a broken implementation.

Report each finding as: file:line, what breaks, and the concrete sequence of user actions that triggers it. If you find nothing in a category, say so explicitly rather than staying silent.`,
    { label: 'verify:review', phase: 'Verify' }),
])

return {
  implement: impl,
  build: verify[0],
  review: verify[1],
}
