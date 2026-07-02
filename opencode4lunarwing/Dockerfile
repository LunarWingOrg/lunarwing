# ──────────────────────────────────────────────────────────────────────────────
# Stage 1: build opencode from source
# ──────────────────────────────────────────────────────────────────────────────
FROM docker.io/oven/bun:debian AS builder

WORKDIR /build

RUN apt-get update && apt-get install -y --no-install-recommends \
      git python3 make g++ ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/sst/opencode.git /build/opencode

WORKDIR /build/opencode
RUN bun install --frozen-lockfile || bun install

WORKDIR /build/opencode/packages/sdk/js
RUN bun run build 2>/dev/null || true

WORKDIR /build/opencode/packages/app
RUN bun run build 2>/dev/null || true

WORKDIR /build/opencode/packages/opencode
RUN bun run build 2>/dev/null || true

# ──────────────────────────────────────────────────────────────────────────────
# Stage 2: runtime image
# ──────────────────────────────────────────────────────────────────────────────
FROM docker.io/oven/bun:debian AS runtime

LABEL org.opencontainers.image.title="LunarWing OpenCode Worker" \
      org.opencontainers.image.description="Persistent opencode worker with WebSocket agent communication" \
      org.opencontainers.image.version="1.0.0"

RUN apt-get update && apt-get install -y --no-install-recommends \
      tini \
      python3 \
      python3-dev \
      python3-pip \
      python3-venv \
      git \
      ripgrep \
      curl \
      wget \
      ca-certificates \
      build-essential \
      gcc \
      g++ \
      libc-dev \
      binutils \
      cmake \
      ninja-build \
      clang \
      lld \
      llvm \
      pkg-config \
      libssl-dev \
      zlib1g-dev \
      libsqlite3-dev \
      libpq-dev \
      libffi-dev \
      libz-dev \
      liblzma-dev \
      libzstd-dev \
      protobuf-compiler \
      libprotobuf-dev \
      musl-tools \
      libcurl4-openssl-dev \
      libxml2-dev \
      nodejs \
      npm \
      openssh-client \
      jq \
      neovim \
    && rm -rf /var/lib/apt/lists/*

# ── GitHub CLI ─────────────────────────────────────────────────────────────────
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ── Rust toolchain (rustup + cargo + rustc) ────────────────────────────────────
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --default-toolchain 1.92.0 \
    && chmod -R a+r /usr/local/rustup /usr/local/cargo

# ── Go toolchain ───────────────────────────────────────────────────────────────
ENV GOROOT=/usr/local/go \
    GOPATH=/home/opencode/go \
    PATH=/usr/local/go/bin:/home/opencode/go/bin:$PATH
RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://go.dev/dl/go1.24.3.linux-${ARCH}.tar.gz" \
      | tar -C /usr/local -xz

# ── non-root user ──────────────────────────────────────────────────────────────
RUN groupadd -r opencode && useradd -r -g opencode -m -d /home/opencode opencode

# ── app layout ─────────────────────────────────────────────────────────────────
WORKDIR /app

COPY --from=builder /build/opencode /app/opencode

COPY --chown=opencode:opencode entrypoint.sh health_server.py agent_comm_protocol.json ./
COPY --chown=opencode:opencode scripts/ ./scripts/
COPY --chown=opencode:opencode config/ ./config/

RUN chmod +x /app/entrypoint.sh /app/health_server.py

RUN ln -s /app/opencode/node_modules /app/node_modules

# ── XDG directories for opencode state ────────────────────────────────────────
RUN mkdir -p /home/opencode/.local/share/opencode \
             /home/opencode/.config/opencode \
             /workspace \
             /var/log/lunarwing \
             /app/results \
    && chown -R opencode:opencode /home/opencode /workspace /var/log/lunarwing /app/results

# ── ports ──────────────────────────────────────────────────────────────────────
EXPOSE 8443
EXPOSE 9090

# ── health check ───────────────────────────────────────────────────────────────
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -sf http://127.0.0.1:8443/health || exit 1

USER opencode

ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]
CMD ["--mode", "websocket"]
