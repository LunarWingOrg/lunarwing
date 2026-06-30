# Vision-Analyze WASM Tool — Per-Tenant Sidecar Wiring (Phase 2) Design Spec

**Date:** 2026-06-30
**Status:** Approved (pending spec review)
**Branch:** `1.1.7-lunarvision-and-kers-4090-b-4`
**Phase relationship:** Follow-on to Phase 1 (`2026-06-29-lunarvision-vl-wiring-design.md`), which wired the VL server into tenant sidecars. Phase 2 wires the *agent's* vision-analyze WASM tool to the per-tenant sidecar.

---

## Goal

Make the LunarWing agent's `vision-analyze` WASM tool reach the correct per-tenant OCR sidecar (e.g. `http://127.0.0.1:20015` for venus, `http://127.0.0.1:20005` for mercury) so the agent can actually perform OCR/vision, without relying on the LLM to pass the port correctly.

## Context (verified facts)

- **Phase 1 done:** Both tenants' OCR sidecars reach the GPU-backed Qwen3-VL server via `host.containers.internal:8080`. Verified end-to-end: sidecar `/v1/vision/analyze` with `mode=describe` returns a real Qwen3-VL description.
- **The tool is the gap:** the `vision-analyze` WASM tool (`ic/tools-src/vision-analyze/`) is not yet built or installed for tenants, and even if built, its `service_url` handling is broken for multi-tenant:
  - `ALLOWED_HOSTS` (`lib.rs:28-33`) is hardcoded to exactly `127.0.0.1:8088`, `localhost:8088`, `host.containers.internal:8088`, `[::1]:8088`. Per-tenant ports (`20015`, `20005`) are rejected.
  - `default_url()` (`lib.rs:63`) returns `DEFAULT_VISION_URL` = `http://127.0.0.1:8088` (single-tenant default; nothing listens there in MT).
  - The tool has no env access (WASM sandbox) and no per-tenant awareness.
- **The plumbing already exists** (this is the key insight that shaped the design):
  - The MT script already writes `VISION_SERVICE_URL=http://127.0.0.1:<tenant_port>` to the daemon's env (`lunarwing.env`) — `lunarwing-mt-admin.sh:2005-2006`.
  - `JobContext` (`ic/src/context/state.rs:126`) is already the host→WASM per-call context channel, serialized and passed as `Request.context` (`ic/src/tools/wasm/wrapper.rs:1199`, per `wit/tool.wit:113-115`).
  - `JobContext.user_id` already carries tenant identity at tool-call time; the WASM wrapper reads it directly (`wrapper.rs:1180`).
- **Dispatch path** (traced): `agentic_loop.rs:221` → `dispatcher.rs:440 execute_tool_calls` → `tools/execute.rs:18 execute_tool_with_safety` → `wrapper.rs:1169 WasmToolWrapper::execute` → `wrapper.rs:979 execute_sync` → `wrapper.rs:1052 call_execute` (crosses into WASM).

## Architecture

Data flow for an agent vision request:

```
[daemon startup] reads VISION_SERVICE_URL from env (e.g. http://127.0.0.1:20015)
       │
       ▼ cached on Config.vision_service_url
[per-message] JobContext created in dispatcher.rs:125/166 → carries vision_service_url
       │
       ▼ wrapper.rs:1199 serializes entire JobContext → Request.context
[WASM tool execute()] reads vision_service_url from Request.context (not the hardcoded default)
       │
       ▼ validates host (sans port) against loosened allowlist (loopback-only)
POSTs to {vision_service_url}/v1/vision/analyze → tenant's sidecar → Qwen3-VL
```

**Why this works:** `JobContext` is already the documented channel for "host adds per-call per-tenant context to a WASM tool" (`wit/tool.wit:113-115`). The correct per-tenant URL is already in the daemon's env. We connect two existing pieces of plumbing — no new WIT field, no param mutation, no per-tool daemon code.

## Components

### Component 1 — Daemon: add `vision_service_url` to Config and JobContext

**File: `ic/src/config/mod.rs`** (alongside `Config.owner_id` at `:91`)

- Add field: `pub vision_service_url: Option<String>`
- Populate in the existing env-loading path (near where `LUNARWING_OWNER_ID` is read in `config/helpers.rs:55-56`): read `VISION_SERVICE_URL` env var → `Some(url)` if set and non-empty, else `None`.
- `#[serde(default)]` so old persisted configs load cleanly.

**File: `ic/src/context/state.rs`** (where `JobContext` is defined at `:126`; `user_id` at `:132`)

- Add field: `pub vision_service_url: Option<String>`
- Propagate from `Config` in `JobContext` constructors (notably `JobContext::with_user` used at `dispatcher.rs:125/166`). The constructors take or have access to the app/config; copy `config.vision_service_url` into the new context.
- Additive `Option<String>` — existing call sites keep working (they get `None` until propagation lands).

