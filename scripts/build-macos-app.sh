#!/bin/bash
# Build a local Nota.app bundle from the SwiftUI sources via XcodeGen + xcodebuild.
#
# The Xcode project is generated from macos/project.yml (not committed); the
# app-extension product type natively produces the MH_EXECUTE / _NSExtensionMain
# setup and embeds/signs NotaShare.appex with its App Sandbox entitlements, so
# no manual linker or codesign hacks are needed here.
#
# Contract preserved for package.json: the LAST stdout line is the .app path,
# placed at .build/macos-app/Nota.app.

set -euo pipefail

XCODE_VERSION="$(xcodebuild -version | awk 'NR==1{ver=$2} END{print ver}')"
if [[ ! "$XCODE_VERSION" =~ ^26 ]]; then
  echo "Error: Xcode 26+ required (found: $XCODE_VERSION)"
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "Error: xcodegen not found in PATH (brew install xcodegen)" >&2
  exit 1
fi

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Nota"
BUILD_DIR="$PROJECT_DIR/.build/macos-app"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
DERIVED_DATA_DIR="$PROJECT_DIR/.build/DerivedData"
SPEC_FILE="$PROJECT_DIR/macos/project.yml"
XCODEPROJ="$PROJECT_DIR/macos/$APP_NAME.xcodeproj"

NOTA_BUILD_CONFIG="${NOTA_BUILD_CONFIG:-debug}"
case "$NOTA_BUILD_CONFIG" in
  debug)   XCODE_CONFIG="Debug" ;;
  release) XCODE_CONFIG="Release" ;;
  *)
    echo "Unknown NOTA_BUILD_CONFIG: $NOTA_BUILD_CONFIG (expected debug|release)" >&2
    exit 1
    ;;
esac

# Regenerate the project from the committed spec (idempotent).
xcodegen generate --spec "$SPEC_FILE" >&2

# Build. All xcodebuild chatter goes to stderr so stdout stays scriptable.
xcodebuild \
  -project "$XCODEPROJ" \
  -scheme "$APP_NAME" \
  -configuration "$XCODE_CONFIG" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  build >&2

BUILT_APP="$DERIVED_DATA_DIR/Build/Products/$XCODE_CONFIG/$APP_NAME.app"
if [ ! -d "$BUILT_APP" ]; then
  echo "Error: expected build product not found at $BUILT_APP" >&2
  exit 1
fi

# Place the built bundle at the historical location.
mkdir -p "$BUILD_DIR"
rm -rf "$APP_DIR"
cp -R "$BUILT_APP" "$APP_DIR"

echo "$APP_DIR"
