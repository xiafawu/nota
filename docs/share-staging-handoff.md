# Handoff — fix share-extension staging (Voice Memos → Nota "Could not copy audio")

Status: LANDED — commits `d835bdc` + `cb14e36` (staging fix), `91d583d` (visible-error follow-up).
Kept as the historical record of the diagnosis, security constraints, and review trail.
Agents: do NOT load this file for new work — the living rules are in `docs/macos-app.md`,
the entitlements comments, and `scripts/deploy-macos-app.sh`.
Repo: `/Users/xiafawu/Developer/Nota`, branch `master`.

## 1. The bug (proven, not suspected)

Sharing a Voice Memo to Nota fails in the host app with:

```
".nota-share-1784993316-FC3EF629-62AD-46FF-B719-1B33E4A244DE.qta" couldn't be copied
because you don't have permission to access "Nota".
```

Evidence chain (macOS unified log, 2026-07-25 08:28:36, and again at 00:31:23):

```
Nota: (libcopyfile.dylib) open on /Users/xiafawu/Library/Containers/com.xiafawu.nota.share/
  Data/Documents/Nota/.nota-share-1784993316-FC3EF629-62AD-46FF-B719-1B33E4A244DE.qta:
  Operation not permitted
sandboxd: [com.apple.sandbox:sandcastle] TCC denied kTCCServiceSystemPolicyAppDataDetailed
```

Mechanism:

```text
NotaShare.appex (SANDBOXED)              Nota.app (UNSANDBOXED host)
  copyForNota()                            makeStableInputCopy()
  homeDirectoryForCurrentUser              copyItem(at: staged, to: outputDirectory)
    = ~/Library/Containers/                          |
      com.xiafawu.nota.share/Data                    |
        /Documents/Nota/.nota-share-*.qta  <---------+  open() -> EPERM
                                             TCC kTCCServiceSystemPolicyAppDataDetailed
                                             blocks reads of ANOTHER app's container
```

Two independent mistakes meet here:

1. `FileManager.default.homeDirectoryForCurrentUser` inside an App-Sandboxed process
   returns the **container** `Data` dir, not `/Users/<me>`. So the staged copy lands in the
   extension's private container.
2. The entitlement `com.apple.security.temporary-exception.files.home-relative-path.read-write
   = /Documents/Nota/` was written for the **real** home. It is currently dead — nothing in the
   code ever builds a real-home path, so the exception is never exercised.

Confirmation that the error string comes from the *source* side (not a write failure on the
output dir): a standalone Swift repro copying that exact container path into a freshly created,
writable dir named `Nota` reproduces the message verbatim, UUID included. `~/Documents/Nota` is
`drwxr-xr-x`, no ACLs, and the host writes summaries into it fine.

Not a regression from a specific commit — the share path has never worked on this machine.
The successful summary at 00:34 today came from a manual re-import 49 s after the failed share.

## 2. The fix (option C): stage outside every TCC-protected directory

Move staging from the extension container to `~/.nota/inbox/` (real home), reached via
`getpwuid`, and grant it with a home-relative sandbox exception.

Why `~/.nota/inbox` and not the alternatives:

| Destination | Verdict |
|---|---|
| extension container (today) | host read is TCC-blocked — the bug |
| `~/Documents/Nota` | still TCC-gated (`SystemPolicyDocumentsFolder`); log shows this path runs with `user interaction not allowed`, so a prompt can't rescue it |
| `/private/tmp/nota-share` | works, but meeting audio in a world-readable dir |
| **`~/.nota/inbox`** | TCC protects Desktop/Documents/Downloads/Containers/Group Containers — a home dotdir is on none of those lists; already Nota's own state dir (`~/.nota/history`, `~/.nota/speakers.json`) |

### 2a. `macos/NotaShare/ShareViewController.swift`

Add a real-home helper and route both staging functions through it. The helper **fails loudly**
rather than falling back to `homeDirectoryForCurrentUser` — that fallback is precisely the
container path that causes this bug, so a silent fallback would resurrect it invisibly.

