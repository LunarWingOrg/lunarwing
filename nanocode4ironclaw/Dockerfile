# ──────────────────────────────────────────────────────────────────────────────
# Stage 1: build nanocode from source
# ──────────────────────────────────────────────────────────────────────────────
FROM oven/bun:1.3-debian AS builder

WORKDIR /build

# System deps for native addons (tree-sitter, bun-pty)
RUN apt-get update && apt-get install -y --no-install-recommends \
      git python3 make g++ ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy nanocode monorepo source
COPY nanocode/ ./nanocode/

# Install dependencies and build the opencode package
WORKDIR /build/nanocode
RUN bun install --frozen-lockfile || bun install

# Build the SDK (needed by the bridge)
WORKDIR /build/nanocode/packages/sdk/js
RUN bun run build 2>/dev/null || true

# Build the opencode package
WORKDIR /build/nanocode/packages/opencode
RUN bun run build 2>/dev/null || true

# ──────────────────────────────────────────────────────────────────────────────
# Stage 2: runtime image
# ──────────────────────────────────────────────────────────────────────────────
FROM oven/bun:1.3-debian AS runtime

LABEL org.opencontainers.image.title="IronClaw Nanocode Worker" \
      org.opencontainers.image.description="Persistent nanocode worker with WebSocket agent communication" \
      org.opencontainers.image.version="1.0.0"

# ── system packages ────────────────────────────────────────────────────────────
# tini      : PID-1 signal reaping
# python3   : health server (reused from codex4ironclaw)
# git       : nanocode needs git for project context
# ripgrep   : nanocode grep tool dependency
# curl      : readiness checks in entrypoint
RUN apt-get update && apt-get install -y --no-install-recommends \
      tini \
      python3 \
      git \
      ripgrep \
      curl \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ── non-root user ──────────────────────────────────────────────────────────────
RUN groupadd -r nanocode && useradd -r -g nanocode -m -d /home/nanocode nanocode

# ── app layout ─────────────────────────────────────────────────────────────────
WORKDIR /app

# Copy built nanocode
COPY --from=builder /build/nanocode /app/nanocode

# Copy worker scripts and config
COPY --chown=nanocode:nanocode entrypoint.sh health_server.py agent_comm_protocol.json ./
COPY --chown=nanocode:nanocode scripts/ ./scripts/
COPY --chown=nanocode:nanocode config/ ./config/

# Ensure scripts are executable
RUN chmod +x /app/entrypoint.sh /app/health_server.py

# ── XDG directories for nanocode state ────────────────────────────────────────
RUN mkdir -p /home/nanocode/.local/share/nanocode \
             /home/nanocode/.config/nanocode \
             /workspace \
             /var/log/ironclaw \
             /app/results \
    && chown -R nanocode:nanocode /home/nanocode /workspace /var/log/ironclaw /app/results

# ── ports ──────────────────────────────────────────────────────────────────────
# 8443 : health-check HTTP endpoint
# 9090 : inbound IronClaw WebSocket server (server role)
EXPOSE 8443
EXPOSE 9090

# ── health check ───────────────────────────────────────────────────────────────
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -sf http://127.0.0.1:8443/health || exit 1

USER nanocode

ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]
CMD ["--mode", "websocket"]
