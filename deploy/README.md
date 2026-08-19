# VLESS REALITY Proxy — Hardened Deployment

Deploys a single hardened Ubuntu 24.04 droplet (DigitalOcean, `sgp1`, cheapest size)
running Xray-core with a VLESS + REALITY inbound on `443`, camouflaged as
`m365.cloud.microsoft`.

## Account model (dual-account)

| User | Access | Privilege |
|---|---|---|
| `deploy-user` | SSH only (port `SSH_PORT`, Ed25519 key) | **Zero** — no sudo, not in sudo group |
| `admin-user` | Local only (DO web console → root → `su - admin-user`) | Full sudo, NOPASSWD |

Both usernames are configurable via `DEPLOY_USER` / `ADMIN_USER` (see `.env.example`).
`admin-user` is blocked from SSH at sshd level (`AllowUsers`/`DenyUsers`), has no
password, and is only reachable from the console.

## Security posture

| Control | Implementation |
|---|---|
| Root SSH login | disabled (`PermitRootLogin no`) |
| SSH keys only | Ed25519, generated locally, `PasswordAuthentication no` |
| Remote access account | `deploy-user` — key-only SSH, no sudo (`sudo: null`) |
| Admin account | `admin-user` — full sudo, local only (SSH-blocked) |
| Custom SSH port | `SSH_PORT` (default 22022), rate-limited via `ufw limit` |
| Firewall | UFW default `deny incoming`, whitelist 443 + `SSH_PORT` only |
| Brute force | fail2ban: `sshd` jail + custom `xray-reality` jail on 443 |
| Patching | `unattended-upgrades` (security only) + auto-reboot 04:00 |
| Bloat removal | telnet/rsh/ftp/nfs/rpcbind/avahi/cups/snapd/compilers purged |
| Kernel | reverse-path filter, no redirects/source-route, syncookies |
| Secrets | REALITY keys + UUID generated **on the server**; stored `/usr/local/etc/xray/real.env` (0600). Nothing secret is committed or leaves the host. |

## Environment

Copy `deploy/.env.example` → `deploy/.env` (gitignored) and fill in `DO_API_KEY`.
All values are optional except `DO_API_KEY`.

```bash
cd deploy
cp .env.example .env
# edit .env: set DO_API_KEY (and optionally REGION/SIZE/IMAGE/DROPLET_NAME/TAGS/
# DEPLOY_USER/ADMIN_USER/SSH_PORT/REALITY_SNI/REALITY_DEST)
./deploy.sh
```

`deploy.sh` also accepts the same variables as shell env overrides.

## Prerequisites (your machine)

- `curl`, `jq`, `ssh`, `scp`, `ssh-keygen`, `python3` (defaults on macOS)

## Deploy flow

1. Generates Ed25519 keypair into `deploy/keys/` (gitignored)
2. Renders `cloud-init.yml` (splices `xray/` and `fail2ban/` files, injects usernames + pubkey)
3. Creates the droplet with the user-data via the DO API
4. Waits for sshd on `SSH_PORT` + cloud-init completion
5. Verifies services without needing sudo (as `deploy-user`)
6. Prints client connection parameters (also saved at `/home/<deploy-user>/client-params.txt`)

## Client connection parameters

Printed at the end of a successful deploy and stored server-side at
`/home/<deploy-user>/client-params.txt` (0600, owned by `deploy-user`).
Parameters: address/IP, port 443, UUID, flow `xtls-rprx-vision`, security `reality`,
SNI (from `REALITY_SNI`), fingerprint `chrome`, publicKey, shortId.

## Admin operations (rotation, troubleshooting)

Admin work requires the console (remote accounts have zero admin power):

1. DO web console → log in as `root` → `su - <admin-user>`
2. E.g. rotate REALITY keys:
   ```bash
   sudo rm /usr/local/etc/xray/real.env /home/<deploy-user>/client-params.txt
   sudo bash /usr/local/sbin/deploy-xray.sh
   ```
3. Distribute the new params from `/home/<deploy-user>/client-params.txt` (via `deploy-user` SSH read or console)

## Managing client UUIDs (root)

The server authenticates clients by **UUID**: `inbounds[0].settings.clients[]` in
`/usr/local/etc/xray/config.json`. A default UUID is generated at first boot
(`REALITY_UUID` in `/usr/local/etc/xray/real.env`) - that is the existing client.
Adding/removing clients is a root operation (SSH users have zero admin power):

1. DO web console → root → `su - <admin-user>` → `sudo -i`
2. Generate a UUID: `xray uuid` (or `cat /proc/sys/kernel/random/uuid`)
3. Edit `/usr/local/etc/xray/config.json`:
   - **add** a client: insert `{"id": "<new-uuid>", "flow": "xtls-rprx-vision"}`
     into `inbounds[0].settings.clients` (after the existing entries)
   - **remove** a client: delete that client's `{...}` entry
4. Validate before restart: `xray run -test -config /usr/local/etc/xray/config.json`
5. Apply: `systemctl restart xray`

Optional per-client isolation: add a value to `realitySettings.shortIds[]` and hand
that specific shortId to that client only.

Hand a new client these parameters: server IP, port 443, its UUID,
`REALITY_PUBLIC_KEY`, its shortId, `REALITY_SNI` (all visible in
`/usr/local/etc/xray/real.env`).

## Verification

- `ssh -p $SSH_PORT -i deploy/keys/deploy_user_ed25519 <deploy-user>@IP` then:
  - `systemctl is-active ssh xray fail2ban`
  - `ss -tln` → only 443 + `SSH_PORT` listening
  - `tail /var/log/cloud-init-output.log` → bootstrap output
- REALITY dest reachable: `curl -I https://m365.cloud.microsoft` (should answer like a normal site)
- `sudo ufw status verbose` / `sudo fail2ban-client status` → console as `admin-user`

## Troubleshooting

- **Locked out of SSH**: DO console as `root` (DO emails the root password at creation;
  SSH-registered keys are irrelevant since the hardening config only allows `deploy-user`).
- **xray-reality jail never bans**: inspect `sudo tail -f /var/log/xray/access.log`
  (console), then adjust `/etc/fail2ban/filter.d/xray-reality.conf` and
  `sudo fail2ban-client reload`.
- **Cloud-init failures**: `tail -100 /var/log/cloud-init-output.log`.

## File map

```
deploy/
├── deploy.sh                    # orchestrator (keygen → render → droplet → verify → report)
├── cloud-init.yml               # OS hardening + dual accounts + bootstrap ({{...}} markers)
├── .env.example                 # required/optional env vars (copy to .env, gitignored)
├── .env                         # YOUR secrets - never commit
├── xray/
│   ├── config.json.template     # VLESS+REALITY config ($VAR placeholders, no secrets)
│   └── xray.service             # hardened systemd unit (User=xray, ProtectSystem=strict, …)
├── fail2ban/
│   ├── jail.local               # sshd + xray-reality jails
│   └── filter.d/xray-reality.conf
├── keys/                        # generated at deploy time — GITIGNORED
└── .generated/                  # rendered cloud-init — GITIGNORED
```
