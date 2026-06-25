# DarkIRC Channel for LunarWing — Build & Maintenance Guide

## Directory Layout

```
~/lunarwing/                          ← LunarWing repo (main binary)
├── wit/
│   └── channel.wit                  ← WASM channel interface definition
├── src/
│   └── tools/wasm/
│       └── host.rs                  ← Patched: localhost HTTP allowed
├── channels-src/
│   └── darkirc/                     ← DarkIRC channel project
│       ├── build.sh
│       ├── Cargo.toml               ← [workspace] at end, wit-bindgen = "0.36"
│       ├── darkirc.capabilities.json
│       ├── src/
│       │   └── lib.rs               ← WASM channel source
│       └── adapter/
│           ├── darkirc_adapter.py   ← IRC-to-HTTP bridge (Python, no deps)
│           ├── darkirc-adapter.service
│           └── Containerfile
└── target/release/lunarwing          ← Main binary (rebuild only for lunarwing patches)

~/.lunarwing/                         ← LunarWing runtime data
├── .env                             ← Bootstrap config (DATABASE_BACKEND, LLM_*, etc.)
├── lunarwing.db                      ← SQLite database (workspace, pairing, history)
└── channels/
    ├── darkirc.wasm                 ← Compiled WASM channel (copied after build)
    └── darkirc.capabilities.json    ← Channel config (copied after changes)
```

## What Lives Where

| Thing | Location | When to touch |
|-------|----------|---------------|
| WASM channel source | `channels-src/darkirc/src/lib.rs` | Changing channel behavior |
| Capabilities JSON | `channels-src/darkirc/darkirc.capabilities.json` | Changing permissions, polling, allowlist |
| Adapter source | `channels-src/darkirc/adapter/darkirc_adapter.py` | Changing IRC behavior, message limits |
| Installed WASM | `~/.lunarwing/channels/darkirc.wasm` | Never edit directly — copy from build |
| Installed capabilities | `~/.lunarwing/channels/darkirc.capabilities.json` | Never edit directly — copy from source |
| LunarWing localhost patch | `src/tools/wasm/host.rs` line ~265 | Only if lunarwing repo is reset/updated |

## Build: WASM Channel Only (most common)

After editing `src/lib.rs`, `Cargo.toml`, or `darkirc.capabilities.json`:

```bash
cd ~/lunarwing/channels-src/darkirc
cargo build --target wasm32-wasip2 --release
cp target/wasm32-wasip2/release/darkirc_channel.wasm ~/.lunarwing/channels/darkirc.wasm
cp darkirc.capabilities.json ~/.lunarwing/channels/
```

Then restart lunarwing. No need to rebuild the main binary.

### Common build errors

**"current package believes it's in a workspace"**
```bash
echo '[workspace]' >> Cargo.toml
```

**"can't find library darkirc_channel"**
Make sure `Cargo.toml` and `src/lib.rs` are at the same level — not inside a `channel/` subdirectory.

**wit_bindgen path errors**
The path in `lib.rs` must resolve from `Cargo.toml` location to `~/lunarwing/wit/channel.wit`:
```rust
wit_bindgen::generate!({
    world: "sandboxed-channel",
    path: "../../wit/channel.wit",  // from channels-src/darkirc/ → wit/
});
```

## Build: LunarWing Binary (rare)

Only needed when patching LunarWing itself (e.g., the localhost HTTP fix in `host.rs`):

```bash
cd ~/lunarwing
cargo build --release
```

This takes a while. The binary lands at `~/lunarwing/target/release/lunarwing`.

### The Localhost HTTP Patch

LunarWing's WASM sandbox blocks plain HTTP. Our patch in `src/tools/wasm/host.rs` (~line 265) allows it for localhost:

```rust
let validator = AllowlistValidator::new(capability.allowlist.clone());
// Allow plain HTTP for localhost/loopback endpoints
let validator = if capability.allowlist.iter().any(|p| p.host == "127.0.0.1" || p.host == "localhost" || p.host == "::1") {
    validator.allow_http()
} else {
    validator
};
```

If you pull upstream changes to lunarwing, check if this patch survives. If `host.rs` was modified upstream, you may need to re-apply it.

## Running

### 1. Start the adapter

```bash
# Direct
DARKIRC_NICK=kageho python3 ~/lunarwing/channels-src/darkirc/adapter/darkirc_adapter.py

# Or via systemd user service
cp ~/lunarwing/channels-src/darkirc/adapter/darkirc-adapter.service ~/.config/systemd/user/
# Edit the service file: set DARKIRC_NICK, paths, etc.
systemctl --user daemon-reload
systemctl --user enable --now darkirc-adapter
```

The adapter connects to DarkIRC on `localhost:6667` and listens for HTTP on `localhost:6680`.

### 2. Start LunarWing

```bash
# Using the start script (loads env vars)
~/lunarwing/start_lunarwing.sh

# Or manually
cd ~/lunarwing
source ~/.lunarwing/.env
source .lunarwing.env  # if you have extra vars here
HTTP_PORT=9098 HTTP_WEBHOOK_SECRET="your-secret" ./target/release/lunarwing
```

### 3. Verify

Check lunarwing startup logs for:
```
Added channel: darkirc
```

And polling activity:
```
Polling tick - calling on_poll channel=darkirc
```

