#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/desk-sprite"
./start_console.sh
./halt.sh || true
./launch.sh
