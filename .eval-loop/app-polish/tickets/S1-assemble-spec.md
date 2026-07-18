<!-- wayfinder:task -->
# S1 — Assemble the polish spec

status: open
blocked-by: D1

## Question

Assemble the locked spec from D1's verdict table: per-surface sections, each
accepted defect with its agreed fix direction and priority, hard constraints
(no new features; structure changes only where D1 approved them; dark-capsule HUD
direction immutable), and per-surface verification (screenshot-compare + full Swift
test suite + `npm run build:macos`).

Execution per the map: Claude direct, worktree branch per surface, per-surface PRs,
screenshot-verified. Spec lives at `.eval-loop/app-polish/POLISH-SPEC.md`.

Resolving this ticket completes the map — the way is clear, implementation starts.
