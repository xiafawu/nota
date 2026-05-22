#!/bin/bash
# Build a local Nota.app bundle from the lightweight SwiftUI sources.

set -euo pipefail

XCODE_VERSION="$(xcodebuild -version | awk 'NR==1{ver=$2} END{print ver}')"
if [[ ! "$XCODE_VERSION" =~ ^26 ]]; then
  echo "Error: Xcode 26+ required (found: $XCODE_VERSION)"
  exit 1
fi

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Nota"
BUILD_DIR="$PROJECT_DIR/.build/macos-app"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
MODULE_CACHE_DIR="$BUILD_DIR/ModuleCache"
PLUGINS_DIR="$CONTENTS_DIR/PlugIns"
SHARE_APP_EXTENSION_DIR="$PLUGINS_DIR/NotaShare.appex"
SHARE_CONTENTS_DIR="$SHARE_APP_EXTENSION_DIR/Contents"
SHARE_MACOS_DIR="$SHARE_CONTENTS_DIR/MacOS"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$MODULE_CACHE_DIR" "$SHARE_MACOS_DIR"

NOTA_SOURCES=()
while IFS= read -r -d '' file; do
  NOTA_SOURCES+=("$file")
done < <(find "$PROJECT_DIR/macos/Nota" -type f -name "*.swift" -print0 | sort -z)

if [ "${#NOTA_SOURCES[@]}" -eq 0 ]; then
  echo "No Swift sources found under $PROJECT_DIR/macos/Nota" >&2
  exit 1
fi

NOTA_BUILD_CONFIG="${NOTA_BUILD_CONFIG:-debug}"
NOTA_SWIFT_FLAGS=()
case "$NOTA_BUILD_CONFIG" in
  debug)
    NOTA_SWIFT_FLAGS+=("-D" "DEBUG" "-Onone")
    ;;
  release)
    NOTA_SWIFT_FLAGS+=("-O")
    ;;
  *)
    echo "Unknown NOTA_BUILD_CONFIG: $NOTA_BUILD_CONFIG (expected debug|release)" >&2
    exit 1
    ;;
esac

swiftc \
  -target arm64-apple-macosx26.0 \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -parse-as-library \
  -framework SwiftUI \
  -framework AppKit \
  -framework UniformTypeIdentifiers \
  "${NOTA_SWIFT_FLAGS[@]}" \
  "${NOTA_SOURCES[@]}" \
  -o "$MACOS_DIR/$APP_NAME"

cp "$PROJECT_DIR/macos/Nota/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/macos/Nota/Assets/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"
chmod +x "$MACOS_DIR/$APP_NAME"

# Build the share extension as a real executable (MH_EXECUTE), NOT a dylib.
# A .appex is exec'd as its own process by pkd, and — critically — codesign
# silently ignores --entitlements on a dylib, so an `-emit-library` build can
# never carry the App Sandbox entitlement pkd requires. The entry point is
# _NSExtensionMain (from Foundation), which reads Info.plist and instantiates
# NSExtensionPrincipalClass.
swiftc \
  -target arm64-apple-macosx26.0 \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -parse-as-library \
  -module-name NotaShare \
  -framework Foundation \
  -framework AppKit \
  -framework UniformTypeIdentifiers \
  -Xlinker -e -Xlinker _NSExtensionMain \
  "$PROJECT_DIR/macos/NotaShare/ShareViewController.swift" \
  -o "$SHARE_MACOS_DIR/NotaShare"

cp "$PROJECT_DIR/macos/NotaShare/Info.plist" "$SHARE_CONTENTS_DIR/Info.plist"
chmod +x "$SHARE_MACOS_DIR/NotaShare"

if command -v codesign >/dev/null 2>&1; then
  # Sign the extension FIRST, WITH its sandbox entitlements. Do not use --deep:
  # signing the outer app with --deep would re-sign (and strip the entitlements
  # off) the nested .appex. Failures must abort the build, not be swallowed.
  codesign --force --sign - \
    --entitlements "$PROJECT_DIR/macos/NotaShare/NotaShare.entitlements" \
    "$SHARE_APP_EXTENSION_DIR"
  # Re-seal the app bundle (no --deep) so it embeds the already-signed,
  # entitled extension without re-signing it.
  codesign --force --sign - "$APP_DIR"
fi

echo "$APP_DIR"