**No change to `wrapper.rs:1199`** — it already serializes the entire `JobContext` to `Request.context`. The new field rides along automatically.

### Component 2 — WASM tool: read `service_url` from `Request.context`, loosen allowlist

**File: `ic/tools-src/vision-analyze/src/lib.rs`**

- **Loosen `ALLOWED_HOSTS`** (`:28-33`): change from exact `host:8088` entries to host-suffix matching. Accept any port on the loopback hosts: `127.0.0.1`, `localhost`, `host.containers.internal`, `[::1]`. Update `validate_service_url` (`:207-227`) to split host from port and check the host portion (sans port) against the allowed-host set. Preserves the loopback-only security property (no LAN, no external).
- **Host-wins precedence:** in `execute_inner`, resolve the effective `service_url` as:
  1. Parse `Request.context` as JSON; if it has a non-empty `vision_service_url` field → use it.
  2. Else if the LLM passed `service_url` in params → use it.
  3. Else fall back to `default_url()` (`http://127.0.0.1:8088`).
  - When the host provides a URL (step 1), the LLM-provided value (step 2) is **ignored** — host-controlled, the LLM cannot redirect vision calls. Mirrors `credential_injector`'s host-controlled model.
- The `execute_inner` signature may need to accept `context_json: &str` (currently it only takes `params_json`). The WIT `execute` already receives `Request { params, context }` (`wit/tool.wit:110-132`); thread `context` through to `execute_inner`.

**File: `ic/tools-src/vision-analyze/vision-analyze-tool.capabilities.json`**

- Update `http.allowlist` to match the loosened runtime allowlist (any port on the loopback hosts). The capabilities file is the declarative enforcement layer; the Rust constant is the runtime check. Both must agree or the sandbox blocks what the tool allows.
- Update the `service_url` schema description to reflect host-injection precedence.

### Component 3 — Build + install + verify

**Build:** `ic/scripts/build-wasm-extensions.sh --tools` — compiles all WASM tools (including the patched vision-analyze) against the current WIT. Prereqs: `wasm32-wasip2` target + `cargo-component` (already present on the host and per-tenant via `add-tenant`).

**Install per-tenant:** `sudo -E ./ic/scripts/lunarwing-mt-admin.sh install-wasm venus` and `mercury` — copies the built `.wasm` + `.capabilities.json` into each tenant's `state/tools/`. The daemon picks up new tools on next tool-registry refresh (or tenant restart).

**Verify (the real proof — agent, not curl):**
1. Confirm the patched `.wasm` and `.capabilities.json` are installed in tenant state dirs.
2. Restart the tenant daemon (picks up the new `VISION_SERVICE_URL`-aware Config + the new tool).
3. Send the agent a message via the gateway or REPL asking it to OCR/describe an image.
4. Confirm the agent invokes `vision-analyze`, the tool resolves `service_url` from context → `127.0.0.1:<tenant_port>`, and OCR/VL text comes back in the agent's response.

## Risks & rollback

- **Risk:** Modifying `JobContext` touches a widely-used type.
  **Mitigation:** Additive `Option<String>` field with `#[serde(default)]`. Existing call sites get `None`; no behavior change until propagation + the WASM tool change land together.
- **Risk:** `Config` change could affect persisted config serialization.
  **Mitigation:** `Option<String>` with `#[serde(default)]` — old configs load as `None`.
- **Risk:** Loosening the allowlist could weaken security.
  **Mitigation:** Loopback-only preserved (no LAN/external hosts); the host controls the URL via env, so the LLM can't pick an attacker-controlled host. Defense-in-depth retained at the host-validation layer.
- **Rollback:** Revert the WASM tool change + daemon change. The tool falls back to its `:8088` default — broken for multi-tenant, identical to today (no regression).

## Explicitly out of scope (deferred)

- Stale `vision.env` guard fix (`lunarwing-mt-admin.sh:3191/3327` — `[[ -f ... ]] ||` skips rewrite on restart).
- Sidecar bugfixes (disk-cache `safe_name` collision, synthetic confidence, `bbox=[0,0,0,0]`, global rate-limiter vs per-IP docs).
- Health-check wiring — point `health-lunarvision.sh` at each tenant's per-tenant health port (`20016`-style) with `HEALTH_LUNARVISION_REQUIRE_VL=true`. The sidecar already reports `vl_available: true`.
- Rootless-podman GPU containerization of the VL server (the `docs/proposals/qwen3vl-ocr-podman.md` alternative).

## Open questions

None at spec time. All design decisions resolved during brainstorming:
- Architecture: Approach A (JobContext + `Request.context`).
- Value source: `VISION_SERVICE_URL` env var, read once at startup.
- Allowlist: any loopback port.
- Precedence: host-injected wins; LLM-provided ignored when host provides.
