# Config changing

## The edit-then-build flow

The config files are plain files in the repo, baked into the image by `COPY` in the Dockerfile:

```dockerfile
# opencode4lunarwing/Dockerfile:119-121
COPY --chown=opencode:opencode entrypoint.sh health_server.py agent_comm_protocol.json ./
COPY --chown=opencode:opencode scripts/ ./scripts/
COPY --chown=opencode:opencode config/ ./config/
```

So the editable files are:

| File | Purpose | Edit to change |
|------|---------|----------------|
| `opencode4lunarwing/config/opencode.json` | opencode's runtime config (model, provider, plugins, MCP) | Default model, providers, plugins, MCP servers |
| `opencode4lunarwing/entrypoint.sh` | Container startup (config override logic, SSH, opencode server launch) | Override behavior, env var handling |
| `opencode4lunarwing/scripts/*.ts` | The bridge + executor + runtime (the WebSocket protocol) | Worker behavior, task execution, honest-result logic |
| `opencode4lunarwing/health_server.py` | The `/health` + `/ready` endpoints | Health reporting |
| `opencode4lunarwing/agent_comm_protocol.json` | The `lunarwing-agent-v1` message schema | Protocol shape |

**Workflow to change any of them:**

```bash
# 1. Edit the file in the repo
$EDITOR opencode4lunarwing/config/opencode.json   # or whichever

# 2. Rebuild the image (use --no-cache only if you changed something COPY'd
#    that Docker might otherwise serve from cache; config changes usually
#    invalidate the COPY layer automatically, but --no-cache is safest)
sudo ic/scripts/lunarwing-mt-admin.sh build-opencode-worker --no-cache

# 3. Restart the tenant so the new image syncs into its rootless store and
#    the container is force-recreated
sudo ic/scripts/lunarwing-mt-admin.sh stop-tenant <name>
sudo ic/scripts/lunarwing-mt-admin.sh start-tenant <name>
```

## The nuance: per-tenant overrides vs baked defaults

This is the part worth understanding so you don't get confused later. There are **two layers** of config, and they interact:

1. **Baked defaults** (in `config/opencode.json`, applied to *every* tenant at boot unless overridden).
2. **Per-tenant overrides** (via `OPENCODE_MODEL` / `OPENCODE_BASE_URL` env vars, set by `configure-opencode`).

At container startup, `entrypoint.sh:73-96` does this:

```
if OPENCODE_MODEL or OPENCODE_BASE_URL is set:
    → read baked config, apply overrides, write to /workspace/.opencode/opencode.json
else:
    → symlink baked config as-is to /workspace/.opencode/opencode.json
```

So:

- **Edit the baked `config/opencode.json`** to change the *default* everyone gets (e.g. the model we just fixed, default plugins, MCP servers).
- **Use `configure-opencode <tenant> --model ...`** for a *per-tenant* change without rebuilding (e.g. pointing one tenant at a different model).

**Gotcha:** if a tenant has `OPENCODE_MODEL` set (via `configure-opencode`), editing the baked `config/opencode.json`'s `model` field **won't affect that tenant** — the override branch wins. That's by design (per-tenant takes precedence), but it's the thing most likely to confuse someone who edits the baked config and wonders why one tenant didn't change.

## When you need `--no-cache` vs not

- **Changed `config/`, `scripts/`, `entrypoint.sh`, `health_server.py`** → Docker *usually* detects the COPY source changed and rebuilds from that layer. `--no-cache` not strictly required, but harmless and safer.
- **Changed `Dockerfile` build args (e.g. `OPENCODE_REF`)** or anything in the builder stage → `--no-cache` to be safe, otherwise Docker may reuse cached builder layers that don't reflect your change.
- **Only changed the Rust/TS source that opencode's own `bun run build` compiles** → those are pinned to `OPENCODE_REF`, so you'd change the ref, and `--no-cache` is needed.

## Quick reference for a user

The cleanest mental model to document (and maybe I should add a short section to `opencode4lunarwing/README.md`):

> **To change worker defaults for all tenants:** edit `opencode4lunarwing/config/opencode.json` (or `entrypoint.sh` / `scripts/`), then `build-opencode-worker --no-cache` + restart tenants.
>
> **To change one tenant's model/endpoint without rebuilding:** `configure-opencode <tenant> --model <fn> --base-url <url>` + restart that tenant. This sets env vars that `entrypoint.sh` applies at boot, overriding the baked defaults.
