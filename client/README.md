# VLESS REALITY Client (macOS / Linux)

Local SOCKS **and** HTTP proxy that tunnels all traffic through the deployed
VLESS+REALITY server. Uses `xray-core` - the same binary as the server.

```
client/
├── .env.example           # all options (copy to .env)
├── config.json.template   # SOCKS + HTTP inbounds, VLESS/REALITY outbound
├── start.sh               # render config from .env, run xray (foreground)
├── stop.sh                # stop the client
├── status.sh              # is it running? are the proxy ports up?
└── fetch-params.sh        # pull connection params from the server into .env
```

Everything lives in `client/` - `.env` and `.generated/` are gitignored and
per-machine. This directory can be copied to any macOS/Linux machine and run
there independently; it does not need the deploy machine or its SSH key.

## 1. Install xray-core

No dependencies other than `curl` (and `unzip` if downloading manually) - config
rendering and fetching are pure shell (`bash`).

### macOS

```bash
# Homebrew (recommended)
brew install xray

# or manual download (no brew):
curl -LO "https://github.com/XTLS/Xray-core/releases/latest/download/xray-macos-$(uname -m).zip"
unzip xray-macos-$(uname -m).zip -d xray-tmp
sudo mv xray-tmp/xray /usr/local/bin/
rm -rf xray-tmp xray-macos-$(uname -m).zip
```

### Linux (Debian / Ubuntu)

```bash
# Official installer (detects distro/arch)
sudo bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# or manual download:
curl -LO "https://github.com/XTLS/Xray-core/releases/latest/download/xray-linux-$(uname -m).zip"
unzip xray-linux-$(uname -m).zip -d xray-tmp
sudo mv xray-tmp/xray /usr/local/bin/
rm -rf xray-tmp xray-linux-$(uname -m).zip
```

Verify: `xray version` should print a version.

## 2. Get the connection parameters

Two ways - pick whichever fits:

### A. Auto-fetch from the server (recommended)

Only needs SSH access to the server from *this* machine (as `deploy-user`):

```bash
cd client
cp .env.example .env
# edit .env: set SERVER_ADDR (the droplet IP) and SSH_KEY (path to a private
# key that can log in as deploy-user on THIS machine - see key note below)
./fetch-params.sh
```

`fetch-params.sh` connects to the server, reads the stored parameters
(`/home/deploy-user/client-params.txt`), and fills `SERVER_ADDR`, `SERVER_PORT`,
`UUID`, `REALITY_PUBLIC_KEY`, `REALITY_SHORT_ID`, `REALITY_SNI` into `.env`.
It prompts interactively for `SERVER_ADDR`/`SSH_KEY` if they are not set.

**About the SSH key:** the deploy machine's key (`deploy/keys/deploy_user_ed25519`)
is gitignored and stays on the deploy machine. To use this client machine you
either copy that key over securely (e.g. `scp` from the deploy machine), or add
a new public key to the server's `deploy-user` (root console →
edit `/home/deploy-user/.ssh/authorized_keys`).
`SSH_KEY` in `.env` may be absolute or relative to the `client/` directory
(e.g. `../deploy/keys/deploy_user_ed25519`).

### B. Manual

Copy the values from the deploy machine's deploy output, or from the server via
the root console (`cat /home/deploy-user/client-params.txt`), and paste them
into `.env` yourself.

## 3. Run

```bash
./start.sh      # renders client/.generated/config.json, runs xray in foreground
./status.sh     # running? SOCKS/HTTP ports listening?
./stop.sh       # stop the client
```

## 4. Route traffic through the proxy

Two local endpoints are exposed (both tunnel to the server):

| Endpoint | URL | Use for |
|---|---|---|
| SOCKS | `socks5://127.0.0.1:1080` | anything (curl, browsers, apps) |
| HTTP | `http://127.0.0.1:1081` | apps that only support HTTP proxies |

One-off tests:

```bash
curl -x socks5h://127.0.0.1:1080 https://ipinfo.io/ip
curl -x http://127.0.0.1:1081 https://ipinfo.io/ip
```

Whole terminal session (macOS/Linux):

```bash
export all_proxy=socks5h://127.0.0.1:1080
```

Or point your app/browser's proxy setting at `127.0.0.1:1080` (SOCKS) or
`127.0.0.1:1081` (HTTP).

## Troubleshooting

- `xray: command not found` in start.sh -> xray-core not in PATH (step 1)
- Connection fails -> re-check the 5 required fields in `.env` against
  `client-params.txt` (UUID / publicKey / shortId / SNI must match the server);
  re-run `./fetch-params.sh`
- `fetch-params.sh` fails to connect -> wrong `SSH_PORT`/`SSH_KEY`, or the key is
  not authorized for `deploy-user` (see section 2A)
- SOCKS/HTTP port already in use -> change `SOCKS_PORT`/`HTTP_PORT` in `.env`
- Wrong REALITY dest on server -> update `REALITY_SNI` on both server and client
