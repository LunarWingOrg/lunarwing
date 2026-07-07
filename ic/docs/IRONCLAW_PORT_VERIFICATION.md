# IronClaw 0.27.0 Port — Verification Guide

Verification procedures for changes ported from IronClaw 0.27.0 to LunarWing.
Run all commands from `lunarwing/ic/`.

## Phase 1A: Zip Bomb Prevention (Document Extraction)

Bounded decompression reads prevent OOM from malicious zip files (PPTX, XLSX, DOCX).

### Unit Tests

```bash
cargo test -p lunarwing --lib document_extraction
```

Key tests:
- `bounded_read_tracks_actual_bytes` — cumulative byte counter across entries
- `bounded_read_rejects_single_entry_over_limit` — per-entry 50MB cap
- `bounded_read_rejects_cumulative_over_limit` — total 100MB cap
- `extract_pptx_*`, `extract_xlsx_*`, `extract_office_xml_*` — existing extraction unbroken

### Manual Verification

Create a test PPTX/XLSX with a single slide/sheet containing a small amount of text.
Confirm extraction still returns the expected content:

```bash
cargo test -p lunarwing --lib document_extraction -- --nocapture
```

To test the bomb rejection path without a real zip bomb, the unit tests use
`bounded_read_zip_entry_with_limits()` directly with artificially low limits.

---

## Phase 1B: Path-Based Credential Matching

Credentials can now be scoped to specific URL paths, not just hosts. Different
API endpoints on the same host can use different secrets.

### Unit Tests

```bash
# Policy decision tests (specificity, path scoping, most-specific-wins)
cargo test -p lunarwing --lib sandbox::proxy::policy

# Secrets types (path matching helpers, host wildcard patterns)
cargo test -p lunarwing --lib secrets::types

# WASM credential injector (struct compatibility with new fields)
cargo test -p lunarwing --lib tools::wasm::credential_injector

# WASM wrapper (struct compatibility with new fields)
cargo test -p lunarwing --lib tools::wasm::wrapper
```

Key tests:
- `test_sandbox_proxy_honors_path_patterns` — write-path injects, read-path does not
- `test_sandbox_proxy_most_specific_credential_wins` — path-scoped token beats global token regardless of declaration order
- `test_host_matches_pattern_wildcard` — `*.example.com` matches subdomains but not bare domain

### Backward Compatibility

The new `CredentialMapping` fields use `#[serde(default)]`:
- `path_patterns: Vec<String>` defaults to empty (matches all paths)
- `optional: bool` defaults to false

Existing WASM tools and capabilities JSON files do not need changes. Verify by
checking that WASM tools with existing capabilities files still compile and load:

```bash
scripts/build-wasm-extensions.sh
```

### Integration Verification

With a running instance, confirm that a capabilities JSON like this works:

```json
{
  "auth": {
    "credentials": [{
      "secret_name": "WRITE_TOKEN",
      "location": "authorization_bearer",
      "host_patterns": ["api.example.com"],
      "path_patterns": ["/api/v1/write"]
    }]
  }
}
```

The credential should only be injected for requests to `/api/v1/write`, not
other paths on the same host.

---

## Phase 2A: WASM Fuel Limit (10M to 500M)

The default fuel limit was raised from 10M to 500M instructions. The old limit
was too low for tools parsing JSON responses over ~100KB.

### Verification

```bash
# Confirm the constant value
grep -n 'DEFAULT_FUEL_LIMIT' src/tools/wasm/limits.rs src/config/wasm.rs
```

Both should show `500_000_000`.

### Functional Test

Any WASM tool that parses a moderately sized JSON response exercises this path.
The Gotify tool is the best smoke test — if it handles a notification response
without a fuel exhaustion error, the fix is working. With the old 10M limit,
JSON parsing alone burns ~2M fuel per 100KB of input.

---

## Phase 2B: Action Name Normalization (GrantedActions)

`GrantedActions::covers()` now normalizes hyphens and underscores bidirectionally.
A lease granting `create-issue` matches a tool call for `create_issue` and vice versa.

### Unit Tests

```bash
cargo test -p lunarwing_engine -- capability
```

Key test:
- `covers_action_normalizes_hyphens_and_underscores` — both directions of normalization

### Manual Verification

If using the capability/lease system with WASM tools, confirm that a tool whose
name contains hyphens (e.g., `create-issue`) is correctly matched by a lease
that uses underscores (e.g., `create_issue`), and vice versa.

---

## Phase 3A: Tool Permission Centralization

Replaced the static `TOOL_RISK_DEFAULTS` HashMap with `seeded_default_permission()`,
added `effective_permission()` with hyphen/underscore normalization, added
`tool_permission_locked()`, and added `AdminToolPolicy` for multi-tenant admin
restrictions.

### Unit Tests

```bash
# All permission tests (seeded defaults, admin policy, normalization, serde)
cargo test -p lunarwing --lib permissions

# Verify seed_tool_permissions in app.rs still works
cargo test -p lunarwing --lib seed_tool_permissions
```

Key tests:
- `test_effective_permission_checks_tool_name_aliases` — hyphen/underscore normalization in overrides lookup
- `test_effective_permission_missing_tool_uses_seeded_default` — confirms LunarWing-specific defaults (http and tool_activate are AskEachTime, not AlwaysAllow)
- `test_seeded_default_normalizes_hyphens` — `memory-search` resolves to `memory_search`
- `test_admin_tool_policy_*` — global disable, per-user disable, combined, empty, serde roundtrip
- `test_validate_admin_tool_policy_rejects_bad_*` — path traversal and invalid chars rejected

