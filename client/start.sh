#!/usr/bin/env bash
# Start the VLESS REALITY client: renders config from .env and runs xray in the
# foreground. All traffic sent to the SOCKS port is tunneled to the server.
set -euo pipefail

CLIENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$CLIENT_DIR/.env"
TEMPLATE="$CLIENT_DIR/config.json.template"
GEN_DIR="$CLIENT_DIR/.generated"
CONFIG="$GEN_DIR/config.json"
PID_FILE="$CLIENT_DIR/xray.pid"

if [ ! -f "$ENV_FILE" ]; then
  echo "FATAL: $ENV_FILE missing - copy .env.example to .env and fill it in" >&2
  exit 1
fi

set -a
. "$ENV_FILE"
set +a

# defaults for optional settings
SOCKS_LISTEN="${SOCKS_LISTEN:-127.0.0.1}"
SOCKS_PORT="${SOCKS_PORT:-1080}"
HTTP_LISTEN="${HTTP_LISTEN:-127.0.0.1}"
HTTP_PORT="${HTTP_PORT:-1081}"
FINGERPRINT="${FINGERPRINT:-chrome}"
FLOW="${FLOW:-xtls-rprx-vision}"
export SOCKS_LISTEN SOCKS_PORT HTTP_LISTEN HTTP_PORT FINGERPRINT FLOW

# required settings
for var in SERVER_ADDR SERVER_PORT UUID REALITY_PUBLIC_KEY REALITY_SHORT_ID REALITY_SNI; do
  [ -n "${!var:-}" ] || { echo "FATAL: $var is empty in $ENV_FILE" >&2; exit 1; }
done

command -v xray >/dev/null 2>&1 || {
  echo "FATAL: 'xray' not found in PATH - install it first (see client/README.md)" >&2
  exit 1
}

mkdir -p "$GEN_DIR"

# render config from template (pure bash)
RENDER_VARS=(SERVER_ADDR SERVER_PORT UUID REALITY_PUBLIC_KEY REALITY_SHORT_ID REALITY_SNI SOCKS_LISTEN SOCKS_PORT HTTP_LISTEN HTTP_PORT FINGERPRINT FLOW)
render_line() {
  local l="$1" var
  for var in "${RENDER_VARS[@]}"; do
    l="${l//\$$var/${!var}}"
  done
  printf '%s' "$l"
}

{
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$(render_line "$line")"
  done < "$TEMPLATE"
} > "$CONFIG"

echo "config rendered -> $CONFIG"
echo "SOCKS proxy: socks5://$SOCKS_LISTEN:$SOCKS_PORT  ->  $SERVER_ADDR:$SERVER_PORT (VLESS+REALITY)"
echo "HTTP  proxy: http://$HTTP_LISTEN:$HTTP_PORT  ->  $SERVER_ADDR:$SERVER_PORT (VLESS+REALITY)"
echo "press Ctrl+C to stop"
echo $$ > "$PID_FILE"
exec xray run -c "$CONFIG"