# Nota macOS App

**Requires macOS 26 (Tahoe) or later and Xcode 26+**

The local macOS app is a lightweight SwiftUI shell around the existing Nota CLI pipeline.

## Build

```bash
npm run build
npm run build:macos
```

The app bundle is written to:

```bash
.build/macos-app/Nota.app
```

## Deploy

```bash
npm run deploy:macos
```

By default this installs the app to:

```bash
/Applications/Nota.app
```

Set `NOTA_DEPLOY_DIR` to deploy somewhere else:

```bash
NOTA_DEPLOY_DIR="$HOME/Applications" npm run deploy:macos
```

The deploy script rebuilds the CLI and app, replaces the existing deployed `Nota.app`, verifies the code signature, registers it with LaunchServices, and opens it. Set `NOTA_OPEN_AFTER_DEPLOY=0` to skip opening after deployment.

Deployment also runs a headless app smoke test. The smoke test launches the deployed app executable with `--smoke-test`, copies a disposable `.m4a` file through the same stable handoff path used by drag and drop, invokes `scripts/nota-app-run.sh` in smoke mode, and verifies that markdown output was produced. It uses a temporary `NOTA_OUTPUT_DIR` so the automated check does not depend on macOS Documents-folder privacy prompts. Set `NOTA_SKIP_APP_SMOKE=1` to skip this check.

## Use

- Open `.build/macos-app/Nota.app`.
- Drop an audio file into the window, or use **File > Open Audio...**.
- Nota writes markdown summaries to `~/Documents/Nota` and shows a rich text preview in the app by default.
- Use the **Rich Text / Markdown** switch to choose between the rendered preview and raw markdown.
- Use **Copy** to copy either rich text for Apple Notes or raw markdown.
- Use **Export** to write either rich text (`.rtf`) or markdown (`.md`).
- Use **Reveal** to show the generated summary file in Finder.

The app supports the same audio extensions as the CLI: `.mp3`, `.wav`, `.m4a`, `.aac`, `.caf`, `.aif`, `.aiff`, `.ogg`, `.webm`, `.flac`, `.qta`, `.mov`, and `.mp4`.

The bundle also embeds a thin Share Extension. The extension stages the shared audio file in `~/.nota/inbox`, opens that staged copy in the main app over `nota://import`, and lets the main app run the existing CLI pipeline. The main app makes its own stable copy and then deletes the staged file, so the inbox stays empty between shares.

Staging deliberately does **not** use `~/Documents/Nota` (where summaries are written). The extension is sandboxed, so `homeDirectoryForCurrentUser` resolves to its own container — a copy staged that way lands in `~/Library/Containers/com.xiafawu.nota.share/…`, and TCC (`kTCCServiceSystemPolicyAppDataDetailed`) then blocks the unsandboxed host app from reading it. `~/.nota/inbox` is resolved from the real home via `getpwuid` and is under none of TCC's protected directories (Desktop, Documents, Downloads, iCloud, Containers), so both sides can reach it. The extension's `com.apple.security.temporary-exception.files.home-relative-path.read-write` entitlement is scoped to `/.nota/inbox/` to match — deliberately not `/.nota/`, which would hand a sandboxed process read-write access to the API-key file `~/.nota/config` and to `speakers.json`. Because that exception does not cover the intermediate `~/.nota`, the extension cannot create it: the unsandboxed sides do, at install time (`scripts/deploy-macos-app.sh`) and at every app launch.

## Environment

Finder-launched apps do not reliably inherit shell environment variables. The app calls `scripts/nota-app-run.sh`, which loads:

- `~/.zshenv`
- `~/.zprofile`
- `~/.zshrc`
- `~/.bash_profile`

Put `OPENAI_API_KEY`, `ASSEMBLYAI_API_KEY`, `HUGGINGFACE_TOKEN`, and `PYTHON_BIN` exports in one of those files. `PYTHON_BIN` defaults to `python3.11`.

## Share Sheet

To make the extension visible to LaunchServices, deploy the app:

```bash
npm run deploy:macos
```

Voice Memos should then be able to share an audio file to Nota. Finder can also open supported audio files with Nota.
