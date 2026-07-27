# dictation-review-panel-polish

## Goal
Fix the three owner findings from the first live review-mode test (2026-07-27):
no live draft while talking, the home window opening with the review panel, and
the panel reading as a bare text input box.

## Changes
1. **Live draft in review mode** (`DictationController.swift`, `AppleSpeechStream`):
   review sessions currently ride the batch recognition path — no volatile feed.
   Run them on the STREAMING recognizer path for recognition/HUD (pill shows the
   live rough draft exactly as `.streaming` does) but deliver nothing until stop;
   on stop, full text → L2 → polish → review panel, unchanged. Segments are
   accumulated, never injected.
2. **No app activation** (`DictationReviewPanel.swift`): drop
   `NSApp.activate(ignoringOtherApps:)`. Style mask gains `.nonactivatingPanel`;
   `canBecomeKey` stays true — a nonactivating key panel takes typing without
   activating Nota (Spotlight pattern), so the home window never surfaces and the
   target app stays frontmost. Focus-return machinery simplifies accordingly
   (nothing to return when nothing was taken); keep the inject-to-stored-pid path.
   VERIFY typing actually lands in the editor under this mask — if SwiftUI
   TextEditor misbehaves in a nonactivating panel, fall back to NSTextView.
3. **Visual redesign**: match the pill's grammar — dark translucent rounded card
   (same `Color(white: 0.09).opacity(0.9)` family, hairline stroke, own shadow
   margin), title row ("Review dictation" + word count), editor area borderless on
   the card (no bezel/focus-ring box), footer: Discard (esc, subdued) and
   Apply (⌘⏎, prominent accent). Comparable products (superwhisper edit window,
   Raycast/Spotlight cards) favor exactly this: one dark card, no chrome.

## Tests
Review-branch tests updated for the streaming-recognizer path (segments
accumulate, nothing injected mid-session); panel construction test asserts the
nonactivating mask + key ability; existing apply/discard/learning tests unchanged.

## Execution
Implementer: Claude Opus 5 via Workflow agent, isolation=worktree.
Verify: xcodegen generate; xcodebuild test. Owner live-smoke after merge.
