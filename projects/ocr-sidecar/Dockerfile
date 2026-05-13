# syntax=docker/dockerfile:1.7

# ---- Build stage ---------------------------------------------------------
FROM rust:1.75-slim-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        libtesseract-dev \
        libleptonica-dev \
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

COPY --from=builder /app/target/release/lunarwing-ocr-sidecar /usr/local/bin/

EXPOSE 8088

ENV OCR_PORT=8088

USER nobody

CMD ["lunarwing-ocr-sidecar"]
