FROM rust:1.92-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends git && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Build the bridge binary
COPY pebble4lunarwing/Cargo.toml pebble4lunarwing/Cargo.lock ./bridge/
COPY pebble4lunarwing/src ./bridge/src
RUN cd bridge && cargo build --release

# Build pebble
RUN git clone --depth 1 https://github.com/nanogpt-community/pebble.git ./pebble
RUN cd pebble && cargo build --release --bin pebble

# --- Runtime ---
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git curl && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/bridge/target/release/pebble4lunarwing /usr/local/bin/pebble4lunarwing
COPY --from=builder /build/pebble/target/release/pebble /usr/local/bin/pebble
COPY pebble4lunarwing/entrypoint.sh /usr/local/bin/entrypoint.sh

RUN mkdir -p /workspace && chmod 777 /workspace

ENV PEBBLE_BIN=/usr/local/bin/pebble \
    PEBBLE_MODE=websocket \
    WS_PORT=9090 \
    HEALTH_PORT=8443 \
    WORKSPACE_ROOT=/workspace

EXPOSE 9090 8443

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -sf http://127.0.0.1:8443/health || exit 1

ENTRYPOINT ["entrypoint.sh"]
