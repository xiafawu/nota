#!/bin/bash
# Internal runner for the macOS app's readiness check. Loads the user's shell
# environment (same harvest as nota-app-run.sh) and invokes `nota preflight
# --json`, whose JSON the app renders as the traffic-light home. Any extra
# arguments are forwarded to the CLI (e.g. --refresh, --identify).

set -euo pipefail

PROJECT_DIR="${NOTA_PROJECT_DIR:-/Users/xiafawu/Developer/Nota}"

fail() {
  echo "nota-app-preflight: $*" >&2
  exit 1
}

load_user_environment() {
  if [ ! -x /bin/zsh ]; then
    return
  fi

  while IFS= read -r assignment; do
    case "$assignment" in
      *=*) export "$assignment" ;;
    esac
  done < <(
    /bin/zsh -lic '
      for name in PATH OPENAI_API_KEY ASSEMBLYAI_API_KEY GEMINI_API_KEY HUGGINGFACE_TOKEN PYTHON_BIN NOTA_PROJECT_DIR; do
        value="${(P)name}"
        if [[ -n "$value" ]]; then
          print -r -- "$name=$value"
        fi
      done
    ' 2>/dev/null || true
  )
}

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
load_user_environment

# Pull all keys from the user's secrets file generically (matches nota-app-run.sh).
if [ -f "$HOME/.secrets" ]; then
  set +u; set -a
  . "$HOME/.secrets" 2>/dev/null || true
  set +a; set -u
fi

export PYTHON_BIN="${PYTHON_BIN:-python3.11}"

[ -d "$PROJECT_DIR" ] || fail "project directory does not exist: $PROJECT_DIR"
cd "$PROJECT_DIR" || fail "could not cd to project directory: $PROJECT_DIR"

if [ ! -f "dist/index.js" ]; then
  npm run build >&2
fi
[ -f "dist/index.js" ] || fail "dist/index.js does not exist after build"
command -v node >/dev/null 2>&1 || fail "node is not on PATH"

exec node dist/index.js preflight --json "$@"
