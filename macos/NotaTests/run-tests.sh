#!/bin/bash
# Compile and run Swift unit tests for in-transcript speaker naming.
# Usage: bash macos/NotaTests/run-tests.sh
# Returns 0 on all-pass, 1 on any failure.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="$PROJECT_DIR/macos/NotaTests"
BUILD_DIR="$PROJECT_DIR/.build/macos-tests"
MODULE_CACHE_DIR="$BUILD_DIR/ModuleCache"
TEST_BIN="$BUILD_DIR/nota-speaker-tests"

mkdir -p "$BUILD_DIR" "$MODULE_CACHE_DIR"

echo "Building speaker tests..."

xcrun swiftc \
  -target arm64-apple-macosx26.0 \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -framework Foundation \
  "$TEST_DIR/SpeakerTests.swift" \
  -o "$TEST_BIN"

echo "Running speaker tests..."
"$TEST_BIN"
