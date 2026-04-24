#!/bin/bash
# Nota Share handler. Designed for a macOS Shortcut or Automator action
# that receives files/media from Voice Memos, Apple Notes, Finder, or the share sheet.

set -euo pipefail

PROJECT_DIR="${NOTA_PROJECT_DIR:-${MEETINGSUM_PROJECT_DIR:-/Users/xiafawu/Developer/Nota}}"
OUTPUT_DIR="${NOTA_OUTPUT_DIR:-${MEETINGSUM_OUTPUT_DIR:-$HOME/Documents/Nota}}"
ERROR_LOG="${NOTA_ERROR_LOG:-${MEETINGSUM_ERROR_LOG:-/tmp/nota-error.log}}"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

notify() {
  local message="$1"
  local sound="${2:-}"

  if command -v osascript >/dev/null 2>&1; then
    if [ -n "$sound" ]; then
      osascript \
        -e 'on run argv' \
        -e 'display notification (item 1 of argv) with title "Nota" sound name (item 2 of argv)' \
        -e 'end run' \
        "$message" "$sound" || true
    else
      osascript \
        -e 'on run argv' \
        -e 'display notification (item 1 of argv) with title "Nota"' \
        -e 'end run' \
        "$message" || true
    fi
  fi
}

decode_input() {
  local value="$1"

  if [[ "$value" == file://* ]]; then
    python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(sys.argv[1][7:]))' "$value" 2>/dev/null || printf '%s\n' "${value#file://}"
  else
    printf '%s\n' "$value"
  fi
}

safe_basename() {
  local value="$1"
  value="${value%.*}"
  value="${value//[^[:alnum:]._-]/-}"
  printf '%s\n' "${value:-recording}"
}

# Load environment variables for API keys when launched outside an interactive shell.
for env_file in "$HOME/.zshenv" "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bash_profile"; do
  if [ -f "$env_file" ]; then
    # User shell files may contain commands that only work interactively.
    # Keep going even if one of them returns non-zero.
    set +u
    source "$env_file" >/dev/null 2>&1 || true
    set -u
  fi
done

export PYTHON_BIN="${PYTHON_BIN:-python3.11}"

inputs=()
for arg in "$@"; do
  [ -n "$arg" ] && inputs+=("$arg")
done

if [ "${#inputs[@]}" -eq 0 ] && [ ! -t 0 ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && inputs+=("$line")
  done
fi

if [ "${#inputs[@]}" -eq 0 ] && command -v osascript >/dev/null 2>&1; then
  set +e
  chosen_file="$(
    osascript \
      -e 'try' \
      -e 'POSIX path of (choose file with prompt "Choose an audio file for Nota")' \
      -e 'on error' \
      -e 'return ""' \
      -e 'end try'
  )"
  choose_status=$?
  set -e
  if [ "$choose_status" -ne 0 ]; then
    chosen_file=""
  fi
  [ -n "$chosen_file" ] && inputs+=("$chosen_file")
fi

if [ "${#inputs[@]}" -eq 0 ]; then
  notify "No audio file provided" "Basso"
  exit 0
fi

mkdir -p "$OUTPUT_DIR"

read -r -a extra_flags <<< "${NOTA_SHARE_FLAGS:-${MEETINGSUM_SHARE_FLAGS:---identify}}"

successes=0
failures=0
last_output=""
index=0

notify "Preparing ${#inputs[@]} shared item(s)..."

for raw_input in "${inputs[@]}"; do
  [ -n "$raw_input" ] || continue
  input="$(decode_input "$raw_input")"

  [ -n "$input" ] || continue

  if [ ! -f "$input" ]; then
    echo "Skipping non-file input: $raw_input" >> "$ERROR_LOG"
    failures=$((failures + 1))
    continue
  fi

  original_name="$(basename "$input")"
  base="$(safe_basename "$original_name")"
  ext="${original_name##*.}"
  if [ "$ext" = "$original_name" ]; then
    ext="m4a"
  fi
  ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"

  timestamp="$(date +%Y%m%d-%H%M%S)"
  stable_copy="$OUTPUT_DIR/.nota-input-${timestamp}-$$-${index}.${ext}"
  output="$OUTPUT_DIR/${base}-${timestamp}.summary.md"

  # Voice Memos and Notes often share temporary files that disappear when the
  # share sheet closes, so copy immediately before the pipeline starts.
  cp "$input" "$stable_copy"

  notify "Transcribing ${original_name}..."

  set +e
  (
    cd "$PROJECT_DIR" &&
      npm run dev -- "$stable_copy" "${extra_flags[@]}" -o "$output"
  ) > "$ERROR_LOG" 2>&1
  status=$?
  set -e

  rm -f "$stable_copy"

  if [ "$status" -eq 0 ]; then
    successes=$((successes + 1))
    last_output="$output"
  else
    failures=$((failures + 1))
  fi

  index=$((index + 1))
done

if [ "$successes" -gt 0 ] && [ "$failures" -eq 0 ]; then
  notify "Saved ${successes} summary file(s)" "Glass"
elif [ "$successes" -gt 0 ]; then
  notify "Saved ${successes}; failed ${failures}" "Basso"
else
  error="$(tail -1 "$ERROR_LOG" 2>/dev/null || true)"
  notify "Failed: ${error:-see $ERROR_LOG}" "Basso"
  exit 1
fi

if [ "$successes" -eq 1 ] && [ -n "$last_output" ]; then
  open "$last_output" || true
else
  open "$OUTPUT_DIR" || true
fi
