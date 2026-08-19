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
if [ -z "$SSH_KEY" ] || [ ! -f "$SSH_KEY" ]; then
  read -r -p "path to SSH private key for $SSH_USER@$SERVER_ADDR (port $SSH_PORT): " SSH_KEY
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

python3 - "$ENV_FILE" "$SERVER_ADDR" "$PORT" "$UUID" "$PUB" "$SHORT" "$SNI" <<'PYEOF'
import sys

env_file, addr, port, uuid, pub, short, sni = sys.argv[1:8]
updates = {
    "SERVER_ADDR": addr,
    "SERVER_PORT": port,
    "UUID": uuid,
    "REALITY_PUBLIC_KEY": pub,
    "REALITY_SHORT_ID": short,
    "REALITY_SNI": sni,
}
lines, seen = [], set()
for line in open(env_file):
    key = line.split("=", 1)[0]
    if key in updates:
        lines.append(f"{key}={updates[key]}")
        seen.add(key)
    else:
        lines.append(line.rstrip("\n"))
for k, v in updates.items():
    if k not in seen:
        lines.append(f"{k}={v}")
open(env_file, "w").write("\n".join(lines) + "\n")
print(f"updated {env_file}")
PYEOF

echo "done - run ./start.sh to start the client"
