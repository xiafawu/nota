#!/bin/bash
# Build and install Nota.app into /Applications by default.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Nota"
BUILD_APP="$PROJECT_DIR/.build/macos-app/$APP_NAME.app"
DEPLOY_DIR="${NOTA_DEPLOY_DIR:-/Applications}"
DEST_APP="$DEPLOY_DIR/$APP_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
SMOKE_DIR=""

cleanup() {
  if [ -n "$SMOKE_DIR" ] && [ -d "$SMOKE_DIR" ]; then
    rm -rf "$SMOKE_DIR"
  fi
}

trap cleanup EXIT

cd "$PROJECT_DIR"

npm run build
# Deploys always ship Release. Debug builds emit a stub executable that loads
# @rpath/Nota.debug.dylib, which breaks the linkage assertions below and is
# not what testers should be running from /Applications.
NOTA_BUILD_CONFIG=release npm run build:macos

if [ ! -d "$BUILD_APP" ]; then
  echo "Build did not produce $BUILD_APP" >&2
  exit 1
fi

# Liquid Glass linkage assertions (#13) — checked on the build product BEFORE
# touching /Applications, so a failed check never leaves a stale bundle there.
MIN_OS="$(defaults read "$BUILD_APP/Contents/Info.plist" LSMinimumSystemVersion)"
if [ "$MIN_OS" != "26.0" ]; then
  echo "Liquid Glass check failed: LSMinimumSystemVersion=$MIN_OS (expected 26.0)" >&2
  exit 1
fi

# SwiftUI linkage lives in the main executable for Release builds; Xcode 26
# Debug builds emit a stub that links @rpath/Nota.debug.dylib and carry the
# SwiftUI linkage there instead.
swiftui_linked() {
  local exe="$1/Contents/MacOS/$APP_NAME"
  otool -L "$exe" | grep -q SwiftUI.framework && return 0
  local dylib
  dylib="$(otool -L "$exe" | awk -v app="$APP_NAME" '$1 ~ "@rpath/" app "\\.debug\\.dylib" {print $1; exit}')"
  dylib="${dylib#@rpath/}"
  [ -n "$dylib" ] && [ -f "$1/Contents/MacOS/$dylib" ] &&
    otool -L "$1/Contents/MacOS/$dylib" | grep -q SwiftUI.framework
}

if ! swiftui_linked "$BUILD_APP"; then
  echo "Liquid Glass check failed: SwiftUI.framework not linked" >&2
  exit 1
fi

# Smoke-test the build product before deploying for the same reason.
if [ "${NOTA_SKIP_APP_SMOKE:-0}" != "1" ]; then
  SMOKE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nota-app-smoke.XXXXXX")"
  smoke_input="$SMOKE_DIR/smoke.m4a"
  smoke_output="$SMOKE_DIR/smoke.summary.md"
  printf 'nota app smoke input\n' > "$smoke_input"
  NOTA_APP_RUNNER_SMOKE=1 NOTA_OUTPUT_DIR="$SMOKE_DIR/output" "$BUILD_APP/Contents/MacOS/$APP_NAME" \
    --smoke-test "$smoke_input" \
    --smoke-output "$smoke_output"
  grep -q '# Nota App Smoke Test' "$smoke_output"
fi

mkdir -p "$DEPLOY_DIR"

# Share-staging inbox. The share extension is sandboxed and its entitlement
# grants ~/.nota/inbox only — NOT ~/.nota, which would expose the API-key file
# (~/.nota/config) and speakers.json to a sandboxed process. That means the
# extension cannot create the intermediate ~/.nota itself, so on a machine that
# has never written Nota state the first share would fail with EACCES. The app
# also does this at launch (AppDelegate.ensureShareInboxExists), but the
# extension can run before the app has ever been launched.
mkdir -p "$HOME/.nota/inbox"

# Kill any running Nota process so the new binary actually loads on relaunch.
# `open` alone just raises an already-running window without reloading the
# executable, which masks source changes from testers and review loops.
if pgrep -f "$DEST_APP/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
  pkill -f "$DEST_APP/Contents/MacOS/$APP_NAME" || true
  # Wait up to 3s for graceful exit before overwriting the bundle.
  for _ in 1 2 3; do
    pgrep -f "$DEST_APP/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 || break
    sleep 1
  done
