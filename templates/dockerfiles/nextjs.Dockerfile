# =============================================================================
# compose-publisher built-in template: Next.js
# =============================================================================
# Reusable Dockerfile for Next.js apps. Referenced from a consumer config as
# `dockerfile: nextjs`. A consumer can shadow it with a local
# <config_dir>/dockerfiles/nextjs.Dockerfile when it needs something specific.
#
# Build context is the app source repo; this Dockerfile lives with the tool.
# Resolves the npm optional-deps bug (npm/cli#4828) for Tailwind v4:
# npm ci --include=optional + pinned install of the native
# lightningcss / @tailwindcss/oxide binaries per architecture.
# =============================================================================

# Build arguments for base images
ARG BASE_IMAGE=node:20-alpine
ARG WORKDIR=/app

# Get git commit hash from build context
FROM alpine/git AS git-stage
WORKDIR /app
COPY . .
RUN git rev-parse HEAD > /app/build_commit.txt 2>/dev/null || echo "unknown" > /app/build_commit.txt

# Install dependencies only when needed
FROM ${BASE_IMAGE} AS deps
# Check https://github.com/nodejs/docker-node/tree/b4117f9333da4138b03a546ec926ef50a31506c3#nodealpine to understand why libc6-compat might be needed.
RUN apk add --no-cache libc6-compat
WORKDIR /app

# Add metadata
LABEL maintainer="hperezrodal <hperezrodal@gmail.com>"
LABEL description="Template Dockerfile for Next.js applications"
LABEL version="1.0.0"

# Install dependencies based on the preferred package manager
# Include optional dependencies for native binaries (lightningcss)
COPY package.json yarn.lock* package-lock.json* pnpm-lock.yaml* ./
RUN \
  if [ -f yarn.lock ]; then yarn --frozen-lockfile; \
  elif [ -f package-lock.json ]; then npm ci --include=optional; \
  elif [ -f pnpm-lock.yaml ]; then corepack enable pnpm && pnpm i --frozen-lockfile; \
  else echo "Lockfile not found." && exit 1; \
  fi

# Rebuild the source code only when needed
FROM ${BASE_IMAGE} AS builder
RUN apk add --no-cache libc6-compat
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY package.json package-lock.json* ./
# Install optional native binaries for Tailwind CSS v4 (oxide and lightningcss)
# These are required for Alpine builds but npm may not install them correctly
# due to a known npm bug with optional dependencies (https://github.com/npm/cli/issues/4828)
# Detect architecture and install the correct package variant
ARG TARGETARCH
RUN if [ "$TARGETARCH" = "arm64" ]; then \
      npm install --include=optional \
        @tailwindcss/oxide-linux-arm64-musl@4.1.17 \
        lightningcss-linux-arm64-musl@1.30.2 \
        --no-save || true; \
    elif [ "$TARGETARCH" = "amd64" ]; then \
      npm install --include=optional \
        @tailwindcss/oxide-linux-x64-musl@4.1.17 \
        lightningcss-linux-x64-musl@1.30.2 \
        --no-save || true; \
    else \
      echo "Unsupported architecture: $TARGETARCH" && exit 1; \
    fi
COPY . .

# Next.js collects completely anonymous telemetry data about general usage.
# Learn more here: https://nextjs.org/telemetry
# Uncomment the following line in case you want to disable telemetry during the build.
# ENV NEXT_TELEMETRY_DISABLED=1

# Public API URL — NEXT_PUBLIC_* se inlinea en build time (next build), no
# alcanza con runtime env. Se pasa como build arg (compose-publisher
# components.<x>.args.NEXT_PUBLIC_API_URL). Vacío = no-op (backward compat:
# consumidores que no lo pasan no cambian).
ARG NEXT_PUBLIC_API_URL=""
ENV NEXT_PUBLIC_API_URL=${NEXT_PUBLIC_API_URL}

RUN \
  if [ -f yarn.lock ]; then yarn run build; \
  elif [ -f package-lock.json ]; then npm run build; \
  elif [ -f pnpm-lock.yaml ]; then corepack enable pnpm && pnpm run build; \
  else echo "Lockfile not found." && exit 1; \
  fi

# Production image, copy all the files and run next
FROM ${BASE_IMAGE} AS runner
WORKDIR /app

# Add metadata
LABEL maintainer="hperezrodal <hperezrodal@gmail.com>"
LABEL description="Runtime image for Next.js applications"
LABEL version="1.0.0"

# No instalar wget/curl en runtime - facilita descarga de malware si hay RCE

# Create a non-root user
ARG APP_USER=nextjs
ARG APP_GROUP=nodejs
ARG APP_UID=1001
ARG APP_GID=1001

# Create group and user with proper syntax for Alpine Linux
RUN addgroup -S -g ${APP_GID} ${APP_GROUP} && \
    adduser -S -D -H -h /app -G ${APP_GROUP} -u ${APP_UID} ${APP_USER}

ENV NODE_ENV=production
# Uncomment the following line in case you want to disable telemetry during runtime.
# ENV NEXT_TELEMETRY_DISABLED=1

# Create necessary directories with correct permissions
RUN mkdir -p /app/.next/static && \
    chown ${APP_UID}:${APP_GID} /app && \
    chown ${APP_UID}:${APP_GID} /app/.next && \
    chown ${APP_UID}:${APP_GID} /app/.next/static

COPY --from=builder --chown=${APP_UID}:${APP_GID} /app/public ./public

# Automatically leverage output traces to reduce image size
# https://nextjs.org/docs/advanced-features/output-file-tracing
COPY --from=builder --chown=${APP_UID}:${APP_GID} /app/.next/standalone ./
COPY --from=builder --chown=${APP_UID}:${APP_GID} /app/.next/static ./.next/static

# Copy build commit and entrypoint
COPY --from=git-stage --chown=${APP_UID}:${APP_GID} /app/build_commit.txt build_commit.txt
COPY --chown=${APP_UID}:${APP_GID} docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/docker-entrypoint.sh

# Set build datetime and commit
RUN BUILD_DATETIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ") && \
    BUILD_COMMIT=$(cat /app/build_commit.txt) && \
    echo "export BUILD_DATETIME=${BUILD_DATETIME}" > /etc/profile.d/build_info.sh && \
    echo "export BUILD_COMMIT=${BUILD_COMMIT}" >> /etc/profile.d/build_info.sh && \
    chmod +x /etc/profile.d/build_info.sh && \
    echo "BUILD_DATETIME=${BUILD_DATETIME}" >> /etc/environment && \
    echo "BUILD_COMMIT=${BUILD_COMMIT}" >> /etc/environment

USER ${APP_UID}

EXPOSE 3000

# Health check usando node (sin depender de wget/curl)
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD node -e "const http = require('http'); http.get('http://localhost:3000/', (r) => { process.exit(r.statusCode === 200 ? 0 : 1); }).on('error', () => process.exit(1));"
ENV HOSTNAME="0.0.0.0"

ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["node", "server.js"]