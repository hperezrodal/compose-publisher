# compose-publisher

CLI tool for deploying docker-compose stacks to VPS servers. One command to build, transfer, and deploy.

```bash
compose-publisher deploy backend --env prod
```

## What it does

1. **Builds** Docker images from git repos or local directories
2. **Transfers** images to VPS via `docker save | ssh | docker load`
3. **Deploys** with targeted service recreation (no full stack downtime)
4. **Manages** .env files on remote hosts

## Prerequisites

- **bash** 4.0+
- **Docker** 20.10+
- **SSH** access to your VPS
- [bash-library](https://github.com/hperezrodal/bash-library) (installed automatically by install.sh)
- [yq](https://github.com/mikefarah/yq) v4+ (installed automatically by install.sh)

## Installation

```bash
git clone https://github.com/hperezrodal/compose-publisher.git
cd compose-publisher
sudo bash install.sh
```

Or run directly from the repo:

```bash
./bin/compose-publisher --help
```

## Quick Start

### 1. Create `compose-publisher.yml` in your project

```yaml
environments:
  dev:
    host: 10.0.0.10
    user: root
    ssh_key: ~/.ssh/id_deploy
    branch: develop
    env_file: .env.dev
    compose_files:
      - docker-compose.yml

  prod:
    host: 10.0.0.20
    user: root
    ssh_key: ~/.ssh/id_deploy
    branch: main
    env_file: .env.prod
    compose_files:
      - docker-compose.yml
      - docker-compose.prod.yml

components:
  backend:
    source: ./backend               # local directory (monorepo)
    dockerfile: Dockerfile
    target: production               # multi-stage target (optional)
    compose_service: backend         # service name in docker-compose.yml

  api:
    source: git@github.com:org/api.git  # git repo (multi-repo)
    dockerfile: Dockerfile
    compose_service: api
```

### 2. Set up a VPS

```bash
compose-publisher setup --env prod
```

Installs Docker, UFW, fail2ban, swap, log rotation, unattended-upgrades, and hardens SSH.

### 3. Deploy

```bash
# Deploy one component
compose-publisher deploy backend --env prod

# Deploy all components
compose-publisher deploy --all --env dev
```

### 4. Manage secrets

```bash
# Push local .env to VPS
compose-publisher env push --env prod

# Pull .env from VPS
compose-publisher env pull --env prod
```

## CLI Reference

```
compose-publisher <command> [options]

Commands:
  build     <component> --env <env>     Build a Docker image
  deploy    <component> --env <env>     Build + transfer + deploy to VPS
  setup     --env <env>                 Set up a VPS (Docker, firewall, etc.)
  env       push|pull --env <env>       Transfer .env files to/from VPS
  ssh       <env>                       SSH into a configured host

Options:
  --env <env>       Target environment (required)
  --all             Deploy all components (deploy only)
  --help            Show help
  --version         Show version
```

## Config Reference

### `environments.<name>`

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `host` | yes | — | VPS IP or hostname |
| `user` | no | `root` | SSH user |
| `ssh_key` | yes | — | Path to SSH private key |
| `branch` | yes | — | Git branch to build from |
| `env_file` | no | — | Local path to .env file |
| `compose_files` | no | — | List of docker-compose files |
| `deploy_path` | no | `~/deployment` | Remote base directory. Deploy creates `{deploy_path}/{stack}/` on VPS |

### `components.<name>`

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `source` | yes | — | Git URL or local path (`./dir`) |
| `dockerfile` | no | `Dockerfile` | Dockerfile path (relative to source), **or** a bare template name (see below) |
| `context` | no | `.` | Docker build context |
| `target` | no | — | Multi-stage build target |
| `compose_service` | yes | — | Service name in docker-compose.yml |
| `stack` | no | `default` | Stack identifier. Deploy creates `{deploy_path}/{stack}/` on VPS |
| `platform` | no | `linux/amd64` | Docker build platform |
| `args` | no | — | Build args (key-value map) |

### Dockerfile templates

`dockerfile:` accepts either a path or a **bare template name** (no `/`,
no `.`, not the literal `Dockerfile`). A template name is resolved in
order:

1. **Consumer override** — `<config_dir>/dockerfiles/<name>.Dockerfile`
   (next to your `compose-publisher.yml`)
2. **Built-in template** — `templates/dockerfiles/<name>.Dockerfile`
   shipped with compose-publisher

This lets reusable Dockerfiles live with the tool and be shared across
projects, while a consumer can shadow one when it needs something
specific. The build context stays the app source repo.

```yaml
components:
  web:
    source: git@github.com:acme/web.git
    dockerfile: nextjs        # built-in, unless overridden locally
    compose_service: web
```

Paths (anything with `/` or `.`) keep the previous behavior unchanged.

### Deploy path behavior

The `deploy` command places files at `{deploy_path}/{stack}/` on the VPS:

```
deploy_path: ~/deployment  +  stack: apps   →  ~/deployment/apps/
deploy_path: ~/deployment  +  stack: proxy  →  ~/deployment/proxy/
```

The `env push/pull` commands use `{deploy_path}/` directly (no stack suffix). To push .env to the same directory as deploy, set `deploy_path` to include the stack:

```yaml
# If your project has a single stack, set deploy_path explicitly:
deploy_path: ~/deployment/apps
```

### Deploy lifecycle hooks + notifier

Optional. With none of these keys present, deploy behaves exactly as
before (fully backward compatible).

```yaml
components:
  web:
    source: git@github.com:org/web.git
    compose_service: web
    post_deploy:                 # runs after the service is healthy
      run: scripts/smoke.sh      # path; for where=runner, inside the source clone
      where: runner              # runner (default) | host
      timeout: 120               # seconds (default 300)
    hook_env:                    # extra env for this component's hooks
      SMOKE_PATHS: "/,/health"
  db-app:
    source: git@github.com:org/app.git
    compose_service: app
    pre_deploy:                  # runs BEFORE any build/transfer/up
      run: scripts/backup-db.sh
      where: host                # ssh to the env host; script may docker exec
      timeout: 600

environments:
  prod:
    # ...
    hook_env:                    # base env injected into all hooks
      SMOKE_BASE_URL: https://example.com
    wait_healthy: auto           # auto (default: wait iff healthcheck) | true | false
    health_timeout: 150          # seconds
    notify:                      # outcome reporter (finalizer)
      run: scripts/notify.sh     # generic command you provide
      on: [success, failed, aborted]
```

Lifecycle order:

```
pre_deploy → build → transfer → up → wait-healthy → post_deploy → notify
```

- **`pre_deploy`** runs before any mutation. Failure aborts the deploy
  (nothing built/changed) with exit code **8**.
- **wait-healthy** waits for the recreated `compose_service` to be
  Docker-healthy before `post_deploy` (no-op if it has no healthcheck);
  timeout ⇒ exit **10**.
- **`post_deploy`** runs after healthy; failure ⇒ exit **9** (distinct
  from build/transfer/deploy 2/3/4/5, so CI can tell "deployed but
  gate failed" from "deploy failed"). No automatic rollback.
- **Hook interface (frozen):** input via env vars only — merged
  `hook_env` (env-level + component override) plus `CP_COMPONENT`,
  `CP_ENV`, `CP_BRANCH`, `CP_IMAGE`, `CP_TAG`, `CP_COMPOSE_SERVICE`,
  `CP_HOST`, `CP_HOOK_PHASE`. Output via exit code (0 = pass).
- **`notify`** is a finalizer: runs **always** with the terminal
  status (`success|failed|aborted`), whatever stage failed. The
  command receives `CP_STATUS`, `CP_FAILED_STAGE`, `CP_EXIT_CODE`,
  `CP_DURATION_S` (+ the hook context/env). It is **non-blocking** —
  a notifier failure never changes the exit code or stalls the deploy.

## How it works

```
compose-publisher deploy backend --env prod

1. READ    compose-publisher.yml → env=prod, host=10.0.0.20, branch=main
2. BUILD   docker build --target production -t backend:main.abc123
3. TRANSFER docker save backend:main.abc123 | ssh root@10.0.0.20 docker load
4. DEPLOY  scp .env.prod + docker-compose.yml → VPS
           ssh: docker compose up -d --no-deps --force-recreate backend
5. LOG     Append to ~/.compose-publisher/deploy-history.log on VPS
```

## Branch-to-Environment Mapping

Each environment has a `branch` field. When using GitHub Actions, the workflow auto-resolves which environment to deploy to based on the current branch:

```
push to develop → env=dev  → deploys to dev VPS
push to main    → env=prod → deploys to prod VPS
```

## HTTPS with Traefik

compose-publisher includes a Traefik template for automatic HTTPS via Let's Encrypt.

### 1. Setup creates the proxy network

`compose-publisher setup --env prod` creates a `proxy` Docker network on the VPS (along with Docker, firewall, registry, etc.).

### 2. Copy the Traefik template to your project

```bash
cp -r /path/to/compose-publisher/templates/proxy deployment/proxy/
echo "ACME_EMAIL=you@example.com" > deployment/proxy/.env
```

### 3. Deploy Traefik

```bash
compose-publisher deploy proxy --env prod
```

### 4. Add labels to your services

```yaml
# Your docker-compose.yml
services:
  backend:
    image: localhost:5000/backend:latest
    labels:
      - traefik.enable=true
      - traefik.http.routers.backend.rule=Host(`api.example.com`)
      - traefik.http.routers.backend.entrypoints=websecure
      - traefik.http.routers.backend.tls.certresolver=letsencrypt
      - traefik.http.services.backend.loadbalancer.server.port=3000
    networks:
      - proxy
      - default

networks:
  proxy:
    external: true
```

Traefik auto-discovers services via Docker labels, handles HTTP→HTTPS redirect, and renews certificates automatically.

## Examples

See [`examples/`](examples/) for complete config files:
- [`monorepo.yml`](examples/monorepo.yml) — Multiple services in one repo
- [`multi-repo.yml`](examples/multi-repo.yml) — Each service in its own git repo
- [`with-traefik.yml`](examples/with-traefik.yml) — Project with Traefik HTTPS proxy
- [`with-blockchain.yml`](examples/with-blockchain.yml) — Project with private dev blockchain

See [`templates/`](templates/) for reusable stack templates:
- [`templates/proxy/`](templates/proxy/) — Traefik reverse proxy with Let's Encrypt
- [`templates/blockchain/`](templates/blockchain/) — Geth private dev chain + Blockscout explorer
- [`templates/ipfs/`](templates/ipfs/) — IPFS node (Kubo) for decentralized storage

## License

MIT