Test the adapter directly:
```bash
curl http://127.0.0.1:6680/health
curl http://127.0.0.1:6680/poll
```

## Adapter Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DARKIRC_HOST` | `127.0.0.1` | DarkIRC IRC server |
| `DARKIRC_PORT` | `6667` | DarkIRC IRC port |
| `DARKIRC_NICK` | `kageho-bridge` | Bot nick on IRC |
| `ADAPTER_HOST` | `127.0.0.1` | HTTP listen address |
| `ADAPTER_PORT` | `6680` | HTTP listen port |
| `ADAPTER_SECRET` | (empty) | Bearer token (optional) |
| `ADAPTER_MAX_QUEUE` | `500` | Max buffered messages |
| `ADAPTER_LOG_LEVEL` | `INFO` | Log verbosity |

## Capabilities JSON Reference

The file at `~/.lunarwing/channels/darkirc.capabilities.json` must match LunarWing's expected schema exactly. Known working version:

```json
{
  "type": "channel",
  "name": "darkirc",
  "description": "DarkIRC P2P anonymous IRC channel via local HTTP adapter",
  "setup": {
    "required_secrets": []
  },
  "capabilities": {
    "http": {
      "allowlist": [
        { "host": "127.0.0.1", "path_prefix": "/" },
        { "host": "localhost", "path_prefix": "/" }
      ],
      "rate_limit": {
        "requests_per_minute": 60,
        "requests_per_hour": 3000
      }
    },
    "secrets": {
      "allowed_names": []
    },
    "channel": {
      "allowed_paths": [],
      "allow_polling": true,
      "min_poll_interval_ms": 3000,
      "workspace_prefix": "channels/darkirc/",
      "emit_rate_limit": {
        "messages_per_minute": 100,
        "messages_per_hour": 5000
      }
    }
  },
  "config": {
    "adapter_url": "http://127.0.0.1:6680",
    "dm_policy": "pairing",
    "allow_from": [],
    "poll_interval_seconds": 3
  }
}
```

### Schema gotchas

- `"http"` must be an object with `allowlist`, NOT a boolean
- `"secrets"` must be `{"allowed_names": [...]}`, NOT a string array
- `"channel"` must include `allow_polling`, `workspace_prefix`, `emit_rate_limit`
- `"required_secrets"` must be `[]` (empty array) unless you actually use secrets
- Do NOT include `"credentials"` unless you match the exact sub-schema (has a required `name` field)

## Pairing

DM policy in `config.dm_policy`:
- `"open"` — anyone can message
- `"allowlist"` — only nicks in `config.allow_from` array
- `"pairing"` — unknown senders get a code, approve via CLI

```bash
# List pending pairing requests
lunarwing pairing list darkirc

# Approve a user
lunarwing pairing approve darkirc CODE123

# Pre-approve nicks in capabilities JSON
"allow_from": ["sun", "cmcsunmoon"]
```

Pairing approvals survive restarts (stored in database). They do NOT survive `lunarwing onboard` (which can wipe the database).

## Message Splitting

Long agent responses are split into IRC-sized chunks. The limit is in `src/lib.rs`:

```rust
let chunks = split_message(&response.content, 450);
```

And in the adapter `darkirc_adapter.py`:

```python
for chunk in [text[i:i+450] for i in range(0, len(text), 450)]:
```

DarkIRC enforces ~512 byte IRC line limit. After protocol overhead, ~450 chars is the safe max. The `split_message` function breaks at newlines and spaces, and handles multi-byte UTF-8 safely.

## Troubleshooting

### "HTTP request not allowed: Denied(InsecureScheme)"
The localhost HTTP patch in `host.rs` is missing. Re-apply it and rebuild lunarwing.

### "Invalid capabilities JSON"
Schema mismatch. Replace `~/.lunarwing/channels/darkirc.capabilities.json` with the known working version above.

### "WASM on_respond call failed" (trap/panic)
Usually a UTF-8 slicing issue in `split_message`. Make sure you're using the version with `is_char_boundary` checks.

### Channel shows "installed=yes active=no"
- Is the adapter running? (`curl http://127.0.0.1:6680/health`)
- Check lunarwing startup logs for darkirc errors
- Re-copy both `.wasm` and `.capabilities.json` to `~/.lunarwing/channels/`

### Approval flow broken over DarkIRC
Tool approval over IRC is flaky. Auto-approve is the pragmatic workaround:
```bash
lunarwing config set agent.auto_approve true
```

### Database wiped by onboard
`lunarwing onboard` can destroy your database and `.env`. NEVER re-run it casually. Back up first:
```bash
cp ~/.lunarwing/lunarwing.db ~/.lunarwing/lunarwing.db.bak
cp ~/.lunarwing/.env ~/.lunarwing/.env.bak
```

## Workspace Memory

Stored in SQLite (`~/.lunarwing/lunarwing.db`), not filesystem.

```bash
# List workspace files
lunarwing memory tree

# Read a file
lunarwing memory read SOUL.md

# Write a file
lunarwing memory write SOUL.md < ~/SOUL.md

# Write inline
lunarwing memory write config/gotify.md << 'EOF'
Gotify endpoint: http://192.168.1.157:8080
Gotify API token: your-token
EOF
```

The agent cannot write to protected paths like `SOUL.md` directly (security policy). Use the CLI.

