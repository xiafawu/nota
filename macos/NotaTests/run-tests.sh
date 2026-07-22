#!/bin/bash
# Compile and run the Swift unit tests (speaker naming + model catalog).
# Usage: bash macos/NotaTests/run-tests.sh
# Returns 0 on all-pass, 1 on any failure.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="$PROJECT_DIR/macos/NotaTests"
APP_DIR="$PROJECT_DIR/macos/Nota/App"
BUILD_DIR="$PROJECT_DIR/.build/macos-tests"
MODULE_CACHE_DIR="$BUILD_DIR/ModuleCache"
SPEAKER_BIN="$BUILD_DIR/nota-speaker-tests"
CATALOG_BIN="$BUILD_DIR/nota-catalog-tests"

mkdir -p "$BUILD_DIR" "$MODULE_CACHE_DIR"

echo "Building speaker tests..."

xcrun swiftc \
  -target arm64-apple-macosx26.0 \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -framework Foundation \
  "$TEST_DIR/SpeakerTests.swift" \
  -o "$SPEAKER_BIN"

echo "Running speaker tests..."
"$SPEAKER_BIN"

# Catalog tests compile against the REAL production sources so the decode /
# fallback / zombie logic under test is the shipping code.
echo "Building catalog tests..."

xcrun swiftc \
  -target arm64-apple-macosx26.0 \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -framework Foundation \
  "$APP_DIR/ModelRegistry.swift" \
  "$APP_DIR/ModelCatalog.swift" \
  "$TEST_DIR/CatalogTests.swift" \
  -o "$CATALOG_BIN"

echo "Running catalog tests..."
"$CATALOG_BIN"
