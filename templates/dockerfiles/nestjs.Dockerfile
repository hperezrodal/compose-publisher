# =============================================================================
# compose-publisher built-in template: NestJS
# =============================================================================
# Reusable Dockerfile for NestJS (Node) API services. Referenced from a
# consumer config as `dockerfile: nestjs`. A consumer can shadow it with
# <config_dir>/dockerfiles/nestjs.Dockerfile when it needs something specific.
#
# Build context is the app source repo. Multi-stage:
#   deps    : install all dependencies (with devDeps for the build)
#   builder : compile TypeScript to dist/ via `npm run build`
#   runner  : minimal runtime — production node_modules + dist + entrypoint
# Defaults to `node dist/main.js` (NestJS standard entrypoint).
# =============================================================================

ARG BASE_IMAGE=node:20-alpine
ARG WORKDIR=/app

# Get git commit hash from build context (for build_info)
FROM alpine/git AS git-stage
WORKDIR /app
COPY . .
RUN git rev-parse HEAD > /app/build_commit.txt 2>/dev/null || echo "unknown" > /app/build_commit.txt

# ── deps: full install (dev + prod) for the build ──
FROM ${BASE_IMAGE} AS deps
RUN apk add --no-cache libc6-compat
WORKDIR /app
LABEL maintainer="hperezrodal <hperezrodal@gmail.com>"
LABEL description="Template Dockerfile for NestJS API services"
LABEL version="1.0.0"
# Optional private-registry auth. Consumers pass NPM_TOKEN via
# components.<x>.args.NPM_TOKEN: ${NPM_TOKEN} (envsubst from the
# runner env). Empty by default — public-package projects are
# unaffected. Exported under BOTH NPM_TOKEN and TOKEN to support
# .npmrc files that reference either name (npm substitutes ${VAR}
# in .npmrc from the process env). NOTE: build args end up in
# image history; for prod hardening switch to BuildKit
# `--mount=type=secret`. The image is built on the CI runner and
# pushed to a host-local registry on the target — not publicly
# distributed — so the layer-history exposure is contained.
ARG NPM_TOKEN=""
ENV NPM_TOKEN=${NPM_TOKEN}
ENV TOKEN=${NPM_TOKEN}
COPY package.json yarn.lock* package-lock.json* pnpm-lock.yaml* .npmrc* ./
RUN \
  if [ -f yarn.lock ]; then yarn --frozen-lockfile; \
  elif [ -f package-lock.json ]; then npm ci --include=optional; \
  elif [ -f pnpm-lock.yaml ]; then corepack enable pnpm && pnpm i --frozen-lockfile; \
  else echo "Lockfile not found." && exit 1; \
  fi

# ── builder: produce dist/ ──
FROM ${BASE_IMAGE} AS builder
RUN apk add --no-cache libc6-compat
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN \
  if [ -f yarn.lock ]; then yarn run build; \
  elif [ -f package-lock.json ]; then npm run build; \
  elif [ -f pnpm-lock.yaml ]; then corepack enable pnpm && pnpm run build; \
  else echo "Lockfile not found." && exit 1; \
  fi

# ── prod-deps: a fresh, production-only node_modules (no devDeps) ──
FROM ${BASE_IMAGE} AS prod-deps
RUN apk add --no-cache libc6-compat
WORKDIR /app
# Same private-registry auth knob as the deps stage.
ARG NPM_TOKEN=""
ENV NPM_TOKEN=${NPM_TOKEN}
ENV TOKEN=${NPM_TOKEN}
COPY package.json yarn.lock* package-lock.json* pnpm-lock.yaml* .npmrc* ./
RUN \
  if [ -f yarn.lock ]; then yarn --frozen-lockfile --production; \
  elif [ -f package-lock.json ]; then npm ci --omit=dev --include=optional; \
  elif [ -f pnpm-lock.yaml ]; then corepack enable pnpm && pnpm i --frozen-lockfile --prod; \
  else echo "Lockfile not found." && exit 1; \
  fi

# ── runner: minimal runtime image ──
FROM ${BASE_IMAGE} AS runner
WORKDIR /app
LABEL maintainer="hperezrodal <hperezrodal@gmail.com>"
LABEL description="Runtime image for NestJS API services"
LABEL version="1.0.0"

# Non-root user
ARG APP_USER=nodeapp
ARG APP_GROUP=nodeapp
ARG APP_UID=1001
ARG APP_GID=1001
RUN addgroup -S -g ${APP_GID} ${APP_GROUP} && \
    adduser -S -D -H -h /app -G ${APP_GROUP} -u ${APP_UID} ${APP_USER}

ENV NODE_ENV=production
ARG APP_PORT=3000
ENV APP_PORT=${APP_PORT}

COPY --from=prod-deps --chown=${APP_UID}:${APP_GID} /app/node_modules ./node_modules
COPY --from=builder   --chown=${APP_UID}:${APP_GID} /app/dist ./dist
COPY --from=builder   --chown=${APP_UID}:${APP_GID} /app/package.json ./package.json
COPY --from=git-stage --chown=${APP_UID}:${APP_GID} /app/build_commit.txt build_commit.txt

# Build info exported to /etc/environment (consumed by entrypoints that source it)
RUN BUILD_DATETIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ") && \
    BUILD_COMMIT=$(cat /app/build_commit.txt) && \
    echo "export BUILD_DATETIME=${BUILD_DATETIME}" >  /etc/profile.d/build_info.sh && \
    echo "export BUILD_COMMIT=${BUILD_COMMIT}"     >> /etc/profile.d/build_info.sh && \
    chmod +x /etc/profile.d/build_info.sh && \
    echo "BUILD_DATETIME=${BUILD_DATETIME}" >> /etc/environment && \
    echo "BUILD_COMMIT=${BUILD_COMMIT}"     >> /etc/environment

USER ${APP_UID}
EXPOSE ${APP_PORT}

# Healthcheck via node (no wget/curl at runtime — minimal attack surface
# on RCE). Assumes the API serves something on / returning 2xx/3xx; tune
# in the consumer's compose if a /health endpoint exists.
HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
    CMD node -e "const http=require('http');http.get('http://127.0.0.1:'+(process.env.APP_PORT||3000)+'/',(r)=>process.exit(r.statusCode<500?0:1)).on('error',()=>process.exit(1));"

ENV HOST="0.0.0.0"
CMD ["node", "dist/main.js"]