```swift
/// App Sandbox maps `homeDirectoryForCurrentUser` to the extension's container
/// (~/Library/Containers/<id>/Data). The `home-relative-path` entitlement exception,
/// however, is scoped against the REAL home — so staging must resolve the real home
/// explicitly or the exception is never exercised and the host cannot read the file
/// (TCC kTCCServiceSystemPolicyAppDataDetailed blocks cross-container reads).
/// Deliberately no fallback to homeDirectoryForCurrentUser: that value IS the broken
/// container path, and staging there fails later, in the host, with an opaque message.
private func realHomeDirectory() throws -> URL {
  guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else {
    throw ShareError.noHomeDirectory
  }
  return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
}

private func stagingDirectory() throws -> URL {
  try realHomeDirectory()
    .appendingPathComponent(".nota", isDirectory: true)
    .appendingPathComponent("inbox", isDirectory: true)
}
```

- Add `case noHomeDirectory` to the `ShareError` enum at the bottom of the file with an
  `errorDescription` like `"Could not resolve your home directory."` — it surfaces through the
  existing `finish(with:error:)` path.
- `copyForNota(_:)` (currently line ~143): replace the `homeDirectoryForCurrentUser
  → Documents → Nota` chain with `try stagingDirectory()`. Keep the existing
  `.nota-share-<epoch>-<uuid>.<ext>` naming and the `createDirectory` call. It already `throws`.
- `pruneStaleStagedFiles()` (currently line ~162): same directory swap. It is best-effort and
  non-throwing — `guard let directory = try? stagingDirectory() else { return }` is fine here.
  Update its doc comment: it no longer describes a container.
- `getpwuid`/`getuid` need `import Darwin` if `import Foundation` alone doesn't resolve them.

### 2b. `macos/NotaShare/NotaShare.entitlements`

```xml
<key>com.apple.security.temporary-exception.files.home-relative-path.read-write</key>
<array>
  <string>/.nota/inbox/</string>
</array>
```

Replaces `/Documents/Nota/`. Keep `app-sandbox` and `files.user-selected.read-only` as-is —
`user-selected.read-only` is what lets the extension read the shared Voice Memo.
**Also rewrite the XML comment above that key** (currently lines 11–16): it still says staging
targets `~/Documents/Nota` "so the host app can pick it up", which becomes false.

### 2c. `macos/Nota/App/NotaModel.swift` — delete the staged file after import

Why the existing cleanup misses it: `accept(_:)` stores the stable copy in `selectedURL` and the
staged source in `originalSelectedURL` (lines ~223–224), and `transcribe()` passes **only**
`selectedURL` into `runNota` (lines ~238–251). The `shouldRemoveSharedInput` reaper at line ~438
therefore evaluates the stable copy and never sees the staged file at all — it is not a
parent-directory mismatch, the staged URL simply never reaches that code.

Add a shared inbox helper in `macos/Nota/App/Helpers.swift`, next to `notaHistoryDirectory()`
(the host is unsandboxed, so `homeDirectoryForCurrentUser` is already the real home there):

```swift
func notaInboxDirectory() -> URL {
  FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".nota", isDirectory: true)
    .appendingPathComponent("inbox", isDirectory: true)
}
```

