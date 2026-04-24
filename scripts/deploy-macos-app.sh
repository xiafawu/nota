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
npm run build:macos

if [ ! -d "$BUILD_APP" ]; then
  echo "Build did not produce $BUILD_APP" >&2
  exit 1
fi

mkdir -p "$DEPLOY_DIR"

if [ -d "$DEST_APP" ]; then
  rm -rf "$DEST_APP"
fi

ditto "$BUILD_APP" "$DEST_APP"

if command -v codesign >/dev/null 2>&1; then
  codesign --verify --deep --strict "$DEST_APP"
fi

if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$DEST_APP" || true
fi

if [ "${NOTA_SKIP_APP_SMOKE:-0}" != "1" ]; then
  SMOKE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nota-app-smoke.XXXXXX")"
  smoke_input="$SMOKE_DIR/smoke.m4a"
  smoke_output="$SMOKE_DIR/smoke.summary.md"
  printf 'nota app smoke input\n' > "$smoke_input"
  NOTA_APP_RUNNER_SMOKE=1 NOTA_OUTPUT_DIR="$SMOKE_DIR/output" "$DEST_APP/Contents/MacOS/Nota" \
    --smoke-test "$smoke_input" \
    --smoke-output "$smoke_output"
  grep -q '# Nota App Smoke Test' "$smoke_output"
fi

if [ "${NOTA_OPEN_AFTER_DEPLOY:-1}" = "1" ]; then
  open "$DEST_APP" || true
fi

echo "Deployed $DEST_APP"
