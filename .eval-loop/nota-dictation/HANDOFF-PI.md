# Nota Dictation — Handoff for pi harness (P2)

Self-contained. Assume no prior conversation. You are continuing a multi-phase
feature in the **Nota** macOS app.

## Where things stand

- Repo: `/Users/xiafawu/Developer/Nota`
- Branch: `nota-dictation-p1` (stay on it; do not branch to master).
- Full spec (READ IT FIRST): `.eval-loop/nota-dictation/CODEX-SPEC.md` — complete,
  authoritative. `.eval-loop/nota-dictation/plan.md` = 5-phase overview.
- **Phase 1 is DONE and reviewed**, commit `81bfd0b`. It added, under
  `macos/Nota/Dictation/`: `DictationController`, `DictationMenuBarView`,
  `DictationTypes` (state machine incl. an `injecting` state placeholder),
  `HotkeyMonitor` (Fn/Globe hold-to-talk via **listen-only** `CGEventTap`),
  `MicCapture` (16 kHz mono PCM, capture-only), `PermissionsCoordinator`
  (Accessibility + Input Monitoring + Microphone onboarding). Main app is
  unsandboxed; `NotaShare` stays sandboxed.

## Verified facts (already checked — trust these)

- P1 scope is clean: no `src/**`, registry, pipeline, or settings.json touched.
- Build is GREEN end-to-end on this machine (Xcode 26.2): `npm run build:macos`
  → `** BUILD SUCCEEDED **`, exit 0, `.app` with compiled AppIcon.
- The `AppIcon.icon`/`actool` failure a previous agent reported does NOT
  reproduce here — it was a local toolchain gap (`.icon` is an Icon Composer
  doc needing Xcode 26+). **Do NOT touch the icon or `macos/project.yml` to
  work around it.** If your env fails on actool, update Xcode / clean
  DerivedData; leave icon config alone.

## Your task: PHASE 2 ONLY (spec §5 "P2 — Apple engine, paste-only inject")

1. Define `SpeechStream` protocol per spec §4: `start()`, `feed(pcm)`,
   `finish() -> AsyncStream<Hypothesis>` where `Hypothesis { text, isFinal }`.
2. Implement `AppleSpeechStream` — on-device `SpeechAnalyzer` (fall back to
   `SFSpeechRecognizer` if needed); emit partial + final hypotheses.
3. Implement `TextInjector` with **PASTE STRATEGY ONLY**: save clipboard → set
   text → synthesize Cmd-V → restore clipboard. NO AX `setValue`, NO CGEvent
   keystroke typing (those are P3).
4. Wire P1→P2: hold key → capture → Apple stream → on release finalize → paste
   into the focused field. Log hold-release→inject latency.

Paste-injection (NSPasteboard + synthetic Cmd-V) works in an ad-hoc dev build
once the user grants Accessibility — it does NOT need a notarized build. Update
the menu-bar copy so paste-mode is enabled when Accessibility is granted; keep
the "notarized build required" caveat only for the P3 AX/CGEvent strategies.

## Hard constraints (do not violate)

- macOS app only. Do NOT modify `src/**` (TS CLI), the batch pipeline,
  `src/registry.ts`, or the `~/.nota/settings.json` schema.
- All new code under `macos/Nota/Dictation/`. Extend the existing app target.
- Do NOT start P3 (no hybrid strategy, no per-app override table).

## Definition of done (P2 acceptance)

- Dictate a sentence into TextEdit AND the Chrome address bar; text lands.
- Original clipboard restored after paste.
- hold-release→inject latency measured and logged.
- Commit to `nota-dictation-p1`. Report what you built and how you verified
  each acceptance item.

## Build / verify commands

```
npm run build:macos          # xcodegen + xcodebuild → .build/DerivedData/.../Nota.app
cd macos && xcodebuild -project Nota.xcodeproj -scheme Nota \
  -configuration Debug -destination 'platform=macOS' build   # if project regenerated
```
Manual test: launch the built `Nota.app`, grant the 3 permissions, hold the
trigger key, speak, release, confirm text pastes into the focused field.
