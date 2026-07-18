<!-- wayfinder:task -->
# S1 — Assemble the polish spec

status: closed (resolved 2026-07-18)
blocked-by: D1 (closed)

## Question

Assemble the locked spec from D1's verdict table: per-surface sections, each
accepted defect with its agreed fix direction and priority, hard constraints
(no new features; structure changes only where D1 approved them; dark-capsule HUD
direction immutable), and per-surface verification (screenshot-compare + full Swift
test suite + `npm run build:macos`).

Execution per the map: Claude direct, worktree branch per surface, per-surface PRs,
screenshot-verified. Spec lives at `.eval-loop/app-polish/POLISH-SPEC.md`.

Resolving this ticket completes the map — the way is clear, implementation starts.

## Resolution

Spec assembled at [POLISH-SPEC.md](../POLISH-SPEC.md): 56 accepted findings assigned to
four file-fenced lanes (MAIN / HUD / SETTINGS / MENUBAR), hard constraints (no features,
dark capsule immutable, Tokens/Metrics single-owner), per-lane verification (build +
full Swift suite), merge order MAIN → HUD → SETTINGS → MENUBAR with post-merge
screenshot verification. Resolved out of order (before its `/wayfinder` invocation) at
the user's request so the implementation workflow could launch from a committed spec —
worktree agents only see committed HEAD. **Map complete.**
