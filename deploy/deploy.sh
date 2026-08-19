#!/usr/bin/env bash
# Deploy a hardened VLESS REALITY proxy droplet to DigitalOcean.
# Secrets never leave the server: REALITY keys + UUID are generated on the box.
# Environment: see deploy/.env.example (a deploy/.env is auto-loaded if present).
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY_DIR="$DEPLOY_DIR/keys"
GEN_DIR="$DEPLOY_DIR/.generated"
PRIV_KEY="$KEY_DIR/deploy_user_ed25519"
PUB_KEY="$PRIV_KEY.pub"
KNOWN_HOSTS="$KEY_DIR/known_hosts"

# load .env if present (gitignored - never commit DO_API_KEY)
if [ -f "$DEPLOY_DIR/.env" ]; then
  set -a
  . "$DEPLOY_DIR/.env"
  set +a
fi

DEPLOY_USER="${DEPLOY_USER:-deploy-user}"
ADMIN_USER="${ADMIN_USER:-admin-user}"
REGION="${REGION:-sgp1}"
SIZE="${SIZE:-s-1vcpu-512mb-10gb}"          # cheapest droplet
IMAGE="${IMAGE:-ubuntu-24-04-x64}"
DROPLET_NAME="${DROPLET_NAME:-vless-reality-$(date +%m%d%H%M)}"
SSH_PORT="${SSH_PORT:-22022}"
REALITY_SNI="${REALITY_SNI:-m365.cloud.microsoft}"
REALITY_DEST="${REALITY_DEST:-${REALITY_SNI}:443}"
TAGS="${TAGS:-vless-reality}"

# ------------------------------------------------------------------ checks
: "${DO_API_KEY:?Set DO_API_KEY in your environment or deploy/.env (see .env.example)}"
for bin in curl jq ssh scp ssh-keygen base64 python3; do
  command -v "$bin" >/dev/null || { echo "FATAL: missing required binary: $bin" >&2; exit 1; }
done

ssh_opts=(-p "$SSH_PORT" -i "$PRIV_KEY" -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o IdentitiesOnly=yes)

# ---------------------------------------------------------- 1. SSH keypair
mkdir -p "$KEY_DIR" "$GEN_DIR"
chmod 700 "$KEY_DIR"
if [ ! -f "$PRIV_KEY" ]; then
  echo "[1/6] generating Ed25519 keypair -> $PRIV_KEY"
  ssh-keygen -t ed25519 -a 100 -N "" -C "$DEPLOY_USER@vless-reality" -f "$PRIV_KEY" >/dev/null
fi

# ------------------------------------------------- 2. build cloud-init
echo "[2/6] rendering cloud-init (users: $DEPLOY_USER / $ADMIN_USER, ssh port: $SSH_PORT, sni: $REALITY_SNI)"
python3 - "$DEPLOY_DIR" "$PUB_KEY" "$DEPLOY_USER" "$ADMIN_USER" "$SSH_PORT" "$REALITY_SNI" "$REALITY_DEST" "$GEN_DIR/cloud-init.yml" <<'PYEOF'
import sys

deploy_dir, pub_key, deploy_user, admin_user, ssh_port, reality_sni, reality_dest, out = sys.argv[1:9]

def indent_block(text):
    lines = text.splitlines()
    return "\n".join(
        line if i == 0 else ("      " + line if line.strip() else line)
        for i, line in enumerate(lines)
    )

t = open(f"{deploy_dir}/cloud-init.yml").read()
repl = {
    "{{ADMIN_SSH_PUBKEY}}": open(pub_key).read().strip(),
    "{{DEPLOY_USER}}": deploy_user,
    "{{ADMIN_USER}}": admin_user,
    "{{SSH_PORT}}": ssh_port,
    "{{REALITY_SNI}}": reality_sni,
    "{{REALITY_DEST}}": reality_dest,
    "{{FAIL2BAN_JAIL}}": indent_block(open(f"{deploy_dir}/fail2ban/jail.local").read().rstrip("\n")),
    "{{FAIL2BAN_FILTER}}": indent_block(open(f"{deploy_dir}/fail2ban/filter.d/xray-reality.conf").read().rstrip("\n")),
    "{{XRAY_CONFIG_TEMPLATE}}": indent_block(open(f"{deploy_dir}/xray/config.json.template").read().rstrip("\n")),
    "{{XRAY_SERVICE}}": indent_block(open(f"{deploy_dir}/xray/xray.service").read().rstrip("\n")),
}
for _ in range(2):
    for k, v in repl.items():
        t = t.replace(k, v)
