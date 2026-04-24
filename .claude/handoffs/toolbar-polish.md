# Handoff: Nota macOS Toolbar Polish

**Status:** Resolved 2026-04-24. Ship-blocker re-review on `.claude/reviews/toolbar-iter-2.png` returned `RATING: 8/10` with no `CRITICAL_ISSUES`. One remaining follow-up: manual `accessibilityReduceTransparency` smoke test.
**Priority:** Medium. Gemini flagged as a ship-blocker at 7/10; not blocking user workflows, but visually sloppy.
**Owner file:** `macos/Nota/NotaApp.swift`

## Resolution

Swapped the segmented `Picker` for an `HStack` of two `Button`s routed through a new `ViewModePickerButtonStyle` modifier that branches on `isSelected`:

- Selected → `.buttonStyle(.glassProminent)` (or `.borderedProminent` under `reduceTransparency`)
- Unselected → `.buttonStyle(.glass)` (or `.bordered` under `reduceTransparency`)

Why this works where the segmented picker didn't:

1. **Alignment unified.** All toolbar buttons (Open, Transcribe, picker choices, Copy/Export/Reveal) now flow through the same `.glass`-family button-style pipeline, so they share the single accessory-baseline layout pass. The `.principal` placement still centers the pair in the toolbar but the per-button chrome matches the rest of the strip.
2. **Selected-state contrast.** `.glassProminent` on macOS 26 paints a brightened opaque capsule that overrides the translucent material chain entirely, giving high-delta relief regardless of wallpaper/window background. Stronger than `.segmented`'s accent-tint overlay on light liquid glass.
3. **Inference fix.** The style-switch modifier uses explicit `if / else if / else` branches under `@ViewBuilder` rather than a ternary, so the type checker resolves each branch independently. A ternary on `isSelected ? .borderedProminent : .bordered` tripped SourceKit's opaque-return-type inference.

Diff anchors:

- [macos/Nota/NotaApp.swift:816-832](../../macos/Nota/NotaApp.swift:816) — new `ViewModePickerButtonStyle` modifier.
- [macos/Nota/NotaApp.swift:883-897](../../macos/Nota/NotaApp.swift:883) — `.principal` toolbar slot now holds the two-button `HStack`.

### Remaining manual check

- [ ] `accessibilityReduceTransparency` branch: toggle `System Settings → Accessibility → Display → Reduce transparency` ON, relaunch Nota, confirm the `.bordered` / `.borderedProminent` pair still renders legibly and stays aligned with the other toolbar buttons.

## The Complaint

Verbatim from Gemini 2.5 Pro ship-blocker review of `.claude/reviews/layout-v1.png`:

> RATING: 7/10
> CRITICAL_ISSUES: The primary toolbar icons ("Rich Text", "Markdown" and the three action buttons to their right) are not vertically centered within the toolbar, which is a significant fit-and-finish bug. The selected "Rich Text" state has very low contrast, making it difficult to discern.
> SUMMARY: The application is mostly correct but has a critical toolbar alignment bug and poor control selection contrast, preventing it from shipping as-is.

Two distinct issues:

1. **Vertical centering bug** — Rich Text / Markdown segmented picker and the trailing Copy / Export / Reveal buttons sit visually high (or low) in the toolbar strip relative to the window chrome baseline.
2. **Selected-state contrast** — The active segment in the `ResultViewMode` picker is nearly invisible against the toolbar liquid-glass material.

## Reference Screenshot

`.claude/reviews/layout-v1.png` — captured with wallpaper backdrop via the `macos-vision-ui-review` skill's `capture.py`. The toolbar is the top strip; look at "Rich Text | Markdown" center, and the Copy / Export / Reveal icons at the far right.

## Where in Code

