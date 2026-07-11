#!/bin/bash
# Internal runner for the macOS app. It loads the user's shell environment
# before invoking the built Nota CLI.

set -euo pipefail

PROJECT_DIR="${NOTA_PROJECT_DIR:-/Users/xiafawu/Developer/Nota}"

fail() {
  echo "nota-app-run: $*" >&2
  exit 1
}

present() {
  local name="$1"
  if [ -n "${!name:-}" ]; then
    printf 'set'
  else
    printf 'missing'
  fi
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
      for name in PATH OPENAI_API_KEY ASSEMBLYAI_API_KEY HUGGINGFACE_TOKEN PYTHON_BIN NOTA_PROJECT_DIR NOTA_OUTPUT_DIR NOTA_SHARE_FLAGS MEETINGSUM_SHARE_FLAGS; do
        value="${(P)name}"
        if [[ -n "$value" ]]; then
          print -r -- "$name=$value"
        fi
      done
    ' 2>/dev/null || true
  )
}

if [ "$#" -lt 2 ]; then
  echo "Usage: nota-app-run.sh <audio-file> <output-file> [nota flags...]" >&2
  exit 64
fi

input_file="$1"
output_file="$2"
shift 2

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
load_user_environment

# Pull all keys from the user's secrets file generically so new providers
# (PICOVOICE_ACCESS_KEY, GEMINI_API_KEY, ...) need no edit to the harvest list above.
if [ -f "$HOME/.secrets" ]; then
  set +u; set -a
  . "$HOME/.secrets" 2>/dev/null || true
  set +a; set -u
fi

export PYTHON_BIN="${PYTHON_BIN:-python3.11}"

echo "nota-app-run: project=$PROJECT_DIR" >&2
echo "nota-app-run: input=$input_file" >&2
echo "nota-app-run: output=$output_file" >&2
echo "nota-app-run: node=$(command -v node || true)" >&2
echo "nota-app-run: npm=$(command -v npm || true)" >&2
echo "nota-app-run: ffmpeg=$(command -v ffmpeg || true)" >&2
echo "nota-app-run: OPENAI_API_KEY=$(present OPENAI_API_KEY)" >&2
echo "nota-app-run: ASSEMBLYAI_API_KEY=$(present ASSEMBLYAI_API_KEY)" >&2
echo "nota-app-run: HUGGINGFACE_TOKEN=$(present HUGGINGFACE_TOKEN)" >&2
echo "nota-app-run: PYTHON_BIN=${PYTHON_BIN}" >&2

[ -d "$PROJECT_DIR" ] || fail "project directory does not exist: $PROJECT_DIR"
[ -f "$input_file" ] || fail "input file does not exist: $input_file"
[ -s "$input_file" ] || fail "input file is empty: $input_file"

cd "$PROJECT_DIR" || fail "could not cd to project directory: $PROJECT_DIR"

if [ "${NOTA_APP_RUNNER_SMOKE:-0}" = "1" ]; then
  output_dir="$(dirname "$output_file")"
  mkdir -p "$output_dir"
  {
    printf '# Nota App Smoke Test\n\n'
    printf '**Input:** `%s`\n' "$input_file"
    printf '**Project:** `%s`\n' "$PROJECT_DIR"
    printf '**Node:** `%s`\n' "$(command -v node || true)"
    printf '**ffmpeg:** `%s`\n' "$(command -v ffmpeg || true)"
  } > "$output_file"
  echo "nota-app-run: smoke output written" >&2
  exit 0
fi

if [ ! -f "dist/index.js" ]; then
  npm run build
fi

[ -f "dist/index.js" ] || fail "dist/index.js does not exist after build"
command -v node >/dev/null 2>&1 || fail "node is not on PATH"

exec node dist/index.js "$input_file" -o "$output_file" "$@"