open(out, "w").write(t)
PYEOF
USER_DATA_B64=$(base64 < "$GEN_DIR/cloud-init.yml")

# -------------------------------------------------------- 3. create droplet
echo "[3/6] creating droplet '$DROPLET_NAME' ($REGION / $SIZE / $IMAGE)"
CREATE_JSON=$(jq -n \
  --arg name "$DROPLET_NAME" \
  --arg region "$REGION" \
  --arg size "$SIZE" \
  --arg image "$IMAGE" \
  --arg tags "$TAGS" \
  --arg user_data "$USER_DATA_B64" \
  '{name:$name,region:$region,size:$size,image:$image,backups:false,monitoring:true,ipv6:false,tags:[$tags],user_data:$user_data}')
RESP=$(curl -fsS -X POST -H "Authorization: Bearer $DO_API_KEY" -H "Content-Type: application/json" \
  -d "$CREATE_JSON" https://api.digitalocean.com/v2/droplets)
DROPLET_ID=$(echo "$RESP" | jq -r '.droplet.id')

echo "    droplet id: $DROPLET_ID"
echo "    waiting for public IPv4..."
IP=""
for _ in $(seq 1 60); do
  IP=$(curl -fsS -H "Authorization: Bearer $DO_API_KEY" \
    "https://api.digitalocean.com/v2/droplets/$DROPLET_ID" \
    | jq -r '.droplet.networks.v4[]? | select(.type=="public") | .ip_address')
  [ -n "$IP" ] && break
  sleep 5
done
[ -n "$IP" ] || { echo "FATAL: droplet never got an IP" >&2; exit 1; }
echo "    public IP: $IP"

# ------------------------------------------------ 4. wait for SSH (22022)
echo "[4/6] waiting for sshd on port $SSH_PORT and cloud-init completion..."
SSH_OK=0
for _ in $(seq 1 72); do
  if ssh "${ssh_opts[@]}" -o ConnectTimeout=5 "$DEPLOY_USER@$IP" \
      'cloud-init status | grep -q "^status: done"' 2>/dev/null; then
    SSH_OK=1
    break
  fi
  sleep 5
done
[ "$SSH_OK" = 1 ] || { echo "FATAL: ssh not reachable on $IP:$SSH_PORT; use the DO console (root) as fallback" >&2; exit 1; }

# ------------------------------------------------------------ 5. verify
echo "[5/6] verification (no admin privileges required):"
ssh "${ssh_opts[@]}" "$DEPLOY_USER@$IP" "SSH_PORT=$SSH_PORT bash -s" <<'EOF'
echo "  units:"
systemctl is-active ssh xray fail2ban | sed 's/^/    /'
echo "  listeners:"
ss -tln | grep -E ":($SSH_PORT|443)\b" | sed 's/^/    /'
echo "  bootstrap output (tail):"
tail -n 12 /var/log/cloud-init-output.log | sed 's/^/    /'
EOF

# ------------------------------------------------------------ 6. report
echo "[6/6] done."
echo
echo "=== DEPLOYMENT COMPLETE ==="
echo "Droplet: $DROPLET_NAME  ($DROPLET_ID)  IP: $IP"
echo "SSH (remote access, no sudo):"
echo "    ssh -p $SSH_PORT -i $DEPLOY_DIR/keys/deploy_user_ed25519 $DEPLOY_USER@$IP"
echo "Admin (local only, full sudo - via DO console root, then su - $ADMIN_USER):"
echo "    console -> root -> su - $ADMIN_USER"
echo
echo "=== CLIENT CONNECTION PARAMETERS (also saved at /home/$DEPLOY_USER/client-params.txt) ==="
ssh "${ssh_opts[@]}" "$DEPLOY_USER@$IP" "cat /home/$DEPLOY_USER/client-params.txt" | sed "s|<server-ip>|$IP|"
