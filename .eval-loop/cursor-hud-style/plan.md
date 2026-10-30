# Slug: cursor-hud-style

**Goal:** a 4th HUD style, **Cursor** — no preview; a Liquid Glass mark sits at the text caret while you dictate and text lands there. Spec of the end state, not steps: fit it to the repo's existing rules (CLAUDE.md → Dictation HUD Styles, Floating Glass). Look/feel reference: `prototype.html` here (owner-approved 2026-10-30; its glass is a browser imitation).

```text
Fn down ──→ ○ dot at caret ──(voice)──→ ▮▮▮▮▮ waveform ──(pause)──→ ○ dot
                                            │ sentence done
                                            ↓
                              ≈≈≈ wave rolls through bars ──→ text lands at caret, mark follows
Fn up ──→ last cleanup wave ──→ fade out (no "Inserted" card)
problem ──→ mark tints amber/red + one-line glass note beside it, fades ~4s
```

**Done means:**
- Settings → Dictation → Style offers Pill / Bar / Prompter / **Cursor**; new **Position: Beside cursor (default) / Below cursor**.
- Mark is one 20pt-tall glass capsule: 20pt dot (breathing core) ↔ ~40pt five-bar waveform (HUD meter's bars, smoothed). Shown only during a session; not draggable; never steals focus.
- Glass = real `NSGlassEffectView` via the shared Glass material + opacity settings (owner's is Clear).
- Caret from AX (`kAXBoundsForRangeParameterizedAttribute` on the selected range), re-read as text lands; fallback: focused element's bottom-right, then the pill's usual spot.
- Works with Insert While Speaking and Insert on Release (Release: caret captured at key-down). Review Before Inserting keeps its card, unchanged.
- AssemblyAI Realtime delivers each finished turn while speaking (today only the Apple engine streams); same append-only, in-order, fixed-target guarantees as Apple streaming.
- The `.success` "Inserted" card is removed from **every** style (owner, 2026-10-30): a successful insert just fades. Warnings/errors unchanged.
- Tests for the pure parts (placement, fallback, morph state, AssemblyAI turn delivery); CLAUDE.md updated. Out of scope: an always-on idle dot.

## Verification & Rollback
`xcodebuild test` (NotaDictationTests) green; deploy; owner dictates into Craft, Notes and Chrome in both delivery modes. Rollback = revert the branch.
## Execution
Model: Claude Opus. Implementer: one Agent, `isolation: "worktree"`, own branch, never commits to master; owner says "merge" before ff-only.
## Revisions
### r1 — 2026-10-30 @claude (initial)
From the grilling session in this thread (decisions: style not mode, edge fallback, waveform, Liquid Glass Clear, session-only, both delivery modes, tint+note errors, AssemblyAI streaming, drop "Inserted").
