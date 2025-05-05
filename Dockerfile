## Set global build ENV
ARG NODEJS_VERSION="18"

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
    && cp /etc/ssl/certs/ca-certificates.crt /distroless/etc/ssl/certs/ca-certificates.crt \
    && rm -rf /tmp/* /var/lib/apt/lists/* /var/tmp/*

## Builder image
FROM base AS builder

WORKDIR /app

# Atualizar corepack e instalar pnpm
RUN npm install -g corepack && corepack enable && corepack prepare pnpm@latest --activate

# Configurar mirrors, se necessário
ARG USE_CN_MIRROR
RUN if [ "${USE_CN_MIRROR:-false}" = "true" ]; then \
        npm config set registry "https://registry.npmmirror.com/"; \
        echo 'canvas_binary_host_mirror=https://npmmirror.com/mirrors/canvas' >> .npmrc; \
    fi

# Exibir configurações para debug
RUN echo "Registry configurado: $(npm get registry)"
RUN echo "pnpm versão: $(pnpm --version)"

# Instalar dependências
COPY package.json ./
RUN pnpm install

# Adicionar módulo sharp explicitamente
RUN mkdir -p /deps && pnpm add sharp --prefix /deps

# Copiar arquivos restantes e rodar build standalone
COPY . .
RUN npm run build:docker

## Final production image
FROM scratch

COPY --from=base /distroless/ /
COPY --from=builder /app/.next/standalone /app/
COPY --from=builder /deps/node_modules/.pnpm /app/node_modules/.pnpm

USER nextjs

ENV NODE_ENV="production"
EXPOSE 3210
CMD ["/app/startServer.js"]
