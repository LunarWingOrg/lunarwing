## LunarWing v1.0.2

**Release date:** 2026-05-08

### Added

- **Worker test harness** — Docker Compose matrix test suite covering all 4 worker types (Codex, Nanocode, Built-in, Sandbox) with mock orchestrator, WebSocket hub, smoke and chaos test modes
- **Configurable Gotify notifications** — Gotify WASM tool now reads URL and notification title from `config/gotify.json` instead of hardcoded values; title can be overridden per-call
- **Gotify support in MT admin** — `add-tenant`, `add-tenants`, and new `configure-gotify` command accept `--gotify-url` and `--gotify-title`; capabilities allowlist is auto-patched to match the configured host
- **Gotify support in setup-instance** — `--gotify-url` and `--gotify-title` flags write workspace config and generate a host-matched capabilities file
- **Engine V2 architecture spec** and **Semantic Memory Search spec** documentation

### Fixed

- **Mission resolution by name** — `mission_fire`, `mission_pause`, `mission_resume`, `mission_delete`, and `mission_update` now resolve missions by name or UUID (previously UUID-only), eliminating `.unwrap()` on invalid UUIDs in the bridge effect adapter
- **libSQL scientific notation parsing** — `parse_libsql_decimal_text()` handles scientific notation (e.g. `1.5E-7`) returned by libSQL for cost values, preventing crashes on usage stats queries
- **mission_update name collision** — renamed the `name` parameter to `new_name` so it no longer conflicts with the mission lookup field

### Changed

- Gotify default title changed to "LunarWing"
- Worker Dockerfile adjusted for standard worker image compatibility
- Repository cleanup: removed some stale files
