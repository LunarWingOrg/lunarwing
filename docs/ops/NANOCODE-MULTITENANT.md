# Nanocode Worker: Multi-Tenant Setup

Guide for deploying the nanocode external worker in a multi-tenant LunarWing environment.

## Prerequisites

- Multi-tenant deployment via `lunarwing-mt-admin.sh` (tenant already created)
- Docker or Podman available
- Port registry at v3 or later (current is v5); `nanocode_wss` allocated per tenant at offset +7

Verify port allocation:

```bash
jq '.tenants.<TENANT>.ports.nanocode_wss' /etc/lunarwing/ports.json
```

## Step 1: Build the Image

The nanocode worker image is shared across all tenants. Build once (re-run the same command
to **rebuild** after a nanocode or source update):

```bash
sudo ic/scripts/lunarwing-mt-admin.sh build-nanocode-worker
```

Or manually:

```bash
cp -R nanocode-config/nanocode lunarcode4lunarwing/nanocode
sudo docker build -t lunarwing-worker-nanocode:latest lunarcode4lunarwing/
```

**DNS issues during build:** If `rustup` or `npm` fail with DNS errors inside Docker, add DNS servers:

```bash
sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
{"dns": ["1.1.1.1", "8.8.8.8"]}
EOF
sudo systemctl restart docker
```

## Step 2: Start the Container

The `start-tenant` command automatically starts the nanocode container if the image exists:

```bash
sudo ic/scripts/lunarwing-mt-admin.sh start-tenant <TENANT>
```

Or start manually (replace `<TENANT>`, `<WSS_PORT>`, and optionally `<GATEWAY_TOKEN>`):

```bash
sudo docker run -d \
  --name "lunarwing-nanocode-<TENANT>" \
  -e LUNARWING_WORKER_ID="worker-nanocode-<TENANT>" \
  -e WS_PORT="<WSS_PORT>" \
  -e HEALTH_PORT="0" \
  -e NANOCODE_MODE=websocket \
  -e WS_ROLE=server \
  -e WS_BIND_HOST=0.0.0.0 \
  -e WS_PATH=/ws/agent \
  -e AGENT_AUTH_TOKEN="<GATEWAY_TOKEN>" \
  -p "127.0.0.1:<WSS_PORT>:<WSS_PORT>" \
  -v "/home/<TENANT>/lunarwing/nanocode-workspace:/workspace:z" \
  --restart unless-stopped \
  lunarwing-worker-nanocode:latest \
  --mode websocket
```

Get the gateway token from the tenant env:

```bash
grep '^GATEWAY_AUTH_TOKEN=' /home/<TENANT>/lunarwing/env/lunarwing.env
```

## Step 3: Configure the Daemon

Add the external worker to the tenant's `config.toml` at `$LUNARWING_BASE_DIR/config.toml`:

```bash
# Find the base dir
grep LUNARWING_BASE_DIR /home/<TENANT>/lunarwing/env/lunarwing.env
```

Edit (or create) `config.toml`. The `[[sandbox.external_workers]]` entry **must** come after all `[sandbox]` key-value pairs:

```toml
[sandbox]
enabled = true
policy = "workspace_write"
timeout_secs = 599
memory_limit_mb = 4096
cpu_shares = 1024
image = "lunarwing-worker:latest"
auto_pull_image = true
extra_allowed_domains = []
acp_enabled = false

[[sandbox.external_workers]]
name = "nanocode"
url = "ws://127.0.0.1:<WSS_PORT>/ws/agent"
auth_token = "<GATEWAY_TOKEN>"
timeout_ms = 400000
```

**Critical TOML ordering:** `[[sandbox.external_workers]]` must appear after all scalar fields under `[sandbox]`. TOML does not allow returning to a table header after an array-of-tables entry.

## Step 4: Restart the Tenant

```bash
sudo ic/scripts/lunarwing-mt-admin.sh stop-tenant <TENANT> && sudo ic/scripts/lunarwing-mt-admin.sh start-tenant <TENANT>
```

## Step 5: Verify

Check the daemon logs for the ready message:

```bash
sudo machinectl shell <TENANT>@.host /bin/journalctl --user -u lunarwing-<TENANT> --since "1 min ago" --no-pager | grep -i "external worker"
```

You should see:

```
External worker 'nanocode' ready (worker_id=worker-nanocode-<TENANT>)
```

Check the container is running:

```bash
sudo docker ps | grep nanocode-<TENANT>
sudo docker logs lunarwing-nanocode-<TENANT> --tail 10
```

Expected bridge output:

```
[bridge] server listening on ws://0.0.0.0:<WSS_PORT>/ws/agent
[bridge] subprotocol: ironclaw-agent-v1
```

## Step 6: Test

Send a job to the agent:

```
/job Write a Python script that prints the first 20 Fibonacci numbers, run it, show output --mode nanocode
```

Verify execution happened in the container:

```bash
sudo docker exec lunarwing-nanocode-<TENANT> ls /workspace/
```

## Troubleshooting

### Daemon uses built-in sandbox instead of nanocode

**Symptom:** Logs show `Created and started worker container` instead of external worker dispatch.

**Cause:** `config.toml` not parsed correctly. Usually TOML ordering: `[[sandbox.external_workers]]` placed before or mixed with `[sandbox]` scalar fields.

**Fix:** Ensure all `[sandbox]` key-value pairs come before any `[[sandbox.external_workers]]` entries.

### "External workers configured" never appears in logs

- Verify `config.toml` is at the correct `LUNARWING_BASE_DIR` path
- Restart the tenant (daemon only reads config on startup)
- Check for TOML parse errors in full startup logs

### Container starts but worker never shows "ready"

- Check `docker logs lunarwing-nanocode-<TENANT>` for errors
- Verify the WSS port matches between container `-p` flag and `config.toml` URL
- If auth is enabled, ensure `AGENT_AUTH_TOKEN` in the container matches `auth_token` in `config.toml`

### Shell execution fails with "Permission denied" inside nanocode

This usually means the job went to the **built-in sandbox worker** (not nanocode). Verify the external worker is configured by checking for the "ready" log message. If it's missing, fix the `config.toml`.

### DNS failures during image build

Docker containers may not resolve DNS inside builds. Fix by adding DNS to the Docker daemon config (see Step 1).

### `nanocode_wss` port not allocated

The `nanocode_wss` port (offset +7) is allocated from port-registry **v3 onward** (current is
v5). The admin script auto-migrates on `add-tenant`/`build-tenant`. To migrate a standalone
registry to the current version, run the migration scripts in order:

```bash
sudo ic/scripts/migrate-ports-v3.sh
sudo ic/scripts/migrate-ports-v4.sh
sudo ic/scripts/migrate-ports-v5.sh
```

### Known nanocode startup warning

```
WARN  failed to install dependencies
error: @nanogpt/plugin@* failed to resolve
```

This is non-fatal. The plugin is already bundled in the image at `/app/nanocode/node_modules/@nanogpt/plugin`. Nanocode attempts a redundant `bun install` on startup but the tools still work without it.
