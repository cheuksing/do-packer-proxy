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
| Firewall | **DO cloud firewall** (created by deploy.sh): allows 443 + `SSH_PORT` only, drops 22/80 and everything else. **UFW inside the droplet**: default `deny incoming`, allow 443 + `SSH_PORT` |
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
# edit .env: set DO_API_KEY (and optionally REGION/SIZE/IMAGE/DROPLET_NAME/
# DEPLOY_USER/ADMIN_USER/SSH_PORT/REALITY_SNI/REALITY_DEST)
./deploy.sh
```

`deploy.sh` also accepts the same variables as shell env overrides.

## Prerequisites (your machine)

- `doctl` — DigitalOcean CLI. Install: `brew install doctl` (macOS) or
  [doctl docs](https://docs.digitalocean.com/reference/doctl/how-to/install/) (Linux).
  Auth: run `doctl auth init` once, or just set `DO_API_KEY` in `.env` (deploy.sh
  maps it to `DIGITALOCEAN_ACCESS_TOKEN` for doctl automatically).
- `ssh`, `scp`, `ssh-keygen` (defaults on macOS)

### Required API scopes for the token

A full read/write token covers everything. For a restricted token, these scopes
are needed (from the DO API):

| Scope | Used for |
|---|---|
| `droplet:create` | create the droplet (with cloud-init user-data) |
| `droplet:read` | fetch droplet ID / PublicIPv4, wait for creation |
| `firewall:create` | create the cloud firewall (attached to the droplet at creation) |
| `firewall:read` | look up the firewall by name / check its attached droplets |

A fresh firewall is created per droplet (name `<DROPLET_NAME>-<droplet-id>-fw`,
generated automatically) and attached at creation, so `firewall:update`/
`firewall:add-droplets` are never needed, and no `tag:create` scope is required
(nothing is tagged). Re-running for the same droplet reuses its firewall only if
it already covers that droplet. Orphaned firewalls (after deleting a droplet) are
removed manually in the console, or by deleting them via
`doctl compute firewall delete` (which needs `firewall:delete`).

The firewall step is **best-effort**: if the token lacks `firewall:create`/
`firewall:read`, deploy.sh warns and continues (the droplet is still protected by
UFW inside). Once the scopes are added, re-running `./deploy.sh` (idempotent)
creates the firewall and attaches the droplet.

## Deploy flow

1. Generates Ed25519 keypair into `deploy/keys/` (gitignored)
2. Renders `cloud-init.yml` (splices `xray/` and `fail2ban/` files, injects usernames + pubkey)
3. Creates the droplet with the user-data via `doctl compute droplet create --user-data-file` (reuses the droplet if one with the same name already exists)
4. Best-effort: creates/syncs a DO **cloud firewall** (allows 443 + `SSH_PORT`, drops everything else incl. 22/80) and attaches the droplet
5. Waits for sshd on `SSH_PORT` + cloud-init completion (**up to ~20 min** on the cheapest droplet)
6. Verifies services without needing sudo (as `deploy-user`)
7. Prints client connection parameters (also saved at `/home/<deploy-user>/client-params.txt`)

> Provisioning note: the boot image no longer runs a full `apt upgrade`
> (`package_upgrade: false`), so first boot is fast; security patches arrive via
> `unattended-upgrades` + auto-reboot.

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

- **Locked out of SSH / port timeout at step 5**: two possible causes.
  1. The DO **cloud firewall** governs access before UFW does - if one is attached
     but doesn't allow `SSH_PORT`, the wait times out. Confirm with
     `doctl compute firewall list`. Re-running `deploy.sh` re-syncs rules and
     re-attaches the droplet.
  2. Provisioning is still running (up to ~20 min on the smallest droplet) -
     watch progress from the DO console: `cloud-init status`, `tail /var/log/cloud-init-output.log`.
- **Locked out entirely**: DO console as `root` (DO emails the root password at creation;
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
