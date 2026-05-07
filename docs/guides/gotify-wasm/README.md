# LunarWing Gotify WASM Tool

A WASM tool for LunarWing that sends push notifications to a self-hosted Gotify server.

## Build

```bash
cd ironclaw-gotify-tool
cargo build --release --target wasm32-wasip2
cp target/wasm32-wasip2/release/gotify_tool.wasm ~/.lunarwing/tools/gotify.wasm
```

## Installation

1. Copy `gotify.wasm` to `~/.lunarwing/tools/gotify.wasm`
2. Copy `gotify.capabilities.json` alongside it at `~/.lunarwing/tools/gotify.capabilities.json`
3. Store your Gotify app token as a secret named `gotify_app_token`
4. Restart LunarWing to pick up the new tool

## Configuration

### Gotify URL and Title

By default the tool sends notifications to `https://gotify.darkc.sobe.world` with the title `LunarWing`. Both are configurable via the workspace config.

**1. Workspace config** — create `config/gotify.json` in the agent's workspace (`~/.lunarwing/workspace/config/gotify.json`):

```json
{"url": "https://your-gotify.example.com", "title": "My Agent"}
```

The tool appends `/message` automatically, so provide just the base URL. The `title` field is optional — if omitted, the compiled-in default (`LunarWing`) is used. The title serves as the default for notifications when the caller doesn't specify one explicitly.

**2. Capabilities file** — edit `gotify.capabilities.json` to allow HTTP to the new host. Update both the `allowlist` host and the `credentials.host_patterns`:

```json
{
  "capabilities": {
    "http": {
      "allowlist": [
        {
          "host": "your-gotify.example.com",
          "path_prefix": "/"
        }
      ],
      "credentials": {
        "gotify": {
          "secret_name": "gotify_app_token",
          "location": {
            "type": "header",
            "name": "X-Gotify-Key"
          },
          "host_patterns": [
            "your-gotify.example.com"
          ]
        }
      }
    }
  }
}
```

Both changes take effect on restart — no WASM rebuild needed.

If `config/gotify.json` is absent or unparseable, the tool falls back to the compiled-in defaults (URL and title).

### Automated Setup via Scripts

The setup scripts can configure the Gotify URL automatically during provisioning:

**Single-instance** (`setup-instance.sh`):
```bash
scripts/setup-instance.sh --base-dir /srv/lunarwing --gotify-url https://gotify.example.com --gotify-title "My Agent" ...
```
Creates both `workspace/config/gotify.json` and `tools/gotify.capabilities.json` with the custom host. The `--gotify-title` flag is optional.

**Multi-tenant** (`lunarwing-mt-admin.sh`):
```bash
sudo lunarwing-mt-admin.sh add-tenant myagent --gotify-url https://gotify.example.com --gotify-title "My Agent"
```
Creates the workspace config at provisioning time. The capabilities file is automatically rewritten when WASM tools are installed (`install-wasm`).

To reconfigure an existing tenant:
```bash
sudo lunarwing-mt-admin.sh configure-gotify myagent https://new-gotify.example.com "My Agent"
```

**Test harness** (`lunarwing-xmpp-test-env.sh`):

Set `LUNARWING_TEST_GOTIFY_URL` and optionally `LUNARWING_TEST_GOTIFY_TITLE` before running `install-wasm`. URL defaults to `https://gotify.darkc.sobe.world`.

**Environment variables:**

| Variable | Script | Description |
|---|---|---|
| `LUNARWING_MT_GOTIFY_URL` | `lunarwing-mt-admin.sh` | Default Gotify URL for new tenants |
| `LUNARWING_MT_GOTIFY_TITLE` | `lunarwing-mt-admin.sh` | Default Gotify notification title for new tenants |
| `LUNARWING_TEST_GOTIFY_URL` | `lunarwing-xmpp-test-env.sh` | Gotify URL for test harness |
| `LUNARWING_TEST_GOTIFY_TITLE` | `lunarwing-xmpp-test-env.sh` | Gotify notification title for test harness |

### Secrets

The tool requires one secret:

| Secret name | Description |
|---|---|
| `gotify_app_token` | Gotify application token (injected as `X-Gotify-Key` header by the host — never exposed to WASM) |

Use `ic_sm` or `lunarwing config` to store the secret.

## Usage

The agent calls the `gotify` tool with a JSON payload:

```json
{"message": "Deploy complete", "title": "CI", "priority": 8}
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `message` | string | yes | — | Notification body (supports markdown) |
| `title` | string | no | From `config/gotify.json`, or `LunarWing` | Notification title |
| `priority` | integer | no | `3` | 1-3 low, 5-7 medium, 8-10 high |

For routine prompts that use Gotify, see `ic/docs/GOTIFY_ROUTINE_PROMPT.md`.

## How It Works

The tool runs inside the WASM sandbox. It cannot read secrets or environment variables directly. The host runtime:

1. Reads `config/gotify.json` from the workspace when the tool calls `workspace-read`
2. Injects the `gotify_app_token` into the HTTP request's `X-Gotify-Key` header at the host boundary
3. Validates the outbound URL against the capabilities allowlist before sending
