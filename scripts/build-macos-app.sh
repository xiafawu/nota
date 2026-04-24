#!/bin/bash
# Build a local Nota.app bundle from the lightweight SwiftUI sources.

set -euo pipefail

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

swiftc \
  -target arm64-apple-macosx14.0 \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -parse-as-library \
  -framework SwiftUI \
  -framework AppKit \
  -framework UniformTypeIdentifiers \
  "$PROJECT_DIR/macos/Nota/NotaApp.swift" \
  -o "$MACOS_DIR/$APP_NAME"

cp "$PROJECT_DIR/macos/Nota/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/macos/Nota/Assets/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"
chmod +x "$MACOS_DIR/$APP_NAME"

swiftc \
  -target arm64-apple-macosx14.0 \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -parse-as-library \
  -emit-library \
  -module-name NotaShare \
  -framework AppKit \
  -framework UniformTypeIdentifiers \
  "$PROJECT_DIR/macos/NotaShare/ShareViewController.swift" \
  -o "$SHARE_MACOS_DIR/NotaShare"

cp "$PROJECT_DIR/macos/NotaShare/Info.plist" "$SHARE_CONTENTS_DIR/Info.plist"
chmod +x "$SHARE_MACOS_DIR/NotaShare"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$SHARE_APP_EXTENSION_DIR" >/dev/null 2>&1 || true
  codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "$APP_DIR"
