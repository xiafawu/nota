# Nota System-wide Dictation — CODEX-SPEC

Paste this document to Codex. Implement one phase at a time. Each phase is one reviewable PR, created in a worktree branched from committed `HEAD`; do not begin the next phase until the current PR is reviewed and merged.

## 1. Product context

Nota (`/Users/xiafawu/Developer/Nota`) has two existing surfaces: a TypeScript CLI and batch transcription pipeline under `src/`, and a native SwiftUI macOS app under `macos/Nota/` with history, settings, document viewing, and a share extension. The existing app launches the CLI for file-based transcription and summarization.

Add a second mode to the macOS app: system-wide voice dictation. The user holds a global hotkey, speaks into the microphone, releases the key, and Nota inserts the recognized final text into the text field that currently has OS focus. It must work across normal Cocoa apps and common browser, Electron, terminal, and IDE fields. It is a dictation surface, not another batch-pipeline entry point.

## 2. Hard constraints

- Change only the Swift/macOS app and its build metadata under `macos/`. Do not touch `src/**`, TypeScript `tests/**`, `src/registry.ts`, the CLI commands, the batch pipeline, or the schema/contents of `~/.nota/settings.json`.
- Add the feature in-process to the existing `Nota.app`; do not create a second app, daemon, helper process, or CLI `dictate` command.
- New implementation files belong under `macos/Nota/Dictation/`. Reuse the existing app shell plus `NotaSettingsStore.swift`, `ApiKeyStore.swift`, and `ModelRegistry.swift` where this spec calls for them.
- Dictation preferences are Swift-owned and namespaced behind `NotaSettingsStore` but must not be written into the CLI settings JSON. Add a `UserDefaults`-backed `DictationSettings` key or equivalent Swift-only backing store; do not change the CLI settings schema. The optional polish model may reuse an existing `ModelRegistry` summary entry and `ApiKeyStore` key.
- Do not claim that a development/ad-hoc build can provide production system-wide injection. AX/CGEvent injection needs a non-sandboxed, Developer ID signed, notarized direct-download build. This is a distribution change from the current app and must be called out in onboarding/release notes.
- P1 onboarding for Accessibility, Input Monitoring, and Microphone is load-bearing. If any required permission is missing, dictation stays disabled with a specific status and a path to the relevant System Settings pane.
- Do not inject partial text in v1. Capture and recognition may stream partial hypotheses internally, but only the final, formatted text is injected after key release.
- Preserve the document-window, file-open, history, share-extension, and existing batch-run behavior. A menu-bar-resident app must still be able to open its existing document window on demand.

## 3. Eight locked decisions

| Axis | Locked decision |
|---|---|
| Product boundary | Dictation is a second macOS-app mode sharing the app shell, settings UI, and API-key plumbing; it never enters the CLI or batch pipeline. |
| Runtime/residency | Run in-process with a `MenuBarExtra` and agent-style residency; keep an explicit “Open Nota” action for the existing document window. |
| Capture/trigger | Default is hold-to-talk on the Fn/Globe key, observed as `flagsChanged`; microphone capture is live only during a session. Toggle mode and a configurable trigger are added in P4. |
| Recognition engine | Apple on-device Speech (`SpeechAnalyzer` with the macOS 26 Speech framework) is the default. AssemblyAI realtime WebSocket is an opt-in P5 engine behind the same protocol. |
| Injection | Use a per-bundle strategy table with the fallback order Accessibility value/insert → CGEvent keystrokes → clipboard + synthetic Cmd-V. Secure/password fields must no-op safely. |
| Formatting | Local deterministic rules always run before injection. Optional LLM polish is a final, opt-in pass using an existing summary model/key and never blocks rules-only fallback. |
| Settings and secrets | Dictation settings are Swift-only through `NotaSettingsStore` and `UserDefaults`; API credentials come from `ApiKeyStore`; no new secret store and no CLI JSON writes. |
| Permissions and distribution | Accessibility + Input Monitoring + Microphone are required runtime grants; production AX/CGEvent injection ships only in a non-sandboxed, notarized direct-download build. |

## 4. Architecture and core Swift types

Data flow:

```text
global hotkey ──> MicCapture ──> SpeechStream ──> Formatter ──> TextInjector ──> focused field
 (CGEventTap)      (16 kHz PCM)   (Apple | WS)    (rules | LLM)   (AX | CGEvent | paste)
       │                                                                    ▲
       └──────────── DictationController + MenuBarExtra status ─────────────┘
```

Keep the units small and testable. All new files are under `macos/Nota/Dictation/` unless an existing app file is named in a phase.

```swift
import AVFoundation
import ApplicationServices

enum EngineChoice: String, Codable { case apple, assemblyAIRealtime }
enum ActivationMode: String, Codable { case hold, toggle }

struct TriggerKey: Codable, Equatable {
  enum Kind: String, Codable { case fnGlobe, keyCode }
  let kind: Kind
  let keyCode: UInt16?
}

enum DictationState: Equatable {
  case disabled(reason: String)
  case idle
  case listening
  case finalizing
  case injecting
  case failed(message: String)
}

struct Hypothesis: Equatable, Sendable {
  let text: String
  let isFinal: Bool
}

protocol SpeechStream: AnyObject {
  var hypotheses: AsyncStream<Hypothesis> { get }
  func start() async throws
  func feed(_ pcm: AVAudioPCMBuffer) throws
  func finish() async throws -> String
  func cancel()
}

struct FocusedTarget {
  let bundleID: String?
  let isSecureInput: Bool
  let accessibilityElement: AXUIElement?
}

enum InjectionStrategy { case accessibility, keyEvents, paste }

struct DictationSettings: Codable, Equatable {
  var engine: EngineChoice              // apple, assemblyAIRealtime
  var trigger: TriggerKey               // fn/globe by default, configurable
  var activation: ActivationMode        // hold or toggle
  var polishEnabled: Bool
  var polishModelID: String?
}
```

Required responsibilities:

- `DictationController` (`@MainActor`, `Observable`/`ObservableObject`) owns the state machine, permission gate, current session, settings, status text, and wiring. It starts capture on the accepted hotkey transition, stops on release/toggle, finalizes once, formats, then injects.
- `HotkeyMonitor` owns a listen-only `CGEventTap` and emits configured key-down/key-up or Fn `flagsChanged` transitions. It must disable/re-enable a tap when macOS reports a timeout and must expose a clear unavailable state when Input Monitoring is absent.
- `MicCapture` owns `AVAudioEngine`, requests record permission, converts microphone input to 16 kHz mono PCM, and sends buffers only between `start()` and `stop()`.
- `SpeechStream` is the engine seam. `AppleSpeechStream` uses the macOS 26 Speech framework's `SpeechAnalyzer`/`SpeechTranscriber` on-device path. `AssemblyAIRealtimeStream` uses `URLSessionWebSocketTask` with 16 kHz PCM and the API key from `ApiKeyStore`; it maps provider partial/final messages to `Hypothesis`.
- `Formatter` exposes `applyRules(_:) -> String` and `polish(_:) async throws -> String`. Rules are deterministic and unit-testable. Polish is called only after a final hypothesis and only when enabled.
- `TextInjector` captures the focused target immediately before injection, refuses secure/password targets, consults a per-bundle override table, and executes AX → CGEvent → paste fallback. Paste must save and restore the complete general pasteboard, including declared types and data, in a `defer` path.
- `PermissionsCoordinator` checks `AXIsProcessTrustedWithOptions`, `CGPreflightListenEventAccess`/`CGRequestListenEventAccess`, and microphone authorization. It exposes individual statuses, opens the appropriate System Settings URLs, and never reports “ready” until all three required grants are present.
- Extend `NotaSettingsStore.swift` with Swift-only dictation preference accessors backed by a dedicated `UserDefaults` key. Existing model settings continue using their current file/schema path; dictation accessors must not call the CLI JSON writer.

## 5. Phased PRs

### P1 — Residency + hotkey + capture

Touch only the app shell/build metadata plus new `macos/Nota/Dictation/` files. Add the `MenuBarExtra`, agent-style runtime behavior, “Open Nota” action, `HotkeyMonitor`, `MicCapture`, `PermissionsCoordinator`, and first-run onboarding. Use Fn/Globe hold-to-talk as the documented default. P1 need not recognize or inject text; it must show listening state and capture diagnostics.

