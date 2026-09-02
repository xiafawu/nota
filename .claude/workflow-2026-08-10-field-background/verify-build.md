All green on the first run — no source edits were needed.

**Commands run** (all from `/Users/xiafawu/Developer/Nota/macos`):

1. `xcodegen generate --spec project.yml` → `Created project at /Users/xiafawu/Developer/Nota/macos/Nota.xcodeproj`
2. `xcodebuild -list -project Nota.xcodeproj` → targets `Nota`, `NotaDictationTests`, `NotaShare`, `NotaUITests`; schemes `Nota`, `NotaShare`
3. `xcodebuild -project Nota.xcodeproj -scheme Nota -configuration Debug -destination 'platform=macOS' build` → **BUILD SUCCEEDED**
4. `xcodebuild -project Nota.xcodeproj -scheme Nota -configuration Debug -destination 'platform=macOS' -only-testing:NotaUITests/FieldEngineTests -only-testing:NotaUITests/FieldBackgroundTests -only-testing:NotaUITests/RecordingAccentTests -only-testing:NotaUITests/RecordingPaneTests test` → **TEST SUCCEEDED**

**Target ownership:** `project.yml` maps `Nota/UI/Tests` to **NotaUITests** (`NotaDictationTests` owns only `Nota/Dictation/Tests`), so `-only-testing:NotaUITests/…` is the correct prefix — the four classes really executed, not a silent zero.

**Test counts per class** (from the `.xcresult`, not from log scraping):

| Class | Tests | Result |
|---|---|---|
| FieldEngineTests | 15 | Passed |
| FieldBackgroundTests | 15 | Passed |
| RecordingAccentTests | 16 | Passed |
| RecordingPaneTests | 41 | Passed |
| **Total** | **87** | `Executed 87 tests, with 0 failures (0 unexpected) in 219.546 (219.572) seconds` |

**Failures:** none. Nothing red, so there is no first-failure line to quote.

**Notes:**
- `/Applications/Nota.app` was running (pid 1369) throughout. The `-only-testing` scoping avoided the bundle-id wedge; the run completed in ~3.7 min, under the 6-min hang threshold. No process was killed.
- Working tree verified as read-only via `git status` / `git diff --stat`: modified `UI/CraftGlass.swift`, `UI/HomeDashboardView.swift`, `UI/LiveMeetingView.swift`; new untracked `UI/Field/FieldBackground.swift`, `UI/Field/FieldEngine.swift`, `UI/Tests/FieldBackgroundTests.swift`. All were picked up by the XcodeGen directory globs. Nothing committed.