(The extension cannot use this — separate target, `NotaShare/` sources only — so §2a keeps its
own copy. Cross-reference them in comments so they don't drift.)

Then, after a successful `makeStableInputCopy` in `accept(_:)`:

```swift
// Staged shares live in ~/.nota/inbox and never reach runNota's reaper (that one only
// sees the stable copy). Drop the staged file here so the inbox doesn't accumulate
// ~78 MB per share. Both conditions matter: `resolveSharedURL` will hand back ANY
// absolute path carried in a nota: URL, and a user can drag-drop a file that merely
// happens to be named .nota-share-*, so a prefix check alone would delete user data.
let parent = fileURL.deletingLastPathComponent().standardizedFileURL
if parent == notaInboxDirectory().standardizedFileURL,
   fileURL.lastPathComponent.hasPrefix(".nota-share-") {
  try? FileManager.default.removeItem(at: fileURL)
}
```

Deleting here is safe because `originalSelectedURL` (set to the staged path) is only ever read
for its *name*: `displayURL` → `sanitizedBaseName` (line ~241) and `defaultExportName`
(line ~610). Re-confirm no byte-level read of `originalSelectedURL` exists before relying on it.

Leave `shouldRemoveSharedInput` alone: it still correctly reaps the `.nota-input-` copy that
the CLI consumed.

Also update the stale doc comment on `resolveSharedURL` (line ~561–563), which says the staged
file lives in `~/Documents/Nota`.

Optional hardening, flag it rather than silently adding: `resolveSharedURL` accepts any
`nota:` URL with a `path` query and does not require `host == "import"`. Tightening that is a
one-line guard, but it is a behavior change outside this bug — raise it, don't smuggle it in.

### 2d. `scripts/deploy-macos-app.sh` — separate bug, must ship together

Line 102 is `codesign --force --deep --sign "$SIGN_ID" "$DEST_APP"`. `--deep` re-signs nested
bundles **without entitlements**, so the deployed appex loses `app-sandbox` and macOS refuses it:

```
pkd: rejecting; Ignoring mis-configured plugin at
[/Applications/Nota.app/Contents/PlugIns/NotaShare.appex]: plug-ins must be sandboxed
```

Consequence today: `pluginkit -mvvv -i com.xiafawu.nota.share` resolves the share sheet to
`/Users/xiafawu/Developer/Nota/.build/DerivedData/Build/Products/Debug/Nota.app/…/NotaShare.appex`.
Every share ever tested ran the Debug build; deleting `.build/` removes Nota from the share sheet
entirely. Without this fix, 2a–2c can ship and still appear to change nothing.

Inside the `if security find-identity …` branch (currently lines 100–104), replace the `--deep`
call with inside-out signing:

```sh
# Sign inner code first, preserving each nested bundle's entitlements, then the outer app.
# NEVER use --deep here: it re-signs NotaShare.appex with NO entitlements, which strips
# app-sandbox and makes pkd reject the extension ("plug-ins must be sandboxed").
codesign --force --sign "$SIGN_ID" \
  --entitlements "$PROJECT_DIR/macos/NotaShare/NotaShare.entitlements" \
  "$DEST_APP/Contents/PlugIns/NotaShare.appex"
codesign --force --sign "$SIGN_ID" "$DEST_APP"
codesign --verify --deep --strict "$DEST_APP"
```

`$PROJECT_DIR` is the repo root already defined at line 6 — use it, don't invent a new variable.

Then add the entitlement gate **after the whole `if/else` block closes** (i.e. after line 111),
not inside the signed branch. The `else` branch at lines 105–110 leaves an ad-hoc signature in
place, which is exactly the state that produces an unsandboxed appex — a gate nested in the
`if` would skip the case it exists to catch:

```sh
# Fail the deploy if the extension ended up unsandboxed — otherwise the share sheet
# silently falls back to a DerivedData build and every share test is a lie.
if [ -d "$DEST_APP/Contents/PlugIns/NotaShare.appex" ]; then
  codesign -d --entitlements - "$DEST_APP/Contents/PlugIns/NotaShare.appex" 2>&1 \
    | grep -q "com.apple.security.app-sandbox" || {
      echo "ERROR: NotaShare.appex has no sandbox entitlement — pkd will reject it." >&2
      exit 1
    }
fi
```

### 2e. Docs

- `docs/macos-app.md` (line ~54) is where the **embedded extension** is described — update the
  staging location there.
- `docs/share-sheet.md` documents a *different* path: the Shortcut/Quick Action that calls
  `scripts/nota-share.sh`, which stages as `$OUTPUT_DIR/.nota-input-*` and removes it itself
  (`scripts/nota-share.sh:130–147`). Do **not** add an unqualified "staging is `~/.nota/inbox`"
  claim there. If it is mentioned at all, it goes in a clearly separate section for the appex.
- Check `CLAUDE.md` for staging claims that go stale.

## 3. Verification (all of it, in order)

Resolve overrides first — both are supported and both silently redirect the checks below:
`DEPLOY_DIR="${NOTA_DEPLOY_DIR:-/Applications}"`, `OUT_DIR="${NOTA_OUTPUT_DIR:-$HOME/Documents/Nota}"`.

1. `xcodegen generate --spec macos/project.yml && xcodebuild -project macos/Nota.xcodeproj -scheme Nota build`
2. `bash scripts/deploy-macos-app.sh` — must succeed and pass the new entitlement gate.
3. `codesign -d --entitlements - "$DEPLOY_DIR/Nota.app/Contents/PlugIns/NotaShare.appex"`
   → must print `com.apple.security.app-sandbox` **and** the `/.nota/inbox/` exception.
4. `pluginkit -mvvv -i com.xiafawu.nota.share` → `Path` must now be under `$DEPLOY_DIR/Nota.app`,
   **not** `.build/DerivedData`. If it still points at DerivedData, deregister the stale copy
   (the deploy script already has an `lsregister` block; extend it if the appex needs it).
5. End-to-end: share a short Voice Memo → Nota. Expect the pipeline to start, no error card.
6. ```
   log show --last 5m --info --debug \
     --predicate 'process == "Nota" OR process == "NotaShare" OR process == "sandboxd"' \
     | grep -iE "com\.xiafawu\.nota.*(Operation not permitted)|AppDataDetailed.*xiafawu"
   ```
   → no hits. A bare `grep "Operation not permitted"` catches unrelated processes and fails you
   for someone else's TCC noise.
7. `ls -la ~/.nota/inbox` → empty (or only files < 5 min old) after a completed run.
8. `ls -la "$OUT_DIR"` → new `*.summary.md`, no leftover `.nota-input-*` audio.
9. Both suites — they are disjoint, "either" is not enough:
   `bash macos/NotaTests/run-tests.sh` (speaker + catalog) **and** the `Nota` scheme's
   `NotaDictationTests` + `NotaUITests` via `xcodebuild test`.

Step 5 is the only test that proves the fix; 1–4 are necessary preconditions, and skipping 4
is how you end up testing a stale extension and concluding the fix failed.

## 4. Known risks / open questions for the implementer

- **`~/.nota/inbox` TCC assumption.** The claim "home dotdirs are not TCC-protected" is based on
  TCC's protected set being Desktop/Documents/Downloads/iCloud/Containers/Group Containers.
  If step 5 still logs a TCC denial, fall back to `/private/tmp/nota-share/` with
  `com.apple.security.temporary-exception.files.absolute-path.read-write` and a `0700` dir.
- **Sandbox exception path syntax.** Home-relative exception values are relative to the real
  home and conventionally end with `/`. If the extension gets a sandbox `deny file-write-create`
  on `~/.nota/inbox`, check the log for the exact denied path before changing anything else.
- **First-run ordering.** `~/.nota` exists on this machine, but a clean install may not have it.
  `createDirectory(withIntermediateDirectories: true)` covers it — confirm the sandbox exception
  permits creating `inbox` under an existing `.nota`, and creating `.nota` itself if absent.
- **Capture date.** The audio now travels Voice Memos → `~/.nota/inbox` → output dir. That is the
  same two-hop count as today, but confirm the **Captured** header in the output markdown still
  shows the recording time, not the copy time.
- **Don't repurpose `~/.nota/history`.** Staging is transient; history is durable. Separate dirs.

## 5. Out of scope

- App Groups (the sanctioned cross-container channel) — needs a Team ID; this build is
  self-signed with no team.
- Any change to the `nota://import` URL contract between extension and host (the
  `host == "import"` guard in §2c is a *proposal*, not part of this fix).
- Reworking `sanitizedBaseName` / `.nota-share-` naming: the prefix is load-bearing in
  `Helpers.swift:23` and in the reaper, so keep it.

## 6. Revisions

**r2 — 2026-07-25, after Codex (gpt-5.6-sol, xhigh) read-only review.** 10 findings, all folded in:

- BLOCKER — deletion guard was basename-only. `resolveSharedURL` hands back any absolute path in
  a `nota:` URL and drag-drop can supply a `.nota-share-*` name, so §2c now requires the parent
  to equal `~/.nota/inbox`.
- MAJOR — `realHomeDirectory()` fell back to `homeDirectoryForCurrentUser`, silently restoring
  the bug on `getpwuid` failure. Now throws `ShareError.noHomeDirectory`.
- MAJOR — the signing gate sat inside the signed branch; the missing-identity `else` branch
  (the case that actually produces an unsandboxed appex) skipped it. Gate moved after the block.
- MAJOR — `docs/share-sheet.md` documents the Shortcut/`nota-share.sh` flow, not the appex.
  Doc target corrected to `docs/macos-app.md`.
- MINOR — wrong reason given for the staged file surviving cleanup (the reaper never receives it;
  it is not a parent mismatch); `NOTA_OUTPUT_DIR` / `NOTA_DEPLOY_DIR` overrides ignored in
  verification; `run-tests.sh` and the Xcode scheme are disjoint suites, not alternatives;
  stale comments in `NotaShare.entitlements` and on `resolveSharedURL` added to the edit list;
  log-verification grep narrowed to Nota's own processes.

Codex explicitly did **not** verify (not statically checkable from source): the unified-log
evidence, the standalone repro, current ACLs/permissions, TCC protected-set behavior, the
`--deep`/pkd causality, `pluginkit` registration history, end-to-end share behavior, first-run
directory creation, and capture-date preservation. Those rest on §1's runtime evidence and on
step 5.
