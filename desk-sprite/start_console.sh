#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PORT="${DESK_SPRITE_CONSOLE_PORT:-17890}"
PID_FILE="$SCRIPT_DIR/.console.pid"
LOG_FILE="$SCRIPT_DIR/.console.log"
FORCE_RESTART=0

if [ "${1:-}" = "--restart" ] || [ "${DESK_SPRITE_CONSOLE_RESTART:-0}" = "1" ]; then
  FORCE_RESTART=1
fi

if [ -f "$PID_FILE" ]; then
  PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "${PID:-}" ] && ps -p "$PID" >/dev/null 2>&1; then
    if [ "$FORCE_RESTART" -eq 0 ]; then
      echo "desk-sprite console already running (pid: $PID)"
      exit 0
    fi
    kill "$PID" >/dev/null 2>&1 || true
    sleep 0.2
  fi
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found; cannot start console server."
  exit 0
fi

nohup python3 "$SCRIPT_DIR/console_server.py" --port "$PORT" >>"$LOG_FILE" 2>&1 &
PID=$!
echo "$PID" > "$PID_FILE"
sleep 0.4
if ps -p "$PID" >/dev/null 2>&1; then
  echo "desk-sprite console started (pid: $PID)"
  echo "console: http://127.0.0.1:$PORT/"
else
  echo "desk-sprite console failed to start. check log: $LOG_FILE"
  exit 1
fi
