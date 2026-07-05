# ──────────────────────
# Stage 1: build opencode from source
# ──────────────────────
FROM docker.io/oven/bun:debian AS builder

# Pin opencode to a release tag for reproducible builds.
# Override with: docker build --build-arg OPENCODE_REF=v1.17.13 ...
# Bump this default when upgrading the worker to a newer opencode release.
ARG OPENCODE_REF=v1.17.13

WORKDIR /build

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

RUN git clone --depth 1 --branch "${OPENCODE_REF}" https://github.com/sst/opencode.git /build/opencode

WORKDIR /build/opencode
RUN bun install --frozen-lockfile || bun install

WORKDIR /build/opencode/packages/sdk/js
# The bridge imports @opencode-ai/sdk/v2 from THIS build's output. Do not hide
# its errors (no `2>/dev/null`); a build-time import assertion in the runtime
# stage below turns a broken build into a failed image instead of a worker that
# only dies on first boot.
RUN bun run build || echo "WARNING: @opencode-ai/sdk build reported errors (import-verified in runtime stage)"

WORKDIR /build/opencode/packages/app
RUN bun run build 2>/dev/null || true

WORKDIR /build/opencode/packages/opencode
# Build only the native platform target. opencode's build.ts (script/build.ts)
# otherwise cross-compiles 12 targets (linux/darwin/win32 × arm64/x64 ×
# musl/baseline variants), each a separate Rust compile pulling fresh toolchains.
# `--single` filters allTargets to the current host's os/arch (and skips the
# baseline + musl variants), which is the only binary the worker ever loads —
# the image is distributed same-host via podman save|load, never cross-arch.
# See docs/proposals/OPENCODE-WORKER-SINGLE-TARGET-BUILD.md for full rationale.
RUN bun run build -- --single 2>/dev/null || true

# ──────────────────────
# Stage 2: runtime image
# ──────────────────────
FROM docker.io/oven/bun:debian AS runtime

LABEL org.opencontainers.image.title="LunarWing OpenCode Worker" \
      org.opencontainers.image.description="Persistent opencode worker with WebSocket agent communication" \
      org.opencontainers.image.version="1.0.0"

# WITH_TOOLCHAINS=false (default): slim runtime — no Rust/Go/C++ toolchains.
# The opencode binary is already built in the builder stage; these are only
# needed if coding tasks inside the container must compile native code.
# Pass --build-arg WITH_TOOLCHAINS=true for the fat image (CI, dev tenants).
# Also gates the heavy -dev packages and build tools (cmake, clang, llvm, etc.)
# which are only needed to compile native dependencies at runtime.
ARG WITH_TOOLCHAINS=false

# Runtime packages: always installed (needed by the worker itself).
RUN set -e; \
    (apt-get update 2>/dev/null || { \
      echo "apt-get update failed — switching to snapshot.debian.org fallback mirror" >&2; \
      sed -i 's|debian\.org|snapshot.debian.org/archive|g' /etc/apt/sources.list; \
      apt-get update 2>/dev/null || apt-get update -o Acquire::AllowInsecureRepositories=true; \
    }) && \
    apt-get install -y --no-install-recommends \
      tini \
      python3 \
      python3-pip \
      python3-venv \
      git \
      ripgrep \
      curl \
      wget \
      ca-certificates \
      openssh-client \
      jq \
      neovim \
    && rm -rf /var/lib/apt/lists/*

# Toolchain packages: only when WITH_TOOLCHAINS=true.
RUN if [ "${WITH_TOOLCHAINS}" = "true" ]; then \
      set -e; \
      (apt-get update 2>/dev/null || { \
        echo "apt-get update failed — switching to snapshot.debian.org fallback mirror" >&2; \
        sed -i 's|debian\.org|snapshot.debian.org/archive|g' /etc/apt/sources.list; \
        apt-get update 2>/dev/null || apt-get update -o Acquire::AllowInsecureRepositories=true; \
      }) && \
      apt-get install -y --no-install-recommends \
        python3-dev \
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
      && rm -rf /var/lib/apt/lists/*; \
    fi

# ── GitHub CLI ─────────────────
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ── Rust toolchain (only with WITH_TOOLCHAINS=true) ───────────────────
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH

RUN if [ "${WITH_TOOLCHAINS}" = "true" ]; then \
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain 1.92.0 \
      && chmod -R a+r /usr/local/rustup /usr/local/cargo; \
    fi

# ── Go toolchain (only with WITH_TOOLCHAINS=true) ──────────────────────
RUN if [ "${WITH_TOOLCHAINS}" = "true" ]; then \
      ARCH=$(dpkg --print-architecture) \
      && curl -fsSL "https://go.dev/dl/go1.24.3.linux-${ARCH}.tar.gz" \
        | tar -C /usr/local -xz; \
    fi
ENV GOROOT=/usr/local/go \
    GOPATH=/home/opencode/go \
    PATH=/usr/local/go/bin:/home/opencode/go/bin:$PATH

# ── non-root user ──────────────────────
RUN groupadd -r opencode && useradd -r -g opencode -m -d /home/opencode opencode

# ── app layout ─────────────────
WORKDIR /app

COPY --from=builder /build/opencode /app/opencode

COPY --chown=opencode:opencode entrypoint.sh health_server.py agent_comm_protocol.json ./
COPY --chown=opencode:opencode scripts/ ./scripts/
COPY --chown=opencode:opencode config/ ./config/

RUN chmod +x /app/entrypoint.sh /app/health_server.py

RUN ln -s /app/opencode/node_modules /app/node_modules

# Fail the BUILD (not container startup) if the bridge's SDK import can't
# resolve — the `bun run build` steps above are best-effort, so verify the exact
# import the worker depends on. Without this a broken/renamed SDK passes
# `docker build` and only surfaces as a module-resolution error when the bridge
# starts inside the running container.
RUN cd /app && bun -e 'import("@opencode-ai/sdk/v2").then(m => { if (typeof m.createOpencodeClient !== "function") { console.error("FATAL: @opencode-ai/sdk/v2 resolved but is missing createOpencodeClient"); process.exit(1) } }).catch(e => { console.error("FATAL: cannot import @opencode-ai/sdk/v2 —", e.message); process.exit(1) })'

# ── XDG directories for opencode state ────────────────────────
RUN mkdir -p /home/opencode/.local/share/opencode \
             /home/opencode/.config/opencode \
             /workspace \
             /var/log/lunarwing \
             /app/results \
    && chown -R opencode:opencode /home/opencode /workspace /var/log/lunarwing /app/results

# ── ports ──────────────────────
EXPOSE 8443
EXPOSE 9090

# ── health check ───────────────────────
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -sf http://127.0.0.1:8443/health || exit 1

USER opencode

ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]
CMD ["--mode", "websocket"]
