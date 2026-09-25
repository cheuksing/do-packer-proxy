#!/usr/bin/env bash
# Start the VLESS REALITY client using the rendered config.
# All traffic sent to the SOCKS port is tunneled to the server.
set -euo pipefail

CLIENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$CLIENT_DIR/.generated/config.json"
PID_FILE="$CLIENT_DIR/xray.pid"

if [ ! -f "$CONFIG" ]; then
  echo "FATAL: $CONFIG missing - run ./update-config.sh first" >&2
  exit 1
fi

command -v xray >/dev/null 2>&1 || {
  echo "FATAL: 'xray' not found in PATH - install it first (see client/README.md)" >&2
  exit 1
}

echo "starting xray with $CONFIG"
echo "press Ctrl+C to stop"
echo $$ > "$PID_FILE"
exec xray run -c "$CONFIG"
