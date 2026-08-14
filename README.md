# DeepSeek Harness Web Docker

> [English](README.md) | [中文](README.zh.md)

Containerized deployment of the [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (dsh) web client: a single container bundles dsh + Caddy Basic Auth, with configuration and project/session data persisted, and CI automatically pushes GHCR images.

## Features

- Self-contained single container: dsh (loopback only, inside the container) + Caddy username/password Basic Auth
- Configuration and project/session data persisted: bind mount `./data` → `/home/node/.dsh` (settings.yaml, API Key, profiles, sessions, storages)
- Runs as non-root (uid 1000); dsh is not exposed directly
- Pinnable image version: build argument `DSH_VERSION`
- CI automatically builds and pushes `ghcr.io/xidong-ai/deepseek-harness-web-docker` (latest + date-time-hash tags)
- A scheduled CI job checks the dsh upstream daily: on a new version it bumps `DSH_VERSION`, builds and smoke-tests the image, pushes to master on success, or opens an Issue on failure (a failed version is not retried automatically while its Issue is open; manual dispatch bypasses the gate)

## Quick Start

### Option 1: Use the GHCR image

```bash
git clone https://github.com/Xidong-AI/deepseek-harness-web-docker
cd deepseek-harness-web-docker
cp .env.example .env    # edit DSH_AUTH_USER / DSH_AUTH_PASSWORD / DEEPSEEK_API_KEY
docker compose up -d    # pull the latest image and start
```

### Option 2: Build locally

```bash
docker compose up -d --build
# or pin a dsh version:
docker build --build-arg DSH_VERSION=0.1.0-rc.6 -t dsh-web:latest .
```

After startup, open `http://<host>:3080` in a browser (the port is controlled by `DSH_WEB_PORT` in `.env`) and enter the Basic Auth username and password.

## Environment Variables (.env)

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `DSH_AUTH_USER` | Yes | `admin` | Basic Auth username |
| `DSH_AUTH_PASSWORD` | Yes | None | Basic Auth plaintext password (bcrypt hash generated automatically at container startup) |
| `DEEPSEEK_API_KEY` | Yes | None | DeepSeek API Key (referenced by the provider via apiKeyEnv) |
| `DSH_WEB_PORT` | No | `3080` | Host port exposed to the outside (change it when it conflicts with an existing service) |
| `DSH_TRUSTED_HOSTS` | No | Empty | Comma-separated extra trusted hosts, injected into the profile's `cordis.patch.yml`; by default Caddy rewrites Host/Origin to loopback, which covers normal access |
| `DSH_VERSION` | No (build-time) | `0.1.0-rc.6` | dsh version; rebuild with `--build` after changing it |

> `.env` contains passwords and the API Key — never commit it to the repository.

## Data Persistence

All configuration and data is stored in `./data/` under the project directory (git-ignored):

- `settings.yaml`: dsh configuration (auto-generated from the default template on first startup)
- `.credentials.yaml`: credentials (e.g. API Keys configured via the web UI)
- `profiles/web/`: web profile (auto-initialized by dsh on first startup)
- `sessions/`, `storages/`: session and project data

Deleting the container does not affect the data; configuration is preserved after upgrades.

## Upgrading

```bash
docker compose pull && docker compose up -d   # when using the GHCR image
# or rebuild locally:
docker compose build && docker compose up -d
```

## In-Container Tools & Environment

dsh agents run commands inside the container through the bash tool; the available toolset = what's preinstalled in the image + **tools the agent installs itself (x-cmd)**.

### Preinstalled in the image

- Runtime: node 22, npm, pnpm (corepack, required by `dsh plugin`), python3, Caddy, dsh
- Agent tools: git, openssh-client, curl/wget (network), jq/yq (JSON/YAML), ripgrep (search), rsync (sync), procps (processes), zip/unzip/tar, file, dig, sqlite3, python3-pip, vim-tiny, ca-certificates

### Agent self-installation (x-cmd, no root required)

The image ships [x-cmd](https://x-cmd.com) (auto-installed to the data volume on first startup; idempotent; Alibaba Cloud OSS source). Inside a dsh session you can run:

```bash
x env use git python jq       # install/enable tools (no root)
x env ls                      # list enabled tools
x env which jq                # show tool path
x jq . data.json              # call with x prefix (always available)
jq . data.json                # bare command: enabled packages are symlinked to /usr/local/bin, directly usable
```

- Install location: `~/.x-cmd.root` (inside the data volume `./data`), **preserved across container restart/rebuild**
- The `x` command and enabled tools are automatically symlinked to `/usr/local/bin` (the agent's bash PATH is fixed; the symlink is the only entry point)
- Newly installed tools are invoked with the `x <pkg>` prefix in the current session; bare commands become available after the container restarts
- Tools come from the x-cmd package source (Alibaba Cloud OSS, reachable from mainland China) and support version management (`x env use node=v20`)

For the in-container agent environment guide, see `AGENTS.md` in the data volume (auto-loaded by dsh sessions).


System packages that require root (build toolchain like gcc/make, editors, etc.): modify the `apt-get install` line in the `Dockerfile` and rebuild, or add a layer on top of this image:

```dockerfile
FROM ghcr.io/xidong-ai/deepseek-harness-web-docker:latest
RUN apt-get update && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*
```

## Changing the Password

Edit `DSH_AUTH_PASSWORD` in `.env`, then run `docker compose up -d` (the entrypoint regenerates the hash automatically).

## Acknowledgements

Thanks to the [Linux.do](https://linux.do) community for support.