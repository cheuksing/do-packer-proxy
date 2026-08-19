#!/usr/bin/env bash
# Deploy a hardened VLESS REALITY proxy droplet to DigitalOcean via doctl.
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

# ------------------------------------------------------------------ checks
DO_API_KEY="${DO_API_KEY:-${DIGITALOCEAN_ACCESS_TOKEN:-}}"
: "${DO_API_KEY:?Set DO_API_KEY in your environment or deploy/.env (see .env.example)}"
for bin in doctl ssh scp ssh-keygen; do
  command -v "$bin" >/dev/null || { echo "FATAL: missing required binary: $bin (install doctl: brew install doctl)" >&2; exit 1; }
done

ssh_opts=(-p "$SSH_PORT" -i "$PRIV_KEY" -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o IdentitiesOnly=yes)

# ---------------------------------------------------------- 1. SSH keypair
mkdir -p "$KEY_DIR" "$GEN_DIR"
chmod 700 "$KEY_DIR"
if [ ! -f "$PRIV_KEY" ]; then
  echo "[1/7] generating Ed25519 keypair -> $PRIV_KEY"
  ssh-keygen -t ed25519 -a 100 -N "" -C "$DEPLOY_USER@vless-reality" -f "$PRIV_KEY" >/dev/null
fi

# ------------------------------------------------- 2. build cloud-init
echo "[2/7] rendering cloud-init (users: $DEPLOY_USER / $ADMIN_USER, ssh port: $SSH_PORT, sni: $REALITY_SNI)"
PUBKEY=$(cat "$PUB_KEY")

# substitute {{INLINE_MARKERS}} in a line
subst_inline() {
  local l="$1"
  l="${l//\{\{DEPLOY_USER\}\}/$DEPLOY_USER}"
  l="${l//\{\{ADMIN_USER\}\}/$ADMIN_USER}"
  l="${l//\{\{ADMIN_SSH_PUBKEY\}\}/$PUBKEY}"
  l="${l//\{\{SSH_PORT\}\}/$SSH_PORT}"
  l="${l//\{\{REALITY_SNI\}\}/$REALITY_SNI}"
  l="${l//\{\{REALITY_DEST\}\}/$REALITY_DEST}"
  printf '%s' "$l"
}

# emit a file's contents indented into a YAML literal block (marker line supplies indent)
splice_file() {
  local l out
  while IFS= read -r l || [ -n "$l" ]; do
    out=$(subst_inline "$l")
    if [ -n "$out" ]; then
      printf '      %s\n' "$out"
    else
      printf '\n'
    fi
  done < "$1"
}

{
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *"{{FAIL2BAN_JAIL}}"*)        splice_file "$DEPLOY_DIR/fail2ban/jail.local" ;;
      *"{{FAIL2BAN_FILTER}}"*)      splice_file "$DEPLOY_DIR/fail2ban/filter.d/xray-reality.conf" ;;
      *"{{XRAY_CONFIG_TEMPLATE}}"*) splice_file "$DEPLOY_DIR/xray/config.json.template" ;;
      *"{{XRAY_SERVICE}}"*)         splice_file "$DEPLOY_DIR/xray/xray.service" ;;
      *)                            printf '%s\n' "$(subst_inline "$line")" ;;
    esac
  done < "$DEPLOY_DIR/cloud-init.yml"
} > "$GEN_DIR/cloud-init.yml"

# -------------------------------------------------------- 3. create droplet
echo "[3/7] ensuring droplet '$DROPLET_NAME' ($REGION / $SIZE / $IMAGE)"
export DIGITALOCEAN_ACCESS_TOKEN="$DO_API_KEY"
if EXISTING_ID=$(doctl compute droplet get "$DROPLET_NAME" --format ID --no-header 2>/dev/null); then
  echo "    droplet already exists (id $EXISTING_ID) - reusing it"
else
  doctl compute droplet create "$DROPLET_NAME" \
    --region "$REGION" \
    --size "$SIZE" \
    --image "$IMAGE" \
    --enable-monitoring \
    --user-data-file "$GEN_DIR/cloud-init.yml" \
    --wait >/dev/null
  echo "    droplet created"
fi

DROPLET_ID=$(doctl compute droplet get "$DROPLET_NAME" --format ID --no-header)
IP=$(doctl compute droplet get "$DROPLET_NAME" --format PublicIPv4 --no-header)
echo "    droplet id: $DROPLET_ID  public IP: $IP"

