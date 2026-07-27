# dictation-dictionary-tab

## Goal
Promote the dictionary from a section inside the Dictation tab to its own Settings
tab, with bulk import so the owner can paste a word list to bias recognition.

## Changes
- `macos/Nota/UI/SettingsView.swift`: new `SettingsTab.dictionary` case (+idealHeight,
  +tabItem, label "Dictionary", SF Symbol `character.book.closed`).
- NEW `macos/Nota/UI/DictionarySettingsView.swift`: move + expand the existing
  `dictionarySection` UI from `DictationSettingsView` —
  - list of terms: term, spoken forms, source badge, star toggle, remove;
  - single-add row (term + optional "sounds like");
  - **Bulk import**: button → sheet with a TextEditor, "one term per line, optionally
    `term | spoken form`", imports via DictionaryStore merge semantics (case-insensitive
    dedupe, spokenForms union), reports added/merged counts;
  - footer: term count + path (`~/.nota/dictionary.json`) + note that `nota dictionary`
    CLI edits the same file.
- `DictationSettingsView`: remove the inline section; leave a "Manage Dictionary…"
  hint pointing at the new tab.
- Reuse the existing `DictionaryModel` (@MainActor write-through) — move, don't fork.
- Tests: bulk-import parsing (blank lines, whitespace, `|` form, duplicates) as pure
  functions; existing DictionaryStore tests stay authoritative for merge semantics.

## Execution
Implementer: Claude Opus 5 via Workflow agent, isolation=worktree (lane A).
Verify: xcodegen generate; xcodebuild test.
