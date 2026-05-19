# =============================================================================
# compose-publisher built-in template: pure-static + nginx
# =============================================================================
# Reusable Dockerfile for repos that contain pre-built static assets (HTML,
# CSS, JS, images) — no build step. Referenced as `dockerfile: static-nginx`.
# A consumer can shadow it with <config_dir>/dockerfiles/static-nginx.Dockerfile
# when it needs something specific.
#
# Build context is the app source repo. The whole context is copied into
# /usr/share/nginx/html. Optional `nginx.conf` at the repo root overrides
# the default conf.d/default.conf.
# =============================================================================

ARG NGINX_IMAGE=nginx:alpine

# Get git commit hash from build context (for build_info)
FROM alpine/git AS git-stage
WORKDIR /app
COPY . .
RUN git rev-parse HEAD > /app/build_commit.txt 2>/dev/null || echo "unknown" > /app/build_commit.txt

FROM ${NGINX_IMAGE} AS runner
LABEL maintainer="hperezrodal <hperezrodal@gmail.com>"
LABEL description="Template Dockerfile for pure-static + nginx (no build step)"
LABEL version="1.0.0"

# Copy the entire source repo as the static root. The consumer can ignore
# files via a .dockerignore in the source repo (e.g. .git, README.md).
COPY . /usr/share/nginx/html/

# Optional consumer nginx config. Wildcard: if present, overrides the
# default conf.d/default.conf; if absent, stock conf serves the static root.
COPY nginx.conf* /etc/nginx/conf.d/default.conf

# Build info (read-only friendly)
COPY --from=git-stage /app/build_commit.txt /etc/build_commit.txt
RUN BUILD_DATETIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ") && \
    BUILD_COMMIT=$(cat /etc/build_commit.txt) && \
    echo "BUILD_DATETIME=${BUILD_DATETIME}" >  /etc/build_info && \
    echo "BUILD_COMMIT=${BUILD_COMMIT}"     >> /etc/build_info

# Pre-create writable dirs for read_only consumer containers with tmpfs
RUN mkdir -p /var/cache/nginx /var/run /tmp/nginx \
    && chown -R nginx:nginx /var/cache/nginx /var/run /tmp/nginx /usr/share/nginx/html

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -qO- --spider http://127.0.0.1/ >/dev/null 2>&1 || exit 1
