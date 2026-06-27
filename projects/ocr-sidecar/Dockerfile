# syntax=docker/dockerfile:1.7

# ---- Build stage ---------------------------------------------------------
FROM rust:1.92-slim-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        libtesseract-dev \
        libleptonica-dev \
        libssl-dev \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release

# ---- Runtime stage -------------------------------------------------------
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        tesseract-ocr \
        tesseract-ocr-eng \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /app/target/release/lunarwing-ocr-sidecar /app/lunarwing-ocr-sidecar

EXPOSE 8088 8089

HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=5s \
    CMD curl -f http://localhost:8089/health || exit 1

CMD ["/app/lunarwing-ocr-sidecar"]
