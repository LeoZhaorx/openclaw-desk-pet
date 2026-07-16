#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

find_desk_sprite_pids() {
  local abs_bin="$SCRIPT_DIR/.build/debug/desk-sprite"
  {
    pgrep -f "^$abs_bin$" || true
    pgrep -f "^\\./.build/debug/desk-sprite$" || true
  } | awk 'NF { print }' | sort -u
}

load_env_file() {
  local env_file="$1"
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ""|\#*) continue ;;
    esac
    case "$line" in
      *=*) ;;
      *) continue ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    value="${value%$'\r'}"
    case "$key" in
      OPENCLAW_ROOT|OPENCLAW_GATEWAY_URL|OPENCLAW_GATEWAY_TOKEN|OPENCLAW_ACTIVE_WINDOW_SECONDS|OPENCLAW_START_SCRIPT)
        case "$value" in
          \"*\") value="${value#\"}"; value="${value%\"}" ;;
          \'*\') value="${value#\'}"; value="${value%\'}" ;;
        esac
        export "$key=$value"
        ;;
    esac
  done < "$env_file"
}

if [ -f "$SCRIPT_DIR/.desk-sprite.env" ]; then
  # Parse the allowlisted variables as data. Do not source this file: values are
  # editable from the local console and must never be evaluated as shell code.
  load_env_file "$SCRIPT_DIR/.desk-sprite.env"
fi

if [ -x "$SCRIPT_DIR/start_console.sh" ]; then
  "$SCRIPT_DIR/start_console.sh" --restart || true
fi

if [ -z "${DESK_SPRITE_SOURCE_ASSETS:-}" ]; then
  DESK_SPRITE_SOURCE_ASSETS="$PACKAGE_ROOT/media"
fi
export DESK_SPRITE_SOURCE_ASSETS

if [ -z "${OPENCLAW_ROOT:-}" ]; then
  if [ -d "$HOME/.openclaw" ]; then
    OPENCLAW_ROOT="$HOME/.openclaw"
  elif [ -d "$HOME/Openclaw_Workspace" ]; then
    OPENCLAW_ROOT="$HOME/Openclaw_Workspace"
  elif [ -d "$HOME/OpenClaw" ]; then
    OPENCLAW_ROOT="$HOME/OpenClaw"
  fi
fi
if [ -n "${OPENCLAW_ROOT:-}" ]; then
  export OPENCLAW_ROOT
fi

if [ -n "$(find_desk_sprite_pids)" ]; then
  echo "desk-sprite is already running. Use ./halt.sh first if you want to restart."
  exit 0
fi

# Recover from stale SwiftPM lock (PID in .build/.lock no longer exists).
if [ -f "$SCRIPT_DIR/.build/.lock" ]; then
  LOCK_PID="$(cat "$SCRIPT_DIR/.build/.lock" 2>/dev/null || true)"
  if [ -n "$LOCK_PID" ] && ! ps -p "$LOCK_PID" >/dev/null 2>&1; then
    rm -f "$SCRIPT_DIR/.build/.lock"
  fi
fi

swift build >/dev/null

export DESK_SPRITE_ASSETS="$SCRIPT_DIR/../media"

LOG_FILE="${DESK_SPRITE_LOG_FILE:-$SCRIPT_DIR/.desk-sprite.log}"
nohup "$SCRIPT_DIR/.build/debug/desk-sprite" >>"$LOG_FILE" 2>&1 &
PID=$!
sleep 1.2

if [ -n "$(find_desk_sprite_pids)" ] && ps -p "$PID" >/dev/null 2>&1; then
  echo "desk-sprite started (pid: $PID)"
  echo "log: $LOG_FILE"
else
  echo "desk-sprite failed to start. check log: $LOG_FILE"
  exit 1
fi
