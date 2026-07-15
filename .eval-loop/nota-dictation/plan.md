# Nota Dictation Delivery Plan

Goal: add a second, system-wide voice-dictation mode to the existing macOS app.
Execution=Codex. Each phase is one reviewable PR from committed HEAD in a worktree.
Scope: Swift/macOS only; keep the TypeScript CLI and batch pipeline unchanged.
Spec: paste `.eval-loop/nota-dictation/CODEX-SPEC.md` to Codex for phase execution.

```text
P1 residency + hotkey + capture
              |
              v
P2 Apple Speech + paste-only injection
              |
              v
P3 hybrid injection
              |
              v
P4 formatting + settings + polish
              |
              v
P5 AssemblyAI realtime
```

P1 establishes menu-bar residency, hold-to-talk, microphone capture, and the three-permission onboarding gate.
P2 adds on-device Apple Speech and final-on-release paste injection.
P3 adds AX/CGEvent/paste fallback injection with secure-field refusal.
P4 adds local formatting, Swift-owned settings, toggle mode, and opt-in LLM polish.
P5 adds the opt-in AssemblyAI realtime WebSocket engine behind the same stream protocol.
Verification: build/test each PR, run the phase matrix, log release-to-inject latency, and review before merging.
Caveat: system-wide injection requires a non-sandboxed, Developer ID signed, notarized direct-download build; P1 permissions are load-bearing.