fi

if [ -d "$DEST_APP" ]; then
  rm -rf "$DEST_APP"
fi

ditto "$BUILD_APP" "$DEST_APP"

# Re-sign with a STABLE identity so macOS TCC grants (Accessibility, Input
# Monitoring) survive redeploys. xcodebuild ad-hoc signs with no stable
# Designated Requirement, so every rebuild changes the cdhash and silently
# invalidates the Accessibility grant (toggle stays ON but app reads "not
# granted"). See scripts/create-signing-cert.sh. Override with NOTA_SIGN_ID.
SIGN_ID="${NOTA_SIGN_ID:-Nota Local Signing}"
if command -v codesign >/dev/null 2>&1; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
    # Sign inner code first, preserving each nested bundle's entitlements, then the outer app.
    # NEVER use --deep here: it re-signs NotaShare.appex with NO entitlements, which strips
    # app-sandbox and makes pkd reject the extension ("plug-ins must be sandboxed").
    codesign --force --sign "$SIGN_ID" \
      --entitlements "$PROJECT_DIR/macos/NotaShare/NotaShare.entitlements" \
      "$DEST_APP/Contents/PlugIns/NotaShare.appex"
    codesign --force --sign "$SIGN_ID" "$DEST_APP"
    codesign --verify --deep --strict "$DEST_APP"
    echo "Signed with stable identity: \"$SIGN_ID\""
  else
    echo "WARNING: stable signing identity \"$SIGN_ID\" not found — leaving the" >&2
    echo "         ad-hoc signature in place. Accessibility/Input Monitoring grants" >&2
    echo "         will NOT persist across redeploys. Run scripts/create-signing-cert.sh once." >&2
    codesign --verify --deep --strict "$DEST_APP" || true
  fi
fi

# Fail the deploy if the extension ended up unsandboxed — pkd refuses to register an
# unsandboxed plug-in, and the share sheet then silently falls back to a DerivedData
# build, so every share test would exercise a stale binary. The actual culprit was
# `--deep` in the signed branch above, which re-signed the appex with no entitlements;
# the ad-hoc `else` path re-signs nothing, so the appex keeps xcodebuild's signature
# (made with CODE_SIGN_ENTITLEMENTS, hence sandboxed). This check sits outside the
# whole if/else as defense in depth: it holds for any future signing path, including
# ones that do touch the appex.
#
# Remove the bundle before failing: `ditto` above already replaced $DEST_APP, so
# exiting here would otherwise leave a freshly-installed broken app in place.
if [ -d "$DEST_APP/Contents/PlugIns/NotaShare.appex" ]; then
  codesign -d --entitlements - "$DEST_APP/Contents/PlugIns/NotaShare.appex" 2>&1 \
    | grep -q "com.apple.security.app-sandbox" || {
      echo "ERROR: NotaShare.appex has no sandbox entitlement — pkd will reject it." >&2
      rm -rf "$DEST_APP"
      exit 1
    }
fi

if [ -x "$LSREGISTER" ]; then
  # Deregister every OTHER bundle sharing this bundle id before registering the
  # deployed one. Xcode/xcodebuild register each build product (Debug, Release,
  # worktree, DerivedData copies) under com.xiafawu.nota; LaunchServices can then
  # resolve `open`/Spotlight/`open -b` to an ad-hoc build-dir copy instead of
  # this one. Because those copies are ad-hoc, macOS TCC grants (Accessibility,
  # Input Monitoring) reset every relaunch. Keep exactly one registered bundle.
  "$LSREGISTER" -dump 2>/dev/null \
    | grep -iE "path:.*Nota\.app \(" \
    | sed -E 's/.*path: *//; s/ \(0x.*//' \
    | grep -v "appex" | sort -u \
    | while read -r other; do
        [ "$other" = "$DEST_APP" ] && continue
        "$LSREGISTER" -u "$other" 2>/dev/null || true
      done
  "$LSREGISTER" -f "$DEST_APP" || true
fi

if [ "${NOTA_OPEN_AFTER_DEPLOY:-1}" = "1" ]; then
  # Launch by full path (not `open -b <id>`) so we run the deployed bundle even
  # if a build-dir copy re-registers later.
  open "$DEST_APP" || true
fi

echo "Deployed $DEST_APP"
