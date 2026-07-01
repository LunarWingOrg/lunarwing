
# SSH Harness — Delivery Options

**Date:** 2026-06-25  
**Status:** Option 1 implemented and working

## Overview

Three delivery mechanisms for SSH operations in LunarWing:

---

## Option 1: `create_job` in Worker Mode ✅ IMPLEMENTED

```
Agent → create_job(mode="worker") → Nanocode container
  ├── SSH_AUTH_SOCK mounted from gateway
  ├── Worker runs git clone / ssh commands
  └── Keys stay in gateway memory (never touch worker disk)
```

**Pros:**
- Already working and tested
- Strong isolation (separate container)
- Keys never touch worker disk
- Leverages existing worker infrastructure

**Cons:**
- Requires external worker infrastructure (nanocode/pebble)
- Latency overhead from container spin-up
- More resource usage per operation

**Status:** ✅ Working on test VM (confirmed from within nanocode)

---

## Option 2: Built-in Rust SSH Tool

```
Agent → SSH tool (compiled into lunarwing binary)
  ├── Wraps russh directly
  ├── Executes remote commands / git ops inline
  └── No external worker needed
```

**Pros:**
- No worker overhead (faster execution)
- Simpler deployment (no worker infra needed)
- Direct access to russh API

**Cons:**
- Less isolation (SSH runs in gateway process)
- More attack surface in core binary
- Harder to sandbox/limit resources
- SSH credentials loaded into gateway memory space

**Status:** Not started

**Use Cases:**
- Quick one-off SSH commands
- Git operations that don't justify full worker spin-up
- Environments without worker infrastructure

---

## Option 3: WASM SSH Tool

```
Agent → WASM tool (sandboxed via WASI)
  ├── SSH operations in WASM sandbox
  ├── Limited by WASM/WASI capabilities
  └── Sandboxed by design
```

**Pros:**
- Sandboxed execution (WASI limits)
- Portable across platforms
- Safe by construction (memory safety)

**Cons:**
- WASM can't do raw socket operations easily
- Would need custom host functions for SSH
- Most complex to implement
- Performance overhead from WASM boundary

**Status:** Not started

**Requirements:**
- WASI socket extensions or custom host functions
- russh compiled to WASM (may need forks/patches)
- SSH agent protocol over WASM boundary

---

## Recommendation

| Priority | Option | When |
|----------|--------|------|
| 1 | Worker Mode (Option 1) | Default for all SSH operations |
| 2 | Rust Tool (Option 2) | Quick ops, no worker infra available |
| 3 | WASM Tool (Option 3) | Future: maximum isolation needs |

**Rationale:** Option 1 is working and provides the right balance of isolation and simplicity. Option 2 is a useful optimization for specific cases. Option 3 is exploratory.

---

## Implementation Notes

- **Socket location:** Tenant run directory (`/home/<tenant>/lunarwing/run/ssh-agent.sock`)
- **Why not /tmp:** Daemon runs with `PrivateTmp=true`
- **Mounting:** Socket mounted into worker containers via `SSH_AUTH_SOCK` env var
- **Key storage:** Encrypted in secrets store, loaded into agent memory on startup
