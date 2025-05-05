## Set global build ENV
ARG NODEJS_VERSION="22"

## Base image for all building stages
FROM node:${NODEJS_VERSION}-slim AS base

ARG USE_CN_MIRROR

ENV DEBIAN_FRONTEND="noninteractive"

RUN \
    if [ "${USE_CN_MIRROR:-false}" = "true" ]; then \
        sed -i "s/deb.debian.org/mirrors.ustc.edu.cn/g" "/etc/apt/sources.list.d/debian.sources"; \
    fi \
    # Add required packages
    && apt update \
    && apt install ca-certificates proxychains-ng -qy \
    # Prepare required files for distroless
    && mkdir -p /distroless/bin /distroless/etc /distroless/etc/ssl/certs /distroless/lib \
    # Copy proxychains to distroless
    && cp /usr/lib/$(arch)-linux-gnu/libproxychains.so.4 /distroless/lib/libproxychains.so.4 \
    && cp /usr/lib/$(arch)-linux-gnu/libdl.so.2 /distroless/lib/libdl.so.2 \
    && cp /usr/bin/proxychains4 /distroless/bin/proxychains \
    && cp /etc/proxychains4.conf /distroless/etc/proxychains4.conf \
    # Copy Node.js to distroless
    && cp /usr/lib/$(arch)-linux-gnu/libstdc++.so.6 /distroless/lib/libstdc++.so.6 \
    && cp /usr/lib/$(arch)-linux-gnu/libgcc_s.so.1 /distroless/lib/libgcc_s.so.1 \
    && cp /usr/local/bin/node /distroless/bin/node \
    # Copy CA certificates to distroless
    && cp /etc/ssl/certs/ca-certificates.crt /distroless/etc/ssl/certs/ca-certificates.crt \
    # Cleanup temporary files
    && rm -rf /tmp/* /var/lib/apt/lists/* /var/tmp/*

## Builder image
FROM base AS builder

ARG USE_CN_MIRROR
ARG NEXT_PUBLIC_BASE_PATH
ARG NEXT_PUBLIC_SENTRY_DSN
ARG NEXT_PUBLIC_ANALYTICS_POSTHOG
ARG NEXT_PUBLIC_POSTHOG_HOST
ARG NEXT_PUBLIC_POSTHOG_KEY
ARG NEXT_PUBLIC_ANALYTICS_UMAMI
ARG NEXT_PUBLIC_UMAMI_SCRIPT_URL
ARG NEXT_PUBLIC_UMAMI_WEBSITE_ID

ENV NEXT_PUBLIC_BASE_PATH="${NEXT_PUBLIC_BASE_PATH}"

# Sentry
ENV NEXT_PUBLIC_SENTRY_DSN="${NEXT_PUBLIC_SENTRY_DSN}" \
    SENTRY_ORG="" \
    SENTRY_PROJECT=""

# Posthog
ENV NEXT_PUBLIC_ANALYTICS_POSTHOG="${NEXT_PUBLIC_ANALYTICS_POSTHOG}" \
    NEXT_PUBLIC_POSTHOG_HOST="${NEXT_PUBLIC_POSTHOG_HOST}" \
    NEXT_PUBLIC_POSTHOG_KEY="${NEXT_PUBLIC_POSTHOG_KEY}"

# Umami
ENV NEXT_PUBLIC_ANALYTICS_UMAMI="${NEXT_PUBLIC_ANALYTICS_UMAMI}" \
    NEXT_PUBLIC_UMAMI_SCRIPT_URL="${NEXT_PUBLIC_UMAMI_SCRIPT_URL}" \
    NEXT_PUBLIC_UMAMI_WEBSITE_ID="${NEXT_PUBLIC_UMAMI_WEBSITE_ID}"

# Node.js settings
ENV NODE_OPTIONS="--max-old-space-size=8192"

WORKDIR /app

# Copy package.json and .npmrc
COPY package.json ./
COPY .npmrc ./

# Install dependencies
RUN \
    if [ "${USE_CN_MIRROR:-false}" = "true" ]; then \
        export SENTRYCLI_CDNURL="https://npmmirror.com/mirrors/sentry-cli"; \
        npm config set registry "https://registry.npmmirror.com/"; \
        echo 'canvas_binary_host_mirror=https://npmmirror.com/mirrors/canvas' >> .npmrc; \
    fi \
    && export COREPACK_NPM_REGISTRY=$(npm config get registry | sed 's/\/$//') \
    && corepack enable \
    && corepack use pnpm \
    && pnpm install \
    # Add sharp dependencies to guarantee functionality
    && mkdir -p /deps \
    && pnpm add sharp --prefix /deps

COPY . .

# Build standalone version for Docker
RUN npm run build:docker

## Application image - copying files for production
FROM busybox:latest AS app

# Copy distroless files
COPY --from=base /distroless/ /

# Copy public assets
COPY --from=builder /app/public /app/public

# Copy standalone output with all required files
COPY --from=builder /app/.next/standalone /app/
COPY --from=builder /app/.next/static /app/.next/static
COPY --from=builder /deps/node_modules/.pnpm /app/node_modules/.pnpm

# Copy custom server launcher script
COPY --from=builder /app/scripts/serverLauncher/startServer.js /app/startServer.js

# Create user and set permissions
RUN \
    addgroup -S -g 1001 nodejs \
    && adduser -D -G nodejs -H -S -h /app -u 1001 nextjs \
    && chown -R nextjs:nodejs /app /etc/proxychains4.conf

## Final Production image (Scratch)
FROM scratch

# Copy everything from the app stage
COPY --from=app / /

# Define environment variables
ENV NODE_ENV="production" \
    NODE_OPTIONS="--dns-result-order=ipv4first --use-openssl-ca" \
    NODE_EXTRA_CA_CERTS="" \
    NODE_TLS_REJECT_UNAUTHORIZED="" \
    SSL_CERT_DIR="/etc/ssl/certs/ca-certificates.crt"

# Set hostname and port
ENV HOSTNAME="0.0.0.0" \
    PORT="3210"

# General Variables
ENV ACCESS_CODE="" \
    API_KEY_SELECT_MODE="" \
    DEFAULT_AGENT_CONFIG="" \
    SYSTEM_AGENT="" \
    FEATURE_FLAGS="" \
    PROXY_URL=""

# Model Variables (placeholders for multiple ML APIs)
ENV \
    AI21_API_KEY="" AI21_MODEL_LIST="" \
    OPENAI_API_KEY="" OPENAI_MODEL_LIST="" OPENAI_PROXY_URL=""

# Set the user and expose the port
USER nextjs
EXPOSE 3210/tcp

# Entrypoint and default CMD
ENTRYPOINT ["/bin/node"]
CMD ["/app/startServer.js"]
