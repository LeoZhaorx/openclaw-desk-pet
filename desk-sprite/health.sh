#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

find_desk_sprite_pids() {
  local abs_bin="$SCRIPT_DIR/.build/debug/desk-sprite"
  {
    pgrep -f "^$abs_bin$" || true
    pgrep -f "^\\./.build/debug/desk-sprite$" || true
  } | awk 'NF { print }' | sort -u
}

PIDS="$(find_desk_sprite_pids)"
if [ -z "$PIDS" ]; then
  echo 'desk-sprite is not running.'
else
  echo "desk-sprite running (pid: $PIDS)"
fi