Acceptance criteria:

- Launching Nota leaves a menu-bar status item available without requiring the document window to stay open; “Open Nota” restores the existing document window and file workflow.
- The default Fn/Globe hold transition starts and stops one capture session, with no capture while idle; the status item visibly distinguishes idle/listening/permission-blocked.
- Onboarding shows separate Accessibility, Input Monitoring, and Microphone rows, their current states, and working “Open Settings” actions. Missing any one disables the feature with a specific reason.
- The app target remains non-sandboxed for the dictation distribution path; the existing sandboxed share extension is not casually broadened.
- Existing macOS build and document-window behavior are unchanged.

### P2 — Apple engine, paste-only injection

Add `SpeechStream`, `AppleSpeechStream`, `TextInjector`, and controller wiring. Use on-device Apple Speech as the only engine in this PR. Keep injection deliberately paste-only: save the general pasteboard, put the final string on it, synthesize Cmd-V, restore the prior pasteboard in `defer`, and report failures without crashing.

Acceptance criteria:

- Hold → speak → release produces a final hypothesis and pastes it into TextEdit and a Chrome address bar.
- Partial hypotheses are visible only in diagnostic/status state; no text is injected before release.
- The caller’s clipboard contents and declared types are restored after success and after injection failure.
- The controller records a timestamped hold-release-to-inject latency for each completed session.
- If Apple Speech is unavailable or authorization is denied, the UI reports the exact reason and does not silently switch to AssemblyAI.

### P3 — Hybrid injection

Add AX and CGEvent strategies to `TextInjector`, focused-element inspection, the per-bundle strategy table, and secure-field refusal. The default chain is Accessibility value/insert → CGEvent keystrokes → paste; an override may force a later strategy for a known bundle. Keep the strategy selector pure enough to unit-test.

Acceptance criteria:

- A sentence can be injected into TextEdit, Chrome address bar and web textarea, Slack, Terminal, and VS Code.
- The resolved strategy and fallback reason are logged per bundle ID; the table is documented in code/tests.
- Password/secure fields and unavailable AX targets are refused safely, with no clipboard mutation and a user-visible nonfatal notice.
- P2 paste behavior, clipboard restoration, final-on-release semantics, and latency logging remain intact.
- The release artifact is explicitly identified as requiring the non-sandboxed notarized distribution path for system-wide injection.

### P4 — Formatting + settings + polish

Add `Formatter`, `DictationSettings`, Swift-only persistence, the settings UI, toggle activation, and optional LLM polish. Local rules always run: normalize whitespace, capitalize the first word, remove standalone “um”, “uh”, and “you know”, perform basic false-start cleanup, and add terminal punctuation only when absent. Polish runs after rules and before injection, using a selected existing summary model/key. If the key, network, or model call fails, inject the rules-only result and show a warning.

Acceptance criteria:

- Raw recognition, rules-only output, and polished output are distinguishable in diagnostics/tests; rules output is available even with no API key.
- Hold and toggle modes both work; trigger choice, activation mode, engine choice, polish toggle, and polish model persist through `NotaSettingsStore` without changing `~/.nota/settings.json`.
- Model choices are limited to existing summary entries in `ModelRegistry`; secrets are read through `ApiKeyStore` and never displayed or newly serialized.
- The settings UI explains that polish may send final text to the selected provider and that local rules are the offline fallback.
- Existing settings tabs and batch model settings continue to work.

### P5 — AssemblyAI realtime

Implement `AssemblyAIRealtimeStream` behind `SpeechStream`. Use the existing AssemblyAI key plumbing, open/close one WebSocket per dictation session, send 16 kHz mono PCM, map partial/final events, handle provider errors and close codes, and never modify `src/pipeline/assemblyai.ts` or the CLI AssemblyAI path. Add the engine picker integration and a clear offline/provider-error status.

Acceptance criteria:

