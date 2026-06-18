FROM docker.io/oven/bun:debian AS runtime

# ── System packages ───────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    python3 \
    python3-pip \
    ripgrep \
    jq \
    build-essential \
    openssh-client \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ── Node.js (for @openai/codex CLI) ──────────────────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# ── Install @openai/codex globally ───────────────────────────────────────────
RUN npm install -g @openai/codex

# ── Non-root user ─────────────────────────────────────────────────────────────
RUN useradd -m -s /bin/bash -u 1000 codex \
    && mkdir -p /workspace /app/scripts /app/config /home/codex/.codex \
    && chown -R codex:codex /workspace /app /home/codex

# ── Copy application files ────────────────────────────────────────────────────
COPY --chown=codex:codex entrypoint.sh /app/entrypoint.sh
COPY --chown=codex:codex health_server.py /app/health_server.py
COPY --chown=codex:codex agent_comm_protocol.json /app/agent_comm_protocol.json
COPY --chown=codex:codex scripts/ /app/scripts/

RUN chmod +x /app/entrypoint.sh

# ── Runtime configuration ─────────────────────────────────────────────────────
USER codex
WORKDIR /workspace

ENV CODEX_MODE=websocket \
    HEALTH_PORT=8443 \
    WS_PORT=9090 \
    WS_PATH=/ws/agent \
    WS_ROLE=server \
    WORKSPACE_ROOT=/workspace \
    LUNARWING_WORKER_ID=worker-codex-01

EXPOSE 8443 9090

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -sf http://127.0.0.1:8443/health || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["--mode", "websocket"]
