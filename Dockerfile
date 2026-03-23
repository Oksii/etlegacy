# Build stage: ET base files, configs, and ET Legacy binary
FROM debian:stable-slim AS builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
        git \
        unzip \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /legacy/server

RUN mkdir -p etmain/mapscripts legacy && \
    curl -SL "https://cdn.splashdamage.com/downloads/games/wet/et260b.x86_full.zip" -o /tmp/et_full.zip && \
    cd /tmp && \
    unzip -q et_full.zip && \
    chmod +x et260b.x86_keygen_V03.run && \
    sh et260b.x86_keygen_V03.run --tar xf && \
    cp /tmp/etmain/pak*.pk3 /legacy/server/etmain/ && \
    rm -rf /tmp/et_full.zip /tmp/et260b.x86_keygen_V03.run /tmp/etmain

RUN git clone --depth 1 --single-branch "https://github.com/Oksii/legacy-configs.git" settings && \
    mkdir -p /legacy/homepath

# ETLegacy
ARG STATIC_URL_AMD64
ARG STATIC_URL_ARM64
ARG TARGETARCH

RUN if [ "$TARGETARCH" = "arm64" ]; then \
        echo "Downloading ARM64 version..." && \
        curl -SL "${STATIC_URL_ARM64}" | tar xz --strip-components=1; \
    else \
        echo "Downloading AMD64 version..." && \
        curl -SL "${STATIC_URL_AMD64}" | tar xz --strip-components=1; \
    fi && \
    mv etlded.$(arch) etlded && \
    mv etlded_bot.$(arch).sh etlded_bot.sh

# Go build stage: compile entrypoint and autorestart binaries
FROM --platform=$BUILDPLATFORM golang:1.22-alpine AS go-builder

WORKDIR /build

COPY go.mod .
COPY src/ src/

ARG TARGETOS=linux
ARG TARGETARCH=amd64

RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -ldflags="-s -w" -o start ./src/entrypoint/ && \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -ldflags="-s -w" -o autorestart ./src/autorestart/

# Final stage
FROM debian:stable-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git \
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -Ms /bin/bash legacy

COPY --from=builder --chown=legacy:legacy /legacy /legacy/
COPY --chown=legacy:legacy vendor/dkjson.lua /legacy/server/legacy/dkjson.lua
COPY --from=go-builder --chmod=755 --chown=legacy:legacy /build/start /legacy/server/start
COPY --from=go-builder --chmod=755 --chown=legacy:legacy /build/autorestart /legacy/server/autorestart

VOLUME ["/legacy/homepath", "/legacy/server/etmain"]
WORKDIR /legacy/server

EXPOSE 27960/udp
USER legacy

ENTRYPOINT ["./start"]
