#!/usr/bin/env bash
# Report whether the xray client is running and the SOCKS port is listening.
set -euo pipefail

CLIENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$CLIENT_DIR/xray.pid"
ENV_FILE="$CLIENT_DIR/.env"

RUNNING=no
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "xray client: running (pid $(cat "$PID_FILE"))"
  RUNNING=yes
else
  echo "xray client: not running"
fi

SOCKS_PORT=1080
HTTP_PORT=1081
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE" 2>/dev/null || true
  SOCKS_PORT="${SOCKS_PORT:-1080}"
  HTTP_PORT="${HTTP_PORT:-1081}"
fi

if command -v nc >/dev/null 2>&1; then
  if nc -z 127.0.0.1 "$SOCKS_PORT" >/dev/null 2>&1; then
    echo "SOCKS proxy: listening on 127.0.0.1:$SOCKS_PORT"
  else
    echo "SOCKS proxy: NOT listening on 127.0.0.1:$SOCKS_PORT"
  fi
  if nc -z 127.0.0.1 "$HTTP_PORT" >/dev/null 2>&1; then
    echo "HTTP proxy:   listening on 127.0.0.1:$HTTP_PORT"
  else
    echo "HTTP proxy:   NOT listening on 127.0.0.1:$HTTP_PORT"
  fi
else
  echo "proxies: cannot check (nc not installed); curl tests:"
  echo "  curl -x socks5h://127.0.0.1:$SOCKS_PORT https://ipinfo.io/ip"
  echo "  curl -x http://127.0.0.1:$HTTP_PORT https://ipinfo.io/ip"
fi

[ "$RUNNING" = yes ]
