# ──────────────────────
# Stage 1: build nanocode from source
# ──────────────────────
FROM docker.io/oven/bun:debian AS builder

WORKDIR /build

# System deps for native addons (tree-sitter, bun-pty)
# Snapshot fallback helper — tries live mirror first, falls back to
# snapshot.debian.org if live mirror has an invalid signature (e.g. pre-staged
# trixie-security signatures not yet valid for the current UTC window).
RUN set -e; \
    (apt-get update 2>/dev/null || { \
      echo "apt-get update failed — switching to snapshot.debian.org fallback mirror" >&2; \
      sed -i 's|debian\.org|snapshot.debian.org/archive|g' /etc/apt/sources.list; \
      apt-get update 2>/dev/null || apt-get update -o Acquire::AllowInsecureRepositories=true; \
    }) && \
    apt-get install -y --no-install-recommends \
      git python3 make g++ ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Copy nanocode monorepo source
COPY nanocode/ ./nanocode/

# Install dependencies and build the opencode package
WORKDIR /build/nanocode
RUN bun install --frozen-lockfile || bun install

# Build the SDK (needed by the bridge)
WORKDIR /build/nanocode/packages/sdk/js
RUN bun run build 2>/dev/null || true

# Build the app package (required by `serve` command)
WORKDIR /build/nanocode/packages/app
RUN bun run build 2>/dev/null || true

# Build the opencode package
WORKDIR /build/nanocode/packages/opencode
RUN bun run build 2>/dev/null || true

# ──────────────────────
# Stage 2: runtime image
# ──────────────────────
FROM docker.io/oven/bun:debian AS runtime

LABEL org.opencontainers.image.title="LunarWing Nanocode Worker" \
      org.opencontainers.image.description="Persistent nanocode worker with WebSocket agent communication" \
      org.opencontainers.image.version="1.0.0"

# ── system packages ──────────────────────
# tini            : PID-1 signal reaping
# python3 + pip   : health server + installable Python packages
# git             : nanocode needs git for project context
# ripgrep         : nanocode grep tool dependency
# curl/wget       : readiness checks, downloads
# build-essential : C/C++ toolchain (gcc, g++, make, ld)
# cmake/ninja     : build systems for native projects
# clang/lld       : alternative C/C++ compiler and linker
# pkg-config      : library discovery for -sys crates
# lib*-dev        : common Rust crate dependencies (OpenSSL, zlib, SQLite, etc.)
# nodejs + npm    : JavaScript runtime and package manager
# openssh-client  : SSH for git auth and remote access
# jq              : JSON processing
# neovim          : terminal editor
RUN set -e; \
    (apt-get update 2>/dev/null || { \
      echo "apt-get update failed — switching to snapshot.debian.org fallback mirror" >&2; \
      sed -i 's|debian\.org|snapshot.debian.org/archive|g' /etc/apt/sources.list; \
      apt-get update 2>/dev/null || apt-get update -o Acquire::AllowInsecureRepositories=true; \
    }) && \
    apt-get install -y --no-install-recommends \
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

# ── GitHub CLI ─────────────────
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

# ── Go toolchain ───────────────────────
ENV GOROOT=/usr/local/go \
    GOPATH=/home/nanocode/go \
    PATH=/usr/local/go/bin:/home/nanocode/go/bin:$PATH
RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://go.dev/dl/go1.24.3.linux-${ARCH}.tar.gz" \
      | tar -C /usr/local -xz

# ── non-root user ──────────────────────
RUN groupadd -r nanocode && useradd -r -g nanocode -m -d /home/nanocode nanocode

# ── app layout ─────────────────
WORKDIR /app

# Copy built nanocode
COPY --from=builder /build/nanocode /app/nanocode

# Patch fn.ts: safeParse workaround for PartID/SessionID schema mismatch (nanocode v1.2.28)
COPY patches/fn.ts /app/nanocode/packages/opencode/src/util/fn.ts

# Copy worker scripts and config
COPY --chown=nanocode:nanocode entrypoint.sh health_server.py agent_comm_protocol.json ./
COPY --chown=nanocode:nanocode scripts/ ./scripts/
COPY --chown=nanocode:nanocode config/ ./config/

# Ensure scripts are executable
RUN chmod +x /app/entrypoint.sh /app/health_server.py

# Symlink node_modules so bridge scripts can resolve @nanogpt/sdk
RUN ln -s /app/nanocode/node_modules /app/node_modules

# ── XDG directories for nanocode state ────────────────────────
RUN mkdir -p /home/nanocode/.local/share/nanocode \
             /home/nanocode/.config/nanocode \
             /workspace \
              /var/log/lunarwing \
              /app/results \
    && chown -R nanocode:nanocode /home/nanocode /workspace /var/log/lunarwing /app/results

# ── ports ──────────────────────
# 8443 : health-check HTTP endpoint
# 9090 : inbound LunarWing WebSocket server (server role)
EXPOSE 8443
EXPOSE 9090

# ── health check ───────────────────────
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -sf http://127.0.0.1:8443/health || exit 1

USER nanocode

ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]
CMD ["--mode", "websocket"]