# ---------------------------------------------- 4. cloud firewall (doctl)
# DO cloud firewall sits in front of the droplet: allow only 443 + SSH_PORT,
# everything else (incl. 22/80) is dropped. In-droplet UFW is defense in depth.
# A fresh firewall is created per droplet (attached at creation), so only
# firewall:create + firewall:read scopes are needed - never firewall:update.
FW_NAME="${DROPLET_NAME}-${DROPLET_ID}-fw"
INBOUND_RULES="protocol:tcp,ports:443,address:0.0.0.0/0;protocol:tcp,ports:${SSH_PORT},address:0.0.0.0/0"
OUTBOUND_RULES="protocol:tcp,ports:1-65535,address:0.0.0.0/0;protocol:udp,ports:1-65535,address:0.0.0.0/0"

configure_firewall() {
  local fw_id
  fw_id=$(doctl compute firewall get "$FW_NAME" --format ID --no-header 2>/dev/null) || fw_id=""
  if [ -z "$fw_id" ]; then
    fw_id=$(doctl compute firewall create --name "$FW_NAME" \
      --inbound-rules "$INBOUND_RULES" --outbound-rules "$OUTBOUND_RULES" \
      --droplet-ids "$DROPLET_ID" --format ID --no-header 2>/dev/null) || return 1
    echo "    firewall created + attached: $FW_NAME"
  else
    # reuse only if it already covers this droplet; never modify existing rules
    if doctl compute firewall get "$fw_id" --format DropletIDs --no-header 2>/dev/null | grep -qw "$DROPLET_ID"; then
      echo "    firewall already attached (reused): $FW_NAME"
    else
      echo "WARNING: firewall '$FW_NAME' exists but does not cover droplet $DROPLET_ID" >&2
      echo "         delete the stale firewall in the DO console, then re-run" >&2
      return 1
    fi
  fi
  FW_ID="$fw_id"
}

echo "[4/7] configuring cloud firewall '$FW_NAME' (allow 443 + $SSH_PORT, drop 22/80 and everything else)"
if ! configure_firewall; then
  FW_ID=""
  echo "WARNING: cloud firewall NOT configured (token lacks firewall permissions?)." >&2
  echo "         Add firewall:create + firewall:read scopes to the DO token, or create the" >&2
  echo "         firewall in the console, then re-run ./deploy.sh to attach it." >&2
fi

# ------------------------------------------------ 5. wait for SSH (22022)
echo "[5/7] waiting for sshd on port $SSH_PORT and cloud-init completion (up to ~20 min on small droplets)..."
SSH_OK=0
for i in $(seq 1 120); do
  if ssh "${ssh_opts[@]}" -o ConnectTimeout=5 "$DEPLOY_USER@$IP" \
      'cloud-init status | grep -q "^status: done"' 2>/dev/null; then
    SSH_OK=1
    break
  fi
  if [ $((i % 12)) -eq 0 ]; then
    echo "    ...still waiting ($((i * 10 / 60)) min elapsed)"
  fi
  sleep 10
done
[ "$SSH_OK" = 1 ] || {
  echo "FATAL: ssh not reachable on $IP:$SSH_PORT after 20 min." >&2
  echo "       Check progress via the DO console (root): cloud-init status; tail /var/log/cloud-init-output.log" >&2
  exit 1
}

# ------------------------------------------------------------ 5. verify
echo "[6/7] verification (no admin privileges required):"
ssh "${ssh_opts[@]}" "$DEPLOY_USER@$IP" "SSH_PORT=$SSH_PORT bash -s" <<'EOF'
echo "  units:"
systemctl is-active ssh xray fail2ban | sed 's/^/    /'
echo "  listeners:"
ss -tln | grep -E ":($SSH_PORT|443)\b" | sed 's/^/    /'
echo "  bootstrap output (tail):"
tail -n 12 /var/log/cloud-init-output.log | sed 's/^/    /'
EOF

# ------------------------------------------------------------ 6. report
echo "[7/7] done."
echo
echo "=== DEPLOYMENT COMPLETE ==="
echo "Droplet: $DROPLET_NAME  ($DROPLET_ID)  IP: $IP"
if [ -n "${FW_ID:-}" ]; then
  echo "Cloud firewall: $FW_NAME ($FW_ID) - allows 443 + $SSH_PORT only"
else
  echo "Cloud firewall: NOT configured (see warning above; re-run to attach once token has firewall scopes)"
fi
echo "SSH (remote access, no sudo):"
echo "    ssh -p $SSH_PORT -i $DEPLOY_DIR/keys/deploy_user_ed25519 $DEPLOY_USER@$IP"
echo "Admin (local only, full sudo - via DO console root, then su - $ADMIN_USER):"
echo "    console -> root -> su - $ADMIN_USER"
echo
echo "=== CLIENT CONNECTION PARAMETERS (also saved at /home/$DEPLOY_USER/client-params.txt) ==="
ssh "${ssh_opts[@]}" "$DEPLOY_USER@$IP" "cat /home/$DEPLOY_USER/client-params.txt" | sed "s|<server-ip>|$IP|"