All toolbar logic lives in [`ContentView.body`'s `.toolbar { ... }` modifier](../../macos/Nota/NotaApp.swift):

| Line | Block | Content |
|------|-------|---------|
| [NotaApp.swift:863](../../macos/Nota/NotaApp.swift:863) | `ToolbarItemGroup(placement: .navigation)` | Open + Transcribe buttons (`.liquidGlassButton()`) |
| [NotaApp.swift:883](../../macos/Nota/NotaApp.swift:883) | `ToolbarItem(placement: .principal)` | `Picker("View", selection: $model.resultViewMode)` with `.pickerStyle(.segmented)`, `.frame(width: 200)` |
| [NotaApp.swift:894](../../macos/Nota/NotaApp.swift:894) | `ToolbarItemGroup(placement: .status)` | Running progress + status capsule |
| [NotaApp.swift:913](../../macos/Nota/NotaApp.swift:913) | `ToolbarItemGroup(placement: .primaryAction)` | Copy menu, Export menu, Reveal button |

The `liquidGlassButton()` + `liquidGlass()` modifiers are defined at [NotaApp.swift:718-750](../../macos/Nota/NotaApp.swift:718). They branch on `accessibilityReduceTransparency` and call `.buttonStyle(.glass)` (Tahoe-era) or `.buttonStyle(.bordered)`.

## What's Already Been Tried

Check `git log --oneline -- macos/Nota/NotaApp.swift` — recent toolbar-adjacent work:

- `516a562` — **always-enabled view Picker** per Gemini ship-blocker fix (previously the Picker disabled itself when markdown was empty, and the disabled segmented control rendered unreadably).
- `0c8fed5` — **moved view picker to toolbar principal** (was previously in the detail pane header).
- `2f87a0e` — detail pane `thinMaterial` for sidebar contrast, toggle spacing tweaks.

None of these addressed segmented-picker selected-state contrast or item vertical alignment.

## Hypotheses for Root Cause

1. **Vertical alignment** — mixing `ToolbarItem(placement: .principal)` (which centers vertically via the window title baseline) with `ToolbarItemGroup(placement: .navigation)` and `.primaryAction` (which align to the traffic-light / accessory baseline) creates a subtle offset on macOS 26 when the window also uses `.containerBackground(.regularMaterial, for: .window)`. The `.principal` slot is bigger-hit-targeted, so a 200px-wide picker inside it may render a few px higher than the adjacent icon buttons. Worth inspecting with `Xcode → Debug → View Debugger` on a real attach, or visually diffing with a baseline macOS app (Finder, Mail).
2. **Picker contrast** — `.pickerStyle(.segmented)` on Tahoe renders with `.accent`-tinted selection on top of liquid glass. On light material backgrounds the accent-on-white is very low delta. The fix is likely either:
   - Switch to `.pickerStyle(.palette)` or a custom `Button` group with explicit selection background.
   - Wrap the picker in a `.liquidGlass(.regular.tint(.quaternary), in: .capsule)` container so the selected segment gets a darker backdrop to overlay.
   - Test `.controlSize(.regular)` vs `.large` — larger size may bump contrast.
3. **Labels-hidden side effect** — `.labelsHidden()` on the picker strips the `"View"` label but may affect intrinsic content size → vertical stretch.

## Reproduction

```bash
cd /Users/xiafawu/Developer/Nota
bash scripts/deploy-macos-app.sh
# Launch + activate
osascript -e 'tell application id "com.nota.mac" to activate' || open /Applications/Nota.app
sleep 2
python3 ~/.claude/skills/macos-vision-ui-review/scripts/capture.py "Nota" .claude/reviews/toolbar-repro.png
sips -Z 1400 .claude/reviews/toolbar-repro.png --out .claude/reviews/toolbar-repro.png
# Inspect the top ~60px strip of the PNG
```

Zoom in on the top toolbar band. Compare the baseline of:
- The `"Rich Text | Markdown"` picker capsule
- The stroke weight of the adjacent `folder` / `waveform` SF Symbols
- The Copy / Export / Reveal icons on the right

They should share a common vertical centerline. They currently don't.

## Acceptance Criteria

- [ ] Re-run the macos-vision-ui-review skill's **ship-blocker prompt** on a fresh capture. Must return `RATING: >= 8/10` with no CRITICAL_ISSUES mentioning toolbar alignment or segmented-picker contrast.
- [ ] Selected segment of the `ResultViewMode` picker is visually distinct from unselected, readable at 100% display scale, and remains readable when the detail pane is in the empty-state mode (no content loaded).
- [ ] All toolbar icons (Open, Transcribe, picker, status capsule, Copy, Export, Reveal) share a single vertical centerline when inspected at 2× magnification.
- [ ] `accessibilityReduceTransparency` branch still renders without regressions (toggle via `System Settings → Accessibility → Display → Reduce transparency`).

## Out of Scope

- The sidebar history list styling is final (shipped 2026-04-24).
- Drop-zone typography and "Remember speakers" toggle layout are final.
- Don't touch the `.containerBackground(.regularMaterial, for: .window)` window-chrome modifier — that's intentional for the toolbar's translucent look.

## Useful References

- `.claude/reviews/iter-*.txt` — historical Gemini review outputs from the v1/v2 polish loops. Useful for seeing which critiques were taste vs. real.
- Skill: `macos-vision-ui-review` in `~/.claude/skills/` — automated capture + rate loop.
- Apple HIG on Toolbar: https://developer.apple.com/design/human-interface-guidelines/toolbars
- Apple HIG on Segmented Controls: https://developer.apple.com/design/human-interface-guidelines/segmented-controls

## Suggested Workflow for the Next Session

1. Reproduce — capture + eyeball the current toolbar at ≥2× zoom.
2. Prototype contrast fix first (lower-risk): tint the picker container or swap to palette/custom style. Rebuild, recapture, re-rate.
3. If alignment bug persists after contrast fix, inspect frame/alignment with `Environment(\.defaultMinListRowHeight)` or try moving the picker out of `.principal` into `.automatic` within the navigation group. Rebuild, recapture, re-rate.
4. Stop at `RATING: >= 8/10` from the ship-blocker prompt, or at two consecutive iterations with the same complaint (convergence — then report as known follow-up).
5. Remember: `open Nota.app` on a running instance does NOT reload the binary. The deploy script already `pkill`s first; if you bypass it, you'll be reviewing stale captures. See the `macos-app-deploy-kill-first` skill.
