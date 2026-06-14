# Tenant Configuration Guide

This guide covers how to customize a LunarWing multi-tenant instance after it has been created by `lunarwing-mt-admin.sh`. It is written for both operators (who manage the host) and tenant users (who want to adjust their own settings).

## File Layout

Each tenant's configuration lives under their home directory:

```
/home/<tenant>/lunarwing/
├── env/
│   ├── lunarwing.env       # Main daemon environment (LLM, DB, XMPP, gateway, WASM)
│   ├── xmpp-bridge.env     # XMPP bridge service environment
│   ├── proxy.env           # TensorZero proxy environment
│   └── gotify.json         # Gotify notification settings (optional)
├── state/
│   ├── config.toml         # Daemon settings (auto-seeded on first start)
│   ├── workspace-template/ # Identity files (SOUL.md, IDENTITY.md, etc.)
│   ├── tools/              # Installed WASM tools
│   ├── channels/           # Installed WASM channels
│   └── xmpp/               # OMEMO key store
├── logs/                   # Service log output
└── ic/                     # Repo clone (source + build artifacts)
```

**Priority order**: environment variable > `config.toml` > database settings > compiled defaults.

After changing any env file, restart the affected service for changes to take effect (see [Applying Changes](#applying-changes)).

## LLM Provider Configuration

The LLM backend is configured in `env/lunarwing.env`. By default, tenants route through a per-tenant TensorZero proxy, but you can point directly at any OpenAI-compatible endpoint.

### Setting your API key

The most common post-setup task. Edit `lunarwing.env` and set:

```bash
LLM_API_KEY=sk-your-actual-key-here
```

If using TensorZero as a proxy, the key is passed through to the upstream provider. If pointing directly at an LLM API, this is the key for that provider.

### Switching LLM backends

The default setup routes through a local TensorZero proxy:

```bash
LLM_BACKEND=openai_compatible
LLM_BASE_URL=http://127.0.0.1:<proxy_port>/v1
LLM_MODEL=tensorzero::function_name::lunarwing
```

> `LLM_BASE_URL` can be set at provisioning time with `add-tenant --llm-base-url <url>` (or
> fleet-wide via `LUNARWING_MT_LLM_BASE_URL`) instead of hand-editing it here — useful for
> pointing tenants straight at a gateway or upstream endpoint as the proxy is phased out.

To point directly at OpenAI (bypassing TensorZero):

```bash
LLM_BACKEND=openai
LLM_API_KEY=sk-...
LLM_MODEL=gpt-4o
```

To point at Anthropic:

```bash
LLM_BACKEND=anthropic
LLM_API_KEY=sk-ant-...
LLM_MODEL=claude-sonnet-4-20250514
```

To point at a local Ollama instance:

```bash
LLM_BACKEND=ollama
LLM_BASE_URL=http://127.0.0.1:11434
LLM_MODEL=llama3
```

To point at any OpenAI-compatible endpoint (e.g. LiteLLM, vLLM, OpenRouter):

```bash
LLM_BACKEND=openai_compatible
LLM_BASE_URL=https://your-endpoint.example.com/v1
LLM_API_KEY=your-key
LLM_MODEL=your-model-name
```

### TensorZero proxy configuration

Each tenant has a TensorZero proxy configured in `env/proxy.env`:

```bash
PROXY_PORT=<allocated_port>
PROXY_BIND=127.0.0.1
TENSORZERO_URL=http://192.168.1.157:3000/openai/v1
```

`TENSORZERO_URL` is the upstream TensorZero instance that the per-tenant proxy forwards to. Change this if your TensorZero server is at a different address.

## XMPP Configuration

XMPP settings in `lunarwing.env` control how the tenant connects to the XMPP network:

```bash
XMPP_JID=tenant@xmpp.example.com        # Tenant's XMPP account
XMPP_PASSWORD=...                        # XMPP account password
XMPP_RESOURCE=tenant                     # XMPP resource identifier
XMPP_DM_POLICY=allowlist                 # "allowlist" or "open"
XMPP_ALLOW_FROM=user@xmpp.example.com   # Comma-separated JIDs allowed to DM
XMPP_ALLOW_ROOMS=                        # Comma-separated room JIDs to join
XMPP_ENCRYPTED_ROOMS=                    # Rooms requiring OMEMO encryption
```

### Allowing direct messages

By default, `XMPP_DM_POLICY=allowlist` restricts who can message the agent. Add JIDs to `XMPP_ALLOW_FROM`:

```bash
XMPP_ALLOW_FROM=alice@xmpp.example.com,bob@xmpp.example.com
```

Set `XMPP_DM_POLICY=open` to allow messages from anyone (not recommended for production).

### Joining group chats

```bash
XMPP_ALLOW_ROOMS=room1@conference.xmpp.example.com,room2@conference.xmpp.example.com
```

For OMEMO-encrypted rooms, also add them to:

```bash
XMPP_ENCRYPTED_ROOMS=room1@conference.xmpp.example.com
```

### OMEMO encryption

```bash
XMPP_OMEMO_DEVICE_ID=0                  # Auto-generated on first run
XMPP_OMEMO_STORE_DIR=/home/<tenant>/lunarwing/state/xmpp
XMPP_ALLOW_PLAINTEXT_FALLBACK=true      # Set to false to require encryption
```

The XMPP bridge has its own env file (`xmpp-bridge.env`) that mirrors the JID, password, and bridge token. Both files must agree on `XMPP_BRIDGE_TOKEN`.

## Gateway (Web UI)

```bash
GATEWAY_ENABLED=true
GATEWAY_HOST=127.0.0.1                   # Bind address (127.0.0.1 = local only)
GATEWAY_PORT=<allocated_port>
GATEWAY_AUTH_TOKEN=<auto-generated>       # Required for API/UI access
```

To expose the gateway on all interfaces (e.g. behind a reverse proxy):

```bash
GATEWAY_HOST=0.0.0.0
```

The auth token is generated during tenant creation. To retrieve it:

```bash
grep GATEWAY_AUTH_TOKEN /home/<tenant>/lunarwing/env/lunarwing.env
```

## WASM Extensions

```bash
WASM_ENABLED=true
WASM_CHANNELS_ENABLED=true
WASM_TOOLS_DIR=/home/<tenant>/lunarwing/state/tools
WASM_CHANNELS_DIR=/home/<tenant>/lunarwing/state/channels
```

WASM tools and channels are installed into the tenant's state directory. Disable WASM entirely by setting `WASM_ENABLED=false`.

## Gotify Notifications

If a Gotify server is available, configure it in `env/gotify.json`:

```json
{
  "gotify_url": "https://gotify.example.com",
  "gotify_token": "your-app-token",
  "gotify_title": "TenantName"
}
```

The Gotify WASM tool reads this file at runtime. You can set the URL and title during tenant creation with `--gotify-url` and `--gotify-title`.

## Runtime Behavior

```bash
AGENT_NAME=tenant                        # Display name in conversations
CLI_ENABLED=false                        # Disable interactive CLI (daemon mode)
HEARTBEAT_ENABLED=false                  # Disable periodic background execution
ONBOARD_COMPLETED=true                   # Skip setup wizard
RUST_LOG=lunarwing=info                  # Log verbosity
```

### Enabling heartbeat

The heartbeat system runs proactive periodic tasks. To enable:

```bash
HEARTBEAT_ENABLED=true
```

Then customize `state/workspace-template/HEARTBEAT.md` with instructions for periodic execution.

### Adjusting log verbosity

```bash
RUST_LOG=lunarwing=debug                 # More detail
RUST_LOG=lunarwing=trace                 # Maximum verbosity
RUST_LOG=lunarwing::agent=debug          # Agent loop only
```

## Identity Files

On first start, the daemon seeds `state/workspace-template/` with default identity files from `ic/deploy/workspace-template/`. These are injected into the agent's system prompt:

| File | Purpose |
|------|---------|
| `SOUL.md` | Core personality and behavioral guidelines |
| `IDENTITY.md` | Agent identity, name, and role |
| `AGENTS.md` | Agent rules and constraints |
| `USER.md` | Information about the primary user |
| `HEARTBEAT.md` | Instructions for periodic heartbeat execution |
| `TOOLS.md` | Tool usage guidance |
| `MEMORY.md` | Memory system configuration |

Edit these files to customize the agent's behavior for each tenant. Changes take effect on the next conversation session.

## config.toml

The `state/config.toml` file is auto-seeded on first daemon start. It provides defaults that can be overridden by environment variables. A minimal example:

```toml
llm_backend = "openai_compatible"
selected_model = "tensorzero::function_name::lunarwing"
openai_compatible_base_url = "http://192.168.1.157:3000/openai/v1"

[agent]
name = "tenant"
default_timezone = "America/New_York"
```

Environment variables always take precedence over `config.toml` values.

## Applying Changes

After editing configuration files, restart the affected service. The exact commands depend on your init system.

### Systemd

```bash
# Restart the main daemon
sudo systemctl restart lunarwing-<tenant>.service

# Restart the XMPP bridge
sudo systemctl restart lunarwing-<tenant>-bridge.service

# Restart the TensorZero proxy
sudo systemctl restart lunarwing-<tenant>-proxy.service

# Restart all tenant services
sudo systemctl restart lunarwing-<tenant>.target
```

### OpenRC

```bash
sudo rc-service lunarwing-<tenant> restart
sudo rc-service lunarwing-<tenant>-bridge restart
sudo rc-service lunarwing-<tenant>-proxy restart
```

### Verifying

Check that the service started cleanly:

```bash
# Systemd
sudo journalctl -u lunarwing-<tenant>.service -n 20 --no-pager

# OpenRC
tail -20 /home/<tenant>/lunarwing/logs/lunarwing.log
```

## Operator Reference

### Creating a tenant with custom LLM settings

```bash
sudo ic/scripts/lunarwing-mt-admin.sh add-tenant myagent \
  --docker-group \
  --llm-api-key sk-your-key \
  --tensorzero-url http://your-tz-host:3000/openai/v1 \
  --xmpp-jid myagent@xmpp.example.com \
  --gotify-url https://gotify.example.com
```

### Environment variable overrides for the admin script

These environment variables change the defaults used by `lunarwing-mt-admin.sh` when creating tenants:

| Variable | Default | Description |
|----------|---------|-------------|
| `LUNARWING_MT_TENSORZERO_URL` | `http://192.168.1.157:3000/openai/v1` | Upstream TensorZero URL |
| `LUNARWING_MT_GOTIFY_URL` | (empty) | Default Gotify server URL |
| `LUNARWING_MT_GOTIFY_TITLE` | (empty) | Default Gotify notification title |
| `LUNARWING_MT_SOURCE_REPO` | (auto-detected) | Source repo to clone from |
| `LUNARWING_MT_PROFILE` | `release` | Cargo build profile |

### Port allocation

Each tenant gets a 10-port block from `/etc/lunarwing/ports.json` (range 10000-19999):

| Offset | Service |
|--------|---------|
| +0 | Gateway (web UI) |
| +1 | HTTP webhook |
| +2 | XMPP bridge |
| +3 | PostgreSQL |
| +4 | TensorZero proxy |
| +5 | WeeChat |
| +6 | Orchestrator |
| +7 | Nanocode WSS |
| +8 | Pebble WSS |
| +9 | WeeChat adapter |
