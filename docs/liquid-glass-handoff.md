# Liquid Glass Migration — Session Handoff

**Purpose:** migrate the Nota macOS app from its current pre-Tahoe SwiftUI UI to a native Liquid Glass UI.
**Target OS:** macOS 26 (Tahoe). **Target SDK:** Xcode 26.
**Breaking:** drops macOS 14/15 support.

## 1. Starting state

- Repo: `xiafawu/MeetingSum` on GitHub (project renamed to Nota; repo name not yet changed).
- Working directory: `/Users/xiafawu/Developer/Nota`
- Branch: `master` (clean baseline; create a feature branch before each issue).
- App entry point: [`macos/Nota/NotaApp.swift`](../macos/Nota/NotaApp.swift)
- Info.plist: [`macos/Nota/Info.plist`](../macos/Nota/Info.plist) — currently `LSMinimumSystemVersion = 14.0`.
- Build script: `scripts/build-macos.sh`; deploy: `npm run deploy:macos`.
- Existing smoke test: `runHeadlessSmokeTest` in `NotaApp.swift` (invokes `nota-app-run.sh`).

### What's already wrong with the current UI

| Symbol | File:line | Issue |
|---|---|---|
| `.background(.bar)` | `NotaApp.swift:700` | pre-Tahoe material |
| `HSplitView` | `NotaApp.swift:702` | legacy split; blocks adaptive sidebar glass |
| `Color(nsColor: .windowBackgroundColor)` | `NotaApp.swift:775` | solid drop-zone fill |
| `RoundedRectangle.strokeBorder(...dash: [6,6])` | `NotaApp.swift:777-779` | dashed stroke instead of glass card |
| `scrollView.drawsBackground = true` | `NotaApp.swift:664` | kills scroll edge effect |
| `.background(Color(nsColor: .textBackgroundColor))` | `NotaApp.swift:875` | TextEditor opaque fill |
| `LSMinimumSystemVersion = 14.0` | `Info.plist:24` | gates all Liquid Glass APIs |

## 2. Issue tracker

All 13 issues filed on `xiafawu/MeetingSum` with labels `liquid-glass` + `macos`.

