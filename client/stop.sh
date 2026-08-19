#!/usr/bin/env bash
# Stop the running xray client (started via start.sh).
set -euo pipefail

CLIENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$CLIENT_DIR/xray.pid"

if [ ! -f "$PID_FILE" ]; then
  echo "xray client not running (no pidfile)"
  exit 0
fi

PID=$(cat "$PID_FILE")
if kill -0 "$PID" 2>/dev/null; then
  kill "$PID"
  rm -f "$PID_FILE"
  echo "stopped xray client (pid $PID)"
else
  echo "xray client not running (stale pidfile removed)"
  rm -f "$PID_FILE"
fi
