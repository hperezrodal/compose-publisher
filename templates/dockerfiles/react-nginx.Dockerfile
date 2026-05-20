# =============================================================================
# compose-publisher built-in template: React (or any static-build) + nginx
# =============================================================================
# Reusable Dockerfile for SPA/MPA apps that produce a static `build/` (CRA)
# or `dist/` (Vite/Parcel) and are served by nginx. Referenced as
# `dockerfile: react-nginx`. A consumer can shadow it with
# <config_dir>/dockerfiles/react-nginx.Dockerfile when it needs something
# specific.
#
# Build context is the app source repo. Multi-stage:
#   deps    : install dependencies
#   builder : produce the static output (`npm run build`)
#   runner  : nginx:alpine serving the built assets
#
# Optional consumer-supplied files in the source repo root:
#   nginx.conf  → mounted to /etc/nginx/conf.d/default.conf (SPA routing, etc.)
# =============================================================================

ARG BASE_IMAGE=node:20-alpine
ARG NGINX_IMAGE=nginx:alpine
ARG WORKDIR=/app
ARG BUILD_OUTPUT_DIR=build

# Get git commit hash from build context (for build_info)
FROM alpine/git AS git-stage
WORKDIR /app
COPY . .
RUN git rev-parse HEAD > /app/build_commit.txt 2>/dev/null || echo "unknown" > /app/build_commit.txt

# ── deps + builder ──
FROM ${BASE_IMAGE} AS builder
RUN apk add --no-cache libc6-compat
WORKDIR /app
LABEL maintainer="hperezrodal <hperezrodal@gmail.com>"
LABEL description="Template Dockerfile for React+nginx (static-build) apps"
LABEL version="1.0.0"

COPY package.json yarn.lock* package-lock.json* pnpm-lock.yaml* ./
RUN \
  if [ -f yarn.lock ]; then yarn --frozen-lockfile; \
  elif [ -f package-lock.json ]; then npm ci --include=optional; \
  elif [ -f pnpm-lock.yaml ]; then corepack enable pnpm && pnpm i --frozen-lockfile; \
  else echo "Lockfile not found." && exit 1; \
  fi

# Build args inlined into the static bundle (most SPAs need this — REACT_APP_*,
# VITE_*, etc. are baked in at build time). Empty by default = no-op.
ARG REACT_APP_API_URL=""
ENV REACT_APP_API_URL=${REACT_APP_API_URL}
ARG VITE_API_URL=""
ENV VITE_API_URL=${VITE_API_URL}

# Webpack/CRA builds blow past Node's small-host default heap (~512 MB on
# <2 GB hosts) and OOM. Bump the old-space size for the build step. Override
# via components.<x>.args.NODE_BUILD_MEMORY if the runner has more headroom
# or a smaller bundle needs less.
ARG NODE_BUILD_MEMORY=1536
ENV NODE_OPTIONS="--max-old-space-size=${NODE_BUILD_MEMORY}"

COPY . .
RUN \
  if [ -f yarn.lock ]; then yarn run build; \
  elif [ -f package-lock.json ]; then npm run build; \
  elif [ -f pnpm-lock.yaml ]; then corepack enable pnpm && pnpm run build; \
  else echo "Lockfile not found." && exit 1; \
  fi

# ── runner: nginx serving the static bundle ──
FROM ${NGINX_IMAGE} AS runner
ARG BUILD_OUTPUT_DIR=build
LABEL maintainer="hperezrodal <hperezrodal@gmail.com>"
LABEL description="Runtime image (nginx:alpine) for React+nginx apps"
LABEL version="1.0.0"

# Copy static assets. If the consumer's build outputs to `dist/` instead of
# `build/`, override BUILD_OUTPUT_DIR via components.<x>.args.
COPY --from=builder /app/${BUILD_OUTPUT_DIR}/ /usr/share/nginx/html/

# Optional consumer nginx config. Wildcard COPY: if present it overrides the
# default conf.d/default.conf; if absent, nginx:alpine's stock config serves
# /usr/share/nginx/html (SPA routing won't work without try_files — consumers
# that need it should ship an nginx.conf at the repo root).
COPY --from=builder /app/nginx.conf* /etc/nginx/conf.d/default.conf

# Build info (read-only friendly: write before USER switch)
COPY --from=git-stage /app/build_commit.txt /etc/build_commit.txt
RUN BUILD_DATETIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ") && \
    BUILD_COMMIT=$(cat /etc/build_commit.txt) && \
    echo "BUILD_DATETIME=${BUILD_DATETIME}" >  /etc/build_info && \
    echo "BUILD_COMMIT=${BUILD_COMMIT}"     >> /etc/build_info

# nginx:alpine creates `nginx` user (uid 101). Pre-create the dirs nginx
# writes to so a read_only consumer container with tmpfs mounts works.
RUN mkdir -p /var/cache/nginx /var/run /tmp/nginx \
    && chown -R nginx:nginx /var/cache/nginx /var/run /tmp/nginx /usr/share/nginx/html

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -qO- --spider http://127.0.0.1/ >/dev/null 2>&1 || exit 1

# Stock nginx CMD is fine — runs `nginx -g 'daemon off;'` as root by default
# (it drops to `nginx` worker), which is needed to bind :80. Consumers that
# need :8080 + `USER nginx` can shadow this template.
