# SSH Harness — Initial Idea (superseded)

**Status:** Superseded by the shipped implementation (1.1.8).

This was the original one-paragraph seed for the SSH harness. It has been
delivered — with one notable change from the seed. See the current docs:

- Architecture: [`docs/architecture/SSH_AGENT_HARNESS.md`](../../../docs/architecture/SSH_AGENT_HARNESS.md)
- Operator guide: [`docs/ops/SSH-HARNESS-SETUP.md`](../../../docs/ops/SSH-HARNESS-SETUP.md)
- As-built architecture (this folder): [`harness-architecture.md`](harness-architecture.md)
- As-built implementation (this folder): [`harness-implementation.md`](harness-implementation.md)

## Original seed

> Centralized SSH bridge for secure remote host access, auto-injected into
> workers/routines, with no disk writes for secrets.

Core pieces envisioned: an `SSHBridge` struct, non-sensitive config in
`config.toml`, sensitive keys in the secrets store, auto-injection into worker
context, and remote worker integration.

## What changed on the way to shipping

The "auto-injection" was realized as an **in-process ssh-agent** exposed over a
per-tenant Unix socket (`SSH_AUTH_SOCK`), not as a `get_credentials()` call that
hands key bytes to consumers. Keys are decrypted only inside the daemon and
never leave it; workers receive a signing capability via the socket. Everything
else in the seed (central config, encrypted-at-rest keys, per-tenant isolation,
git-over-SSH from workers) shipped as imagined.
