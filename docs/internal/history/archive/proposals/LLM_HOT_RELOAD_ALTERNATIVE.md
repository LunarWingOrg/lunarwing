# LLM Config Hot Reload — Engineering Alternatives

**Context:** LunarWing has no native hot-reload for LLM backend config (confirmed by Ruffles). Full daemon restart is not ideal. These are practical workarounds.

---

## Option 1: Stable Local Endpoint + Swappable Upstream (Recommended)

Keep LunarWing/TensorZero pointed at a **stable URL** (localhost or internal VIP). Swap the upstream behind it.

**Patterns:**
- **Local reverse proxy** (nginx/haproxy/caddy) in front of the real LLM endpoint
  - Change upstream target and `reload` the proxy (fast, usually hitless)
- **Envoy** with xDS / dynamic clusters (more complex, very clean)
- **Tiny "LLM shim" service:**
  - Reads a config file (or watches it via inotify)
  - Forwards requests to the chosen backend
  - Can rotate API keys and endpoints live

LunarWing never changes; the shim changes. Matches the OpenClaw reload pattern.

---

## Option 2: A/B TensorZero Gateways

Run **two gateway instances** (A/B) with different configs:
- LunarWing points at a load balancer / VIP
- Drain A, switch to B, update A's config, etc.

No hot reload needed — zero downtime via traffic flip.

---

## Option 3: API Key Indirection (Limited)

If the gateway reads keys from env vars:
- Make the key a **file** mounted into the process (e.g., `/run/secrets/...`)
- Have the client read it per-request

⚠️ Most code reads env once at startup, so this often doesn't help unless the implementation supports file-based key loading.

---

## Open Questions (Need Answers to Pick Best Design)

1. What exactly is being swapped: **endpoint URL**, **API key**, **model name**, or **routing weights**?
2. Where is the config currently defined: LunarWing config, TensorZero config, systemd env, `.env`?
3. Is **zero downtime** required, or is "restart gateway but not the whole daemon" acceptable?
