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
    # Sign inner code (frameworks, NotaShare.appex) then the outer app.
    codesign --force --deep --sign "$SIGN_ID" "$DEST_APP"
    codesign --verify --deep --strict "$DEST_APP"
    echo "Signed with stable identity: \"$SIGN_ID\""
  else
    echo "WARNING: stable signing identity \"$SIGN_ID\" not found — leaving the" >&2
    echo "         ad-hoc signature in place. Accessibility/Input Monitoring grants" >&2
    echo "         will NOT persist across redeploys. Run scripts/create-signing-cert.sh once." >&2
    codesign --verify --deep --strict "$DEST_APP" || true
  fi
fi

if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$DEST_APP" || true
fi

if [ "${NOTA_OPEN_AFTER_DEPLOY:-1}" = "1" ]; then
  open "$DEST_APP" || true
fi

echo "Deployed $DEST_APP"
