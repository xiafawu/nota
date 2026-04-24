#!/bin/bash
# Backward-compatible wrapper for existing Shortcuts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/nota-share.sh" "$@"
