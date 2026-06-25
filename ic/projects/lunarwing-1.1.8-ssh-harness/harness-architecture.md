# SSH Harness — Architecture Overview

## Problem Statement
- Remote host access is fragmented
- SSH keys scattered, sometimes on disk
- No central config for hosts
- Manual credential passing to workers/routines
- No per-tenant isolation

## Goal
- Centralized SSH config
- Secrets (keys) stored securely (no disk)
- Auto-injection into workers/routines
- Per-tenant isolation
- Git ops over SSH
- Remote worker agents

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     LunarWing Gateway                        │
│                                                              │
│  ┌─────────────────┐    ┌─────────────────────────────────┐ │
│  │  Secrets Store  │    │     SSHBridge (new)             │ │
│  │  (existing)     │    │  ┌───────────────────────────┐  │ │
│  │                 │    │  │  - hosts[]                │  │ │
│  │  - ssh_key_host │    │  │  - get_config()           │  │ │
│  │    _1           │    │  │  - get_credentials()      │  │ │
│  │  - ssh_key_host │    │  │  - validate()             │  │ │
│  │    _2           │    │  └───────────────────────────┘  │ │
│  │                 │    │           ↑                      │ │
│  └─────────────────┘    └───────────┼──────────────────────┘ │
│                                     │                          │
│                           ┌─────────┴─────────┐                │
│                           │  Routine Context  │                │
│                           │  (auto-injected)  │                │
│                           └─────────┬─────────┘                │
│                                     │                          │
│  ┌──────────────────────────────────┼──────────────────────┐  │
│  │        Routines / Workers        │                       │  │
│  │  ┌────────────┐  ┌────────────┐ │  ┌────────────┐       │  │
│  │  │ git-clone  │  │ remote-run │ │  │ ...        │       │  │
│  │  │            │  │            │ │  │            │       │  │
│  │  │ gets host  │  │ gets host  │ │  │ gets host  │       │  │
│  │  │ + key      │  │ + key      │ │  │ + key      │       │  │
│  │  │ via bridge │  │ via bridge │ │  │ via bridge │       │  │
│  │  └────────────┘  └────────────┘ │  └────────────┘       │  │
│  └─────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Data Flow

1. **Config Load**: `config.toml` → `SSHBridge::new()`
2. **Secrets Load**: Secrets store → `get_credentials()`
3. **Routine Execution**: `ctx.bridge.ssh.get_config()` + `get_credentials()`
4. **Remote Ops**: SSH key mounted in-memory → Git/remote commands

## Security Model

| Component | Storage | Encryption |
|-----------|---------|------------|
| Host config | `config.toml` | None (non-sensitive) |
| SSH keys | Secrets store | Encrypted at rest |
| Runtime keys | In-memory | Not persisted |

## Per-Tenant Isolation

- Each tenant has its own `SSHBridge` instance
- Secrets are tenant-scoped
- No cross-tenant key leakage

## Benefits

| Before | After |
|--------|-------|
| SSH keys scattered, sometimes on disk | Keys in secrets store, no disk |
| Manual credential passing | Auto-injected |
| No central host config | Single source of truth |
| Hard to audit access | Centralized, auditable |
| Per-tenant isolation missing | Proper isolation |

---

*See `harness-implementation.md` for detailed implementation steps.*