### LunarWing-Specific Defaults

LunarWing intentionally keeps `http` and `tool_activate` as `AskEachTime`
(IronClaw sets them to `AlwaysAllow`). Verify:

```bash
cargo test -p lunarwing --lib permissions -- missing_tool_uses_seeded_default --nocapture
```

### Integration Verification (Running Instance)

1. **Fresh DB seed**: Start with a clean database. After startup,
   `seed_tool_permissions` should populate defaults. Verify in the settings UI
   or DB that `http` and `tool_activate` show as `ask_each_time`.

2. **Hyphen/underscore normalization**: Set a permission using a hyphenated name
   (e.g., `tool-activate` → `disabled`). Query with underscore form
   (`tool_activate`). The override should be respected.

3. **Admin tool policy** (multi-tenant only): Insert a policy into the settings
   table:
   ```sql
   INSERT INTO settings (user_id, key, value)
   VALUES ('__admin__', 'admin_tool_policy',
           '{"disabled_tools": ["build_software"], "user_disabled_tools": {"alice": ["shell"]}}');
   ```
   Confirm that non-admin user "alice" cannot see `build_software` or `shell`
   in the tool list, while admin users see all tools.

---

## Phase 3B: LLM Provider Config Hardening

Two improvements ported from IronClaw:

1. **Top-level decorator chain env vars** (`LLM_MAX_RETRIES`, `LLM_CIRCUIT_BREAKER_THRESHOLD`,
   `LLM_CIRCUIT_BREAKER_RECOVERY_SECS`, `LLM_RESPONSE_CACHE_ENABLED`,
   `LLM_RESPONSE_CACHE_TTL_SECS`, `LLM_RESPONSE_CACHE_MAX_ENTRIES`). These work with
   any backend (TensorZero, Ollama, Anthropic, etc.), not just LunarWing Cloud. They fall back
   to the LunarWing Cloud-specific values for backward compatibility.

2. **Conditional LunarWing Cloud URL validation**. LunarWing Cloud auth/base URLs are only validated when
   LunarWing Cloud is the configured backend, or the user explicitly set `LUNARWING_CLOUD_AUTH_URL`,
   `LUNARWING_CLOUD_BASE_URL`, or `LUNARWING_CLOUD_API_KEY`. This prevents startup failures in air-gapped
   environments that use a non-LunarWing Cloud backend.

### Unit Tests

```bash
# Config resolution tests (39 existing + 6 new)
cargo test -p lunarwing --lib config::llm

# Provider chain tests (confirm decorator settings now read from top-level config)
cargo test -p lunarwing --lib llm::tests
```

Key new tests:
- `llm_max_retries_overrides_lunarwing_cloud_default` — `LLM_MAX_RETRIES=7` overrides LunarWing Cloud's default 3
- `llm_max_retries_falls_back_to_lunarwing_cloud` — when unset, falls back to `LUNARWING_CLOUD_MAX_RETRIES`
- `llm_max_retries_rejects_invalid` — non-numeric value produces descriptive error
- `llm_response_cache_enabled_overrides_lunarwing_cloud` — `LLM_RESPONSE_CACHE_ENABLED=true` works
- `llm_circuit_breaker_threshold_overrides_lunarwing_cloud` — `LLM_CIRCUIT_BREAKER_THRESHOLD=10` works
- `non_lunarwing_cloud_backend_skips_lunarwing_cloud_url_validation` — openai_compatible backend doesn't fail on LunarWing Cloud URLs

### Integration Verification

Test that the new `LLM_*` env vars work with non-LunarWing Cloud backends:

```bash
# Verify retry config reaches the provider chain
LLM_BACKEND=openai_compatible \
LLM_BASE_URL=http://localhost:3002/openai/v1 \
LLM_MAX_RETRIES=5 \
LLM_CIRCUIT_BREAKER_THRESHOLD=10 \
RUST_LOG=lunarwing=debug \
cargo run 2>&1 | grep -E "retry|circuit"
```

Expected log output:
```
LLM retry wrapper enabled max_retries=5
LLM circuit breaker enabled threshold=10 recovery_secs=30
```

### Air-Gapped Environment Verification

Without any LunarWing Cloud env vars, a non-LunarWing Cloud backend should start cleanly:

```bash
unset LUNARWING_CLOUD_AUTH_URL LUNARWING_CLOUD_BASE_URL LUNARWING_CLOUD_API_KEY
LLM_BACKEND=ollama OLLAMA_BASE_URL=http://localhost:11434 cargo run
```

This should not fail with a URL validation error for `private.near.ai`

---

## Full Regression Suite

After all phases, run the complete verification:

```bash
# All unit tests
cargo test

# Engine crate isolation
cargo test -p lunarwing_engine

# Dual-backend compilation
cargo check                                          # postgres (default)
cargo check --no-default-features --features libsql  # libsql only
cargo check --all-features                           # both

# Pre-commit safety checks
scripts/pre-commit-safety.sh

# XMPP bridge still compiles
cd bridges/xmpp-bridge && cargo check
```

### Known Pre-Existing Failures

These test failures predate the port and are unrelated:

- `channels::xmpp::omemo::store::tests::migration_preserves_legacy_device_id` — OMEMO store migration test
- Several `lunarwing_engine` executor/mission tests — engine executor test infrastructure
