# Build stage
FROM debian:stable-slim AS builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
        git \
        unzip \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Second layer: ET base files
WORKDIR /legacy/server
RUN mkdir -p etmain/mapscripts && \
    mkdir -p /legacy/server/etmain && \
    curl -SL "https://cdn.splashdamage.com/downloads/games/wet/et260b.x86_full.zip" -o /tmp/et_full.zip && \
    cd /tmp && \
    unzip -q et_full.zip && \
    chmod +x et260b.x86_keygen_V03.run && \
    sh et260b.x86_keygen_V03.run --tar xf && \
    cp /tmp/etmain/pak*.pk3 /legacy/server/etmain/ && \
    rm -rf /tmp/et_full.zip /tmp/et260b.x86_keygen_V03.run /tmp/etmain

# Config files
RUN git clone --depth 1 --single-branch "https://github.com/Oksii/legacy-configs.git" settings && \
    mkdir -p /legacy/homepath

# ET Legacy files
ARG STATIC_URL
RUN curl -SL "${STATIC_URL}" | tar xz --strip-components=1 && \
    mv etlded.$(arch) etlded && \
    mv etlded_bot.$(arch).sh etlded_bot.sh

COPY --chmod=755 entrypoint.sh ./start
COPY --chmod=755 autorestart.sh ./autorestart

# Final stage
FROM debian:stable-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        wget \
        git \
        qstat \
        curl \
        ca-certificates \
        parallel \
    && wget -q https://github.com/icedream/icecon/releases/download/v1.0.0/icecon_linux_amd64 -O /bin/icecon && \
    chmod +x /bin/icecon && \
    mkdir -p /legacy/server/legacy && \
    wget -q https://raw.githubusercontent.com/LuaDist/dkjson/master/dkjson.lua -O /legacy/server/legacy/dkjson.lua && \
    rm -rf /var/lib/apt/lists/* && \
    useradd -Ms /bin/bash legacy

# Copy files from builder
COPY --from=builder --chown=legacy:legacy /legacy /legacy/

# Configure volumes and working directory
VOLUME ["/legacy/homepath", "/legacy/server/etmain"]
WORKDIR /legacy/server

# Expose port and set user
EXPOSE 27960/UDP
USER legacy

# Set entrypoint
ENTRYPOINT ["./start"]