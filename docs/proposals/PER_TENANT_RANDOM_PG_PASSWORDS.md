# Proposal: Per-tenant random PostgreSQL passwords

*Drafted 2026-06-16.*

## Current behavior

Every tenant's PostgreSQL container is created with the **same fixed credentials**
`lunarwing/lunarwing/lunarwing` (user/password/database):

- `start_tenant_postgres` passes `-e POSTGRES_PASSWORD=lunarwing`.
- `write_tenant_lunarwing_env` writes
  `DATABASE_URL=postgres://lunarwing:lunarwing@127.0.0.1:<pg_port>/lunarwing`.
- Documented in `docs/ops/MULTITENANCY-PRODUCTION.md:336`
  ("Default credentials: `lunarwing/lunarwing/lunarwing`").

This is the intended, documented default — not a leak or a regression.

## Risk

Each tenant's PG is bound to `127.0.0.1:<unique-port>` (loopback only), but the
shared password means **any local process that knows the convention can connect to
any tenant's database** with `lunarwing:lunarwing`. So DB-layer isolation between
tenants rests entirely on per-tenant port numbers, not on credentials.

Severity is **low** in the current single-operator, trusted-host setup (loopback
binding, no untrusted local users), but unique per-tenant passwords are
defense-in-depth for a genuinely multi-tenant deployment.

## Proposal

Generate a strong random PG password per tenant at `add-tenant` time, persist it
in the tenant's `lunarwing.env` (0600, tenant-owned), and use it for both the
container and the daemon's `DATABASE_URL`.

### Implementation sketch

- New helper `tenant_pg_password <name>`: returns the tenant's PG password,
  generating + persisting it on first call (e.g. `openssl rand -hex 24`). Reads
  from the persisted env on subsequent calls so it is **stable** across restarts.
- `write_tenant_lunarwing_env`: build `DATABASE_URL` from `tenant_pg_password`.
- `start_tenant_postgres`: `-e POSTGRES_PASSWORD="$(tenant_pg_password "$name")"`.
- The password must be resolved **before** the container is first created
  (`POSTGRES_PASSWORD` only initialises on a fresh datadir) and then reused.

### Key caveat — rotation isn't free

`POSTGRES_PASSWORD` only takes effect on **first init of an empty datadir**.
Changing it later requires `ALTER ROLE lunarwing PASSWORD '<new>'` inside the
running container **plus** updating `DATABASE_URL` in the env **plus** a daemon
restart. So:

- **New tenants**: random password from creation — clean.
- **Existing tenants** (zeus/mars/ate/creamheart, created with `lunarwing`): either
  leave as-is, or run a one-time rotation (`ALTER ROLE` + env update + restart),
  ideally folded into a small `rotate-pg-password <tenant>` mt-admin subcommand.

## Follow-ups

- Never log the generated password (repo rule).
- Update `docs/ops/MULTITENANCY-PRODUCTION.md:336` to describe per-tenant random
  passwords instead of the fixed default.
- Update the migration/troubleshooting guides that hardcode
  `PGPASSWORD=lunarwing` / `postgresql://lunarwing:lunarwing@...` to read the
  password from the tenant env instead.