- Switching between Apple and AssemblyAI realtime in settings changes only the `SpeechStream` implementation; capture, formatting, injection, permissions, and state transitions are shared.
- Each engine produces equivalent final-hypothesis handoff behavior for the same controller session, including release, cancellation, and error paths.
- Missing `ASSEMBLYAI_API_KEY`, network loss, malformed provider messages, and WebSocket closure fail visibly and do not inject stale text.
- Apple remains the default; AssemblyAI realtime is opt-in and does not affect existing batch AssemblyAI behavior.

## 6. Entitlements, permissions, and distribution

- Add `NSMicrophoneUsageDescription` to the main app `Info.plist`. Add `NSSpeechRecognitionUsageDescription` for Apple Speech authorization copy.
- Accessibility and Input Monitoring are runtime privacy grants, not entitlements. Use `AXIsProcessTrustedWithOptions` for Accessibility and the CGEvent listen-access checks for Input Monitoring. Guide the user to Privacy & Security panes; do not pretend the app can silently grant either permission.
- Microphone authorization must be requested before capture. The onboarding must show all three permissions together because the feature is dead when any required grant is missing.
- The main dictation app target must not carry `com.apple.security.app-sandbox`. The existing `NotaShare` extension may remain sandboxed with its current extension entitlements; verify the nested bundle and notarization instead of removing its required sandbox.
- The production injection artifact must be Developer ID signed, hardened-runtime compatible, notarized, and stapled for direct download. The current ad-hoc development build is not evidence that system-wide AX/CGEvent injection will work in distribution.
- Keep the existing document/share workflows working in both development and distribution builds; if a release configuration cannot support both, stop and report the distribution blocker instead of weakening the permission model.

## 7. Non-goals

- No changes to the TypeScript CLI, `src/**`, batch transcription/diarization/summarization, `src/registry.ts`, or `~/.nota/settings.json`.
- No CLI `dictate` command, background daemon, helper process, iOS target, or second macOS app.
- No partial-text “type as you speak” UX in v1; final-on-release is the contract.
- No speaker diarization, recurring-speaker enrollment, transcript history record, or markdown output for dictation sessions.
- No automatic cloud fallback when Apple Speech fails; the user selects AssemblyAI realtime explicitly.
- No arbitrary per-app scripting or accessibility bypasses beyond the three documented injection strategies and the small bundle override table.

## 8. Per-phase verification matrix

| Phase | Automated/unit verification | Manual verification | Required evidence |
|---|---|---|---|
| P1 | `xcodebuild` build; pure permission/state tests; existing macOS smoke test | Launch with no document window; open document window; exercise each permission missing/present; hold/release Fn/Globe; verify no idle capture | Three permission states, menu-bar residency, capture start/stop logs, no document regression |
| P2 | `xcodebuild` build; `SpeechStream` state tests; pasteboard save/restore tests | TextEdit and Chrome address bar; Apple Speech denied/offline; release with empty speech; success and injected-error clipboard checks | Final-only injection, restored clipboard, provider/authorization error, timestamped latency per session |
| P3 | Strategy table tests; secure-target refusal tests; fallback-order tests; `xcodebuild` build | TextEdit, Chrome address bar/web textarea, Slack, Terminal, VS Code, password field | Bundle-to-strategy table, fallback reasons, secure-field no-op, clipboard integrity, latency |
| P4 | Formatter rule tests; settings round-trip tests; polish fallback tests; `xcodebuild` build | Hold and toggle modes; settings relaunch; raw/rules/polish cases; no-key/network polish failure | No CLI JSON changes, persisted Swift settings, rules-only fallback, privacy copy, latency |
| P5 | WebSocket message mapping/close/error tests; engine-factory tests; `xcodebuild` build | Apple/AssemblyAI switch; normal release; cancellation; missing key; network drop; repeat across target apps | Shared controller behavior, no stale injection, explicit opt-in cloud engine, batch pipeline untouched |

For every phase, run the existing relevant macOS smoke/build checks and inspect `git diff` to confirm no forbidden CLI/pipeline files changed. Record hold-release-to-inject latency as a timestamped delta (p50/p95 once enough sessions exist); the spec requires measurement, not a fabricated threshold. Review the phase PR before merging and keep rollback available via a feature flag that disables the menu-bar dictation mode and returns Nota to its document-only behavior.