| # | Title | Depends on |
|---|---|---|
| [#1](https://github.com/xiafawu/MeetingSum/issues/1) | Foundation: min OS 26 + Xcode 26 SDK | — |
| [#2](https://github.com/xiafawu/MeetingSum/issues/2) | Build script → Xcode 26 SDK | #1 |
| [#3](https://github.com/xiafawu/MeetingSum/issues/3) | Docs: `docs/macos-app.md` min OS bump | #1 |
| [#4](https://github.com/xiafawu/MeetingSum/issues/4) | HSplitView → NavigationSplitView | #1 |
| [#5](https://github.com/xiafawu/MeetingSum/issues/5) | Toolbar `.bar` → native Liquid Glass | #1 |
| [#6](https://github.com/xiafawu/MeetingSum/issues/6) | Wrap toolbar buttons in `GlassEffectContainer` | #5 |
| [#7](https://github.com/xiafawu/MeetingSum/issues/7) | Copy/Export/Reveal → `.buttonStyle(.glass)` | #6 |
| [#8](https://github.com/xiafawu/MeetingSum/issues/8) | Status + ProgressView → glass badge capsule | #5 |
| [#9](https://github.com/xiafawu/MeetingSum/issues/9) | Drop zone → `.glassEffect()` surface | #1 |
| [#10](https://github.com/xiafawu/MeetingSum/issues/10) | RichTextViewer transparent + scroll edge effect | #1 |
| [#11](https://github.com/xiafawu/MeetingSum/issues/11) | TextEditor markdown view scroll edge effect | #10 |
| [#12](https://github.com/xiafawu/MeetingSum/issues/12) | Accessibility `reduceTransparency` fallback | #5 #6 #7 #8 #9 #10 #11 |
| [#13](https://github.com/xiafawu/MeetingSum/issues/13) | Smoke test asserts Liquid Glass linkage | #12 |

Parent #1 carries the tracking checklist.

## 3. Execution plan (agent teams)

The graph has clean phase barriers. Parallelize within a phase; never across.

```
Phase 0: #1 (sequential, solo agent)
          │
          ▼
Phase 1: {#2, #3, #4, #5, #9, #10}  ← 6 agents in parallel
          │
          ▼
Phase 2: {#6, #8, #11}              ← 3 agents in parallel
          │
          ▼
Phase 3: {#7}                       ← 1 agent
          │
          ▼
Phase 4: {#12}                      ← 1 agent (touches every surface)
          │
          ▼
Phase 5: {#13}                      ← 1 agent
```

### Suggested agent assignments

Use `executor` (Sonnet) for mechanical conversions, `designer` (Sonnet) for surfaces that affect layout, `test-engineer` for smoke test, `writer` (Haiku) for docs.

| Issue | Agent | Model | Rationale |
|---|---|---|---|
| #1 | executor | sonnet | trivial plist edit + verify compile |
| #2 | executor | sonnet | shell script edit |
| #3 | writer | haiku | docs only |
| #4 | designer | sonnet | layout structural change |
| #5 | designer | sonnet | toolbar restructure (affects layout metrics) |
| #6 | designer | sonnet | glass grouping; visual polish |
| #7 | designer | sonnet | button style sweep |
| #8 | designer | sonnet | animated badge |
| #9 | designer | sonnet | drop zone surface |
| #10 | executor | sonnet | NSViewRepresentable tweak + modifier chain |
| #11 | executor | sonnet | two-line change |
| #12 | designer | opus | cross-cutting a11y audit; needs judgment |
| #13 | test-engineer | sonnet | script + binary introspection |

### Parallelization spawn template

```
Phase 1 parallel spawn (6 agents in a single message, multiple Agent tool calls):
  Agent(subagent_type=executor,  prompt=<#2 spec below>)
  Agent(subagent_type=writer,    prompt=<#3 spec>)
  Agent(subagent_type=designer,  prompt=<#4 spec>)
  Agent(subagent_type=designer,  prompt=<#5 spec>)
  Agent(subagent_type=designer,  prompt=<#9 spec>)
  Agent(subagent_type=executor,  prompt=<#10 spec>)
```

Each agent gets a worktree via `isolation: "worktree"` so concurrent edits to `NotaApp.swift` don't collide. Merge worktrees back serially after each agent's PR is reviewed.

## 4. Per-issue implementation spec (concrete changes)

### #1 Foundation
- Edit `macos/Nota/Info.plist:24` → `<string>26.0</string>`
- Verify `npm run build:macos` compiles (expect warnings but no errors; errors resolved by #2)
- **Done when:** `defaults read $(pwd)/.build/macos-app/Nota.app/Contents/Info.plist LSMinimumSystemVersion` returns `26.0`.

### #2 Build script
- Edit `scripts/build-macos.sh` — prepend or export `DEVELOPER_DIR=/Applications/Xcode-26.app/Contents/Developer` (or `xcrun --sdk macosx26`)
- Add guard: `[[ -d "$DEVELOPER_DIR" ]] || { echo "Xcode 26 missing"; exit 1; }`
- **Done when:** `npm run build:macos` passes with `CFBundleSupportedPlatforms` containing `macosx26`.

### #3 Docs
- Edit `docs/macos-app.md` — add "Requires macOS 26 (Tahoe) or later" near top, note Xcode 26 build requirement.
- **Done when:** doc lint passes (no broken links); markdown preview shows update.

### #4 NavigationSplitView
- In `ContentView.body` ([`NotaApp.swift:696`](../macos/Nota/NotaApp.swift:696)), replace:
  ```swift
  HSplitView {
    dropPane.frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
    resultPane.frame(minWidth: 460)
  }
  ```
  with:
  ```swift
  NavigationSplitView {
    dropPane.navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
  } detail: {
    resultPane.navigationSplitViewColumnWidth(min: 460)
  }
  ```
- Preserve `.onDrop` handler on `dropPane`.
- **Done when:** sidebar renders with Liquid Glass chrome; drop still functional.

### #5 Toolbar
- Extract toolbar content out of `VStack`; attach via `.toolbar { ToolbarItemGroup(placement: .primaryAction) { ... } }` on `ContentView`.
- Delete `.padding(12).background(.bar)` on the inner `HStack`.
- Move status `Text` + `ProgressView` into a trailing `ToolbarItemGroup(placement: .automatic)`.
- **Done when:** toolbar shows Liquid Glass refraction when content scrolls under.

### #6 GlassEffectContainer
- Wrap `Open`, `Transcribe`, `Remember speakers` in:
  ```swift
  GlassEffectContainer(spacing: 8) {
    Button(...).glassEffect(.regular, in: .capsule)
    ...
  }
  ```
- **Done when:** buttons refract as a single glass volume (visual check).

### #7 Menus
- Apply `.buttonStyle(.glass)` on `Copy`, `Export`, `Reveal` menu buttons ([`NotaApp.swift:824-863`](../macos/Nota/NotaApp.swift:824)).
- Wrap in right-side `GlassEffectContainer`.

### #8 Status badge
- Create conditional view:
  ```swift
  if model.isRunning {
    HStack(spacing: 6) {
      ProgressView().controlSize(.small)
      Text(model.status).font(.callout)
    }
    .padding(.horizontal, 10).padding(.vertical, 4)
    .glassEffect(.regular.tint(.secondary.opacity(0.1)), in: .capsule)
    .transition(.opacity.combined(with: .scale))
  }
  ```

### #9 Drop zone
- Replace in `dropPane` ([`NotaApp.swift:774-780`](../macos/Nota/NotaApp.swift:774)):
  ```swift
  .background(model.isDropTargeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .windowBackgroundColor))
  .overlay { RoundedRectangle(...).strokeBorder(...) }
  ```
  with:
  ```swift
  .glassEffect(
    model.isDropTargeted ? .regular.tint(.accent) : .regular,
    in: RoundedRectangle(cornerRadius: 20)
  )
  .padding(14)
  ```

### #10 RichTextViewer
- In `makeNSView` ([`NotaApp.swift:660-682`](../macos/Nota/NotaApp.swift:660)):
  - `scrollView.drawsBackground = false`
  - `textView.drawsBackground = false`
  - Delete `scrollView.backgroundColor = .textBackgroundColor`
- On `ContentView`: `.containerBackground(.regularMaterial, for: .window)`
- On `RichTextViewer` call-site: `.scrollEdgeEffect(.hard, for: .top)`

### #11 TextEditor
- Delete `.background(Color(nsColor: .textBackgroundColor))` ([`NotaApp.swift:875`](../macos/Nota/NotaApp.swift:875))
- Add `.scrollEdgeEffect(.hard, for: .top)`

### #12 Accessibility
- Add to `ContentView`: `@Environment(\.accessibilityReduceTransparency) var reduceTransparency`
- Create helper:
  ```swift
  func glassOrFallback<S: Shape>(_ shape: S, tint: Color? = nil) -> some ViewModifier {
    if reduceTransparency {
      return AnyViewModifier { $0.background(.regularMaterial, in: shape) }
    } else {
      return AnyViewModifier { $0.glassEffect(tint.map { .regular.tint($0) } ?? .regular, in: shape) }
    }
  }
  ```
- Apply everywhere `.glassEffect` was used (drop zone, badge, containers).
- Test both states manually.

### #13 Smoke test
- Extend `runHeadlessSmokeTest` or `scripts/deploy-macos.sh`:
  ```bash
  MIN_OS=$(defaults read "$APP/Contents/Info.plist" LSMinimumSystemVersion)
  [[ "$MIN_OS" == "26.0" ]] || { echo "wrong min OS: $MIN_OS"; exit 1; }
  otool -L "$APP/Contents/MacOS/Nota" | grep -q SwiftUI.framework || { echo "SwiftUI not linked"; exit 1; }
  ```

## 5. Constraints + gotchas

- **Do not merge children before parent** — every child assumes #1 is merged. Enforce via PR review, not GH (task lists are visual-only).
- **Worktree isolation required** — most issues edit `NotaApp.swift`. Without worktrees, parallel agents will stomp each other.
- **Xcode 26 must be installed locally** before #1 verification. If absent, the agent will report a build failure; treat that as a blocker, not a code bug.
- **`.glassEffect` availability** — guarded by `if #available(macOS 26, *)` is unnecessary once #1 merges (min OS = 26), but during the transition period compile against Xcode 26 SDK without availability guards.
- **`containerBackground(.regularMaterial, for: .window)`** — set once on `ContentView`, not per subview.
- **Scroll edge effect needs transparent content** — if #10 ships without #5 toolbar change, the effect looks wrong. Gate #10 review on #5 being merged first.
- **`NSViewRepresentable` + Liquid Glass** — `RichTextViewer` is AppKit-bridged. Its parent SwiftUI modifier `.scrollEdgeEffect` applies to the SwiftUI wrapper, not the inner `NSScrollView` — verify with actual scroll.
- **`reduceTransparency` testing** — toggle via System Settings → Accessibility → Display → Reduce Transparency. Required manual QA step before closing #12.

## 6. Verification gates

Before closing any issue:

1. `npm run build:macos` — must succeed.
2. Deploy to a clean `NOTA_DEPLOY_DIR`: `NOTA_DEPLOY_DIR=/tmp/nota-test npm run deploy:macos`.
3. Launch, drop a test audio file, confirm transcription still works.
4. Visual check against [Apple HIG Liquid Glass page](https://developer.apple.com/design/human-interface-guidelines/materials).
5. Screenshot attached to PR.

Before closing #13 (final):

- All 12 prior PRs merged.
- Smoke test assertions pass.
- Manual test of Share Extension path (`scripts/nota-share.sh`).

## 7. Branch + PR naming

- Branch per issue: `liquid-glass/<issue-number>-<short-slug>` (e.g. `liquid-glass/5-toolbar-native`).
- PR title: `Liquid Glass: <short description> (#<issue-number>)`.
- PR body: `Closes #<issue-number>` + before/after screenshot.

## 8. Next-session kickoff command

```
Start with #1 (solo, executor agent). After merged, spawn 6 agents in parallel for phase 1 (#2, #3, #4, #5, #9, #10), each in its own worktree. Use this handoff as the plan of record.
```

---
*Handoff written 2026-04-24 for Nota Liquid Glass migration. Source of truth: the 13 GitHub issues linked above — if this doc drifts, issues win.*
