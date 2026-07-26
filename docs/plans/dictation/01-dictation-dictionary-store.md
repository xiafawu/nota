# dictation-dictionary-store

## Goal
Shared custom-vocabulary store at `~/.nota/dictionary.json`, editable from CLI and Swift.

## Schema (v1)
`{ "version": 1, "terms": [ { "term": "genc2rust", "spokenForms": ["gency to rust"],
"source": "manual"|"learned"|"harvested", "starred": false, "addedAt": "<ISO>" } ] }`
- `term` unique case-insensitive; `spokenForms` optional; `starred` terms win the L1 100-cap cut.

## Changes
- Swift: `macos/Nota/Dictation/DictionaryStore.swift` — load/save/add/remove/star,
  case-insensitive dedupe, atomic write like `ApiKeyStore.writeFileMap`
  (`macos/Nota/App/ApiKeyStore.swift:108`). Corrupt/missing file → warn + empty, never crash.
- TS: `src/cli/dictionary.ts` mimicking `src/cli/settings.ts` (stdout rows, stderr headers,
  injectable path); verb group in `src/index.ts` after the speakers pattern (`index.ts:268`):
  `nota dictionary add <term> [--spoken <form>] [--star] | list | remove <term>`.
- Tests: `macos/Nota/Dictation/Tests/DictionaryStoreTests.swift`; `tests/cli/dictionary.test.ts`.

## Non-goals
No UI, no harvesting, no polish integration — later plans consume this store.

## Execution
Implementer: Claude Opus 5 (owner-selected) via Workflow agent, isolation=worktree,
never commits master. Verify: `npm test`; `xcodegen generate --spec macos/project.yml`
then `xcodebuild test -project macos/Nota.xcodeproj -scheme Nota`.
