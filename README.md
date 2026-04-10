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
| `dockerfile` | no | `Dockerfile` | Dockerfile path (relative to source) |
| `context` | no | `.` | Docker build context |
| `target` | no | — | Multi-stage build target |
| `compose_service` | yes | — | Service name in docker-compose.yml |
| `stack` | no | `default` | Stack identifier. Deploy creates `{deploy_path}/{stack}/` on VPS |
| `platform` | no | `linux/amd64` | Docker build platform |
| `args` | no | — | Build args (key-value map) |

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
