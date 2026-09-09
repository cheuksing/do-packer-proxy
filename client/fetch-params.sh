#!/usr/bin/env bash
# Fetch the server-generated client parameters and fill them into client/.env.
# Runs on ANY machine - it only needs an SSH key that can log in as the remote
# user (deploy-user by default). Nothing is stored outside client/.
set -euo pipefail

CLIENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$CLIENT_DIR/.env"
GEN_DIR="$CLIENT_DIR/.generated"
KNOWN_HOSTS="$GEN_DIR/known_hosts"

if [ ! -f "$ENV_FILE" ]; then
  cp "$CLIENT_DIR/.env.example" "$ENV_FILE"
  echo "created $ENV_FILE from .env.example"
fi

set -a
. "$ENV_FILE"
set +a

SERVER_ADDR="${SERVER_ADDR:-}"
SSH_USER="${SSH_USER:-deploy-user}"
SSH_PORT="${SSH_PORT:-22022}"
SSH_KEY="${SSH_KEY:-}"

if [ -z "$SERVER_ADDR" ]; then
  read -r -p "server address (IP or hostname): " SERVER_ADDR
fi
# resolve relative SSH_KEY against client/ (not the caller's cwd)
if [ -n "$SSH_KEY" ] && [ "${SSH_KEY#/}" = "$SSH_KEY" ] && [ ! -f "$SSH_KEY" ] && [ -f "$CLIENT_DIR/$SSH_KEY" ]; then
  SSH_KEY="$CLIENT_DIR/$SSH_KEY"
fi
if [ -z "$SSH_KEY" ] || [ ! -f "$SSH_KEY" ]; then
  read -r -p "path to SSH private key for $SSH_USER@$SERVER_ADDR (port $SSH_PORT): " SSH_KEY
fi
if [ -n "$SSH_KEY" ] && [ "${SSH_KEY#/}" = "$SSH_KEY" ] && [ ! -f "$SSH_KEY" ] && [ -f "$CLIENT_DIR/$SSH_KEY" ]; then
  SSH_KEY="$CLIENT_DIR/$SSH_KEY"
fi
[ -f "$SSH_KEY" ] || { echo "FATAL: SSH key not found: $SSH_KEY" >&2; exit 1; }

mkdir -p "$GEN_DIR"
echo "fetching client parameters from $SSH_USER@$SERVER_ADDR:$SSH_PORT ..."
PARAMS=$(ssh -p "$SSH_PORT" -i "$SSH_KEY" -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
  "$SSH_USER@$SERVER_ADDR" "cat /home/$SSH_USER/client-params.txt")

echo "$PARAMS" | sed "s|<server-ip>|$SERVER_ADDR|"

parse() { echo "$PARAMS" | awk -F': *' -v k="$1" '$1==k {print $2; exit}'; }
UUID=$(parse "id (UUID)")
PUB=$(parse "publicKey")
SHORT=$(parse "shortId")
SNI=$(parse "sni")
PORT=$(parse "port")

[ -n "$UUID" ] && [ -n "$PUB" ] && [ -n "$SHORT" ] || {
  echo "FATAL: could not parse client-params.txt from the server (unexpected format)" >&2
  exit 1
}

# update .env in place (preserve comments and unrelated keys)
TMP_ENV=$(mktemp)
: > "$TMP_ENV"
SEEN=""
while IFS= read -r line || [ -n "$line" ]; do
  key="${line%%=*}"
  case "$key" in
    SERVER_ADDR)        echo "SERVER_ADDR=$SERVER_ADDR" >> "$TMP_ENV"; SEEN="$SEEN|SERVER_ADDR|" ;;
    SERVER_PORT)        echo "SERVER_PORT=$PORT" >> "$TMP_ENV"; SEEN="$SEEN|SERVER_PORT|" ;;
    UUID)               echo "UUID=$UUID" >> "$TMP_ENV"; SEEN="$SEEN|UUID|" ;;
    REALITY_PUBLIC_KEY) echo "REALITY_PUBLIC_KEY=$PUB" >> "$TMP_ENV"; SEEN="$SEEN|REALITY_PUBLIC_KEY|" ;;
    REALITY_SHORT_ID)   echo "REALITY_SHORT_ID=$SHORT" >> "$TMP_ENV"; SEEN="$SEEN|REALITY_SHORT_ID|" ;;
    REALITY_SNI)        echo "REALITY_SNI=$SNI" >> "$TMP_ENV"; SEEN="$SEEN|REALITY_SNI|" ;;
    *)                  echo "$line" >> "$TMP_ENV" ;;
  esac
done < "$ENV_FILE"
for key in SERVER_ADDR SERVER_PORT UUID REALITY_PUBLIC_KEY REALITY_SHORT_ID REALITY_SNI; do
  case "$SEEN" in
    *"|$key|"*) ;;
    *) echo "$key=${!key}" >> "$TMP_ENV" ;;
  esac
done
mv "$TMP_ENV" "$ENV_FILE"

echo "updated $ENV_FILE - run ./start.sh to start the client"