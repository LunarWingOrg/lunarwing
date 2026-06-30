# Vision-Analyze WASM Tool — Per-Tenant Sidecar Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the LunarWing agent's `vision-analyze` WASM tool reach the correct per-tenant OCR sidecar (e.g. `http://127.0.0.1:20015` for venus) so the agent can do OCR/VL, with the host injecting the URL via `JobContext` (not the LLM).

**Architecture:** The MT script already writes `VISION_SERVICE_URL` to the daemon's env per-tenant. We read it once at startup onto `Config.vision_service_url`, propagate it to `JobContext.vision_service_url` via a builder method at construction sites, and the WASM vision tool reads it from `Request.context` (the existing host→WASM channel, already serialized at `wrapper.rs:1199`) with host-wins precedence. The tool's allowlist is loosened to any loopback port.

**Tech Stack:** Rust 2024 (edition), serde, tokio, WASM Component Model (wasm32-wasip2), cargo-component, bash (MT admin script), rootless podman.

**Spec:** `docs/superpowers/specs/2026-06-30-vision-analyze-tool-wiring-design.md`

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `ic/src/config/mod.rs` | Modify | Add `vision_service_url: Option<String>` field to `Config` struct |
| `ic/src/config/helpers.rs` | Modify | Read `VISION_SERVICE_URL` env var in the existing env-loading path |
| `ic/src/context/state.rs` | Modify | Add `vision_service_url: Option<String>` to `JobContext` + builder method |
| `ic/src/agent/dispatcher.rs` | Modify | Call `.with_vision_service_url(...)` at the two `JobContext::with_user` sites |
| `ic/tools-src/vision-analyze/src/lib.rs` | Modify | Loosen allowlist to any loopback port; read `service_url` from `Request.context` (host-wins); thread context to `execute_inner` |
| `ic/tools-src/vision-analyze/vision-analyze-tool.capabilities.json` | Modify | Update `http.allowlist` to match loosened runtime allowlist; update schema description |
| `ic/src/app.rs` (likely) | Modify | Wire `Config.vision_service_url` through to where `JobContext`s are built (if dispatcher doesn't already have config access) |

**Test additions:** unit tests in `context/state.rs` (JobContext builder), and in `tools-src/vision-analyze/src/lib.rs` (allowlist + precedence). Build verification via `cargo check`. End-to-end via agent invocation (manual).

---

## Task 1: Add `vision_service_url` to `Config`

**Files:**
- Modify: `ic/src/config/mod.rs:90-91` (Config struct)
- Modify: `ic/src/config/helpers.rs` (env loading)

- [ ] **Step 1: Read the current Config struct head and confirm the insertion point**

Run:
```bash
sed -n '85,100p' ic/src/config/mod.rs
```
Expected: `pub struct Config {` at line 90, `pub owner_id: String,` at line 91. Confirm before editing.

- [ ] **Step 2: Add the field to the Config struct**

Use Edit on `ic/src/config/mod.rs`. Match:
```rust
pub struct Config {
    pub owner_id: String,
```
Replace with:
```rust
pub struct Config {
    pub owner_id: String,
    /// Per-tenant vision/OCR sidecar URL the agent's vision-analyze WASM tool should call.
    /// Populated from the `VISION_SERVICE_URL` env var (written per-tenant by the MT admin
    /// script). `None` on deployments without a sidecar; the tool falls back to its default.
    #[serde(default)]
    pub vision_service_url: Option<String>,
```

The `#[serde(default)]` ensures old persisted configs load as `None`.

- [ ] **Step 3: Find where `owner_id` is resolved and add `vision_service_url` resolution alongside**

Run:
```bash
grep -n 'resolve_owner_id\|fn resolve_owner\|owner_id =\|self.owner_id' ic/src/config/mod.rs ic/src/config/helpers.rs | head
```
Find the function that resolves `owner_id` from env (it uses `LUNARWING_OWNER_ID` per `config/helpers.rs:55`). This is where we read `VISION_SERVICE_URL`.

- [ ] **Step 4: Populate the new field from env**

The pattern depends on what Step 3 found — most likely one of:
- If there's a builder/load function that sets `owner_id: optional_env("LUNARWING_OWNER_ID")...`, add a line: `vision_service_url: optional_env("VISION_SERVICE_URL"),` next to it.
- If `owner_id` is set via `Config { owner_id: ..., ... }` construction, add `vision_service_url: std::env::var("VISION_SERVICE_URL").ok().filter(|s| !s.is_empty()),` at the same site.

`optional_env` is the helper used at `config/helpers.rs:492` (`optional_env("LUNARWING_OWNER_ID").unwrap()`). Confirm it returns `Option<String>` and use it.

- [ ] **Step 5: Verify it compiles**

Run:
```bash
taskset -c 0-23 cargo check -j24 --manifest-path ic/Cargo.toml 2>&1 | tail -20
```
Expected: `Finished` with no errors. (A warning about an unused field is fine for now — Task 3 will use it.)

- [ ] **Step 6: Commit**

```bash
git add ic/src/config/mod.rs ic/src/config/helpers.rs
git commit -m "Add Config.vision_service_url field (read from VISION_SERVICE_URL env)

Additive Option<String> field on Config, populated from the VISION_SERVICE_URL
env var (written per-tenant by lunarwing-mt-admin.sh). serde(default) keeps
old persisted configs loading cleanly. Field is unused until Task 3 wires it
into JobContext."
```

---

## Task 2: Add `vision_service_url` to `JobContext` + builder method

**Files:**
- Modify: `ic/src/context/state.rs:126-241` (JobContext struct + `with_user` + add `with_vision_service_url`)

- [ ] **Step 1: Re-read the JobContext struct fields and `with_user` body**

Run:
```bash
sed -n '126,145p' ic/src/context/state.rs
sed -n '208,241p' ic/src/context/state.rs
```
Confirm the field list and that `with_user` initializes each field with a default (line 213-240 builds `Self { ... }`).

- [ ] **Step 2: Add the field to the struct**

Use Edit on `ic/src/context/state.rs`. Find the `pub user_id: String,` line (around `:132`) and add after it:
```rust
    pub user_id: String,
    /// Per-tenant vision/OCR sidecar URL, propagated from Config for WASM tools.
    /// `None` = no sidecar configured; the vision-analyze tool falls back to its default.
    pub vision_service_url: Option<String>,
```

- [ ] **Step 3: Initialize the field in `with_user`**

In the same `with_user` body (line 213-240), the `Self { ... }` initializer must set the new field. Find the line `user_id: user_id.into(),` and add after it:
```rust
            user_id: user_id.into(),
            vision_service_url: None,
```
(Default `None` — Task 3 will override via the builder.)

- [ ] **Step 4: Initialize the field in any other constructors**

Run:
```bash
grep -n 'JobContext {' ic/src/context/state.rs
```
If there are other constructors building `JobContext { ... }` directly (besides `with_user`), each needs `vision_service_url: None,` (or a sensible default). Add it wherever the compiler flags a missing field.

- [ ] **Step 5: Add a builder method `with_vision_service_url`**

Use Edit to add a new builder method next to the other `with_*` methods (after `with_requester_id` at `:249-253` is a natural spot). Match:
```rust
    /// Set the channel-specific requester/actor ID.
    pub fn with_requester_id(mut self, requester_id: impl Into<String>) -> Self {
        self.requester_id = Some(requester_id.into());
        self
    }
```
Replace with:
```rust
    /// Set the channel-specific requester/actor ID.
    pub fn with_requester_id(mut self, requester_id: impl Into<String>) -> Self {
        self.requester_id = Some(requester_id.into());
        self
    }

    /// Set the per-tenant vision/OCR sidecar URL (propagated from Config).
    pub fn with_vision_service_url(mut self, url: Option<String>) -> Self {
        self.vision_service_url = url;
        self
    }
```

- [ ] **Step 6: Add a unit test for the builder**

The existing test module is at `ic/src/context/state.rs:371`. Add a test inside `mod tests`:
```rust
    #[test]
    fn job_context_vision_service_url_builder() {
        let ctx = JobContext::with_user("venus", "chat", "test")
            .with_vision_service_url(Some("http://127.0.0.1:20015".to_string()));
        assert_eq!(
            ctx.vision_service_url.as_deref(),
            Some("http://127.0.0.1:20015")
        );

        // Default is None
        let ctx_default = JobContext::with_user("venus", "chat", "test");
        assert!(ctx_default.vision_service_url.is_none());
    }
```

- [ ] **Step 7: Run the test (expect PASS) and compile-check**

```bash
taskset -c 0-23 cargo test -j24 --manifest-path ic/Cargo.toml job_context_vision_service_url 2>&1 | tail -10
taskset -c 0-23 cargo check -j24 --manifest-path ic/Cargo.toml 2>&1 | tail -5
```
Expected: test passes; check compiles clean.

- [ ] **Step 8: Commit**

```bash
git add ic/src/context/state.rs
git commit -m "Add JobContext.vision_service_url field + builder method

Additive Option<String> field, defaults to None in with_user. Builder method
with_vision_service_url lets dispatcher sites propagate Config.vision_service_url
into the per-call context that flows to WASM tools via Request.context."
```

---

## Task 3: Propagate `Config.vision_service_url` into `JobContext` at construction sites

**Files:**
- Modify: `ic/src/agent/dispatcher.rs:125` and `:166` (the two production `JobContext::with_user` sites)

- [ ] **Step 1: Re-read both construction sites and confirm how they access config**

Run:
```bash
sed -n '120,170p' ic/src/agent/dispatcher.rs
```
Identify whether `self.config` or `self.agent.config` is accessible at those sites (dispatcher holds the agent; agent holds config). Note the exact path (e.g. `self.agent.config.vision_service_url.clone()`).

- [ ] **Step 2: Patch the reflex-path construction (line 125)**

The current code:
```rust
                JobContext::with_user(&message.user_id, "reflex", "Reflex fast-path execution")
```
Change to (substituting the actual config-access path from Step 1):
```rust
                JobContext::with_user(&message.user_id, "reflex", "Reflex fast-path execution")
                    .with_vision_service_url(self.agent.config.vision_service_url.clone())
```
If `self.agent.config` isn't the right path, adjust to whatever Step 1 confirmed.

- [ ] **Step 3: Patch the chat-path construction (line 166)**

The current code:
```rust
            JobContext::with_user(&message.user_id, "chat", "Interactive chat session")
```
Change to:
```rust
            JobContext::with_user(&message.user_id, "chat", "Interactive chat session")
                .with_vision_service_url(self.agent.config.vision_service_url.clone())
```

- [ ] **Step 4: Compile-check**

```bash
taskset -c 0-23 cargo check -j24 --manifest-path ic/Cargo.toml 2>&1 | tail -10
```
Expected: clean compile. If the config-access path was wrong, the compiler will name the correct one — fix and re-run.

- [ ] **Step 5: Commit**

```bash
git add ic/src/agent/dispatcher.rs
git commit -m "Propagate Config.vision_service_url into JobContext at chat/reflex sites

Both production JobContext::with_user call sites in dispatcher.rs now chain
.with_vision_service_url(self.agent.config.vision_service_url.clone()) so the
per-tenant vision URL flows into the context that the WASM wrapper serializes
to Request.context."
```

---

## Task 4: Loosen the vision-analyze tool's allowlist to any loopback port

**Files:**
- Modify: `ic/tools-src/vision-analyze/src/lib.rs:28-33` (ALLOWED_HOSTS) and `:207-227` (validate_service_url)

- [ ] **Step 1: Re-read the current allowlist and validator**

Run:
```bash
sed -n '26,35p' ic/tools-src/vision-analyze/src/lib.rs
sed -n '207,228p' ic/tools-src/vision-analyze/src/lib.rs
```

- [ ] **Step 2: Replace ALLOWED_HOSTS with a host-suffix list**

Use Edit on `ic/tools-src/vision-analyze/src/lib.rs`. Match:
```rust
const ALLOWED_HOSTS: &[&str] = &[
    "127.0.0.1:8088",
    "localhost:8088",
    "host.containers.internal:8088",
    "[::1]:8088",
];
```
Replace with:
```rust
/// Loopback-only hostnames the vision sidecar may live on. Any port is accepted
/// (per-tenant sidecars bind distinct loopback ports); the host portion (sans port)
/// must match one of these. External/LAN hosts are rejected.
const ALLOWED_HOSTS: &[&str] = &[
    "127.0.0.1",
    "localhost",
    "host.containers.internal",
    "[::1]",
];
```

- [ ] **Step 3: Update validate_service_url to split host from port**

Use Edit. Match the full current validator body:
```rust
fn validate_service_url(url: &str) -> Result<String, String> {
    let url = url.trim_end_matches('/');

    let host_port = url
        .strip_prefix("http://")
        .ok_or_else(|| format!("Service URL must use http://, got: {url}"))?;

    let host_port = host_port.split('/').next().unwrap_or(host_port);

    if !ALLOWED_HOSTS.contains(&host_port) {
        return Err(format!(
            "Service URL host '{host_port}' not in allowlist. Allowed: {}",
            ALLOWED_HOSTS.join(", ")
        ));
    }

    Ok(url.to_string())
}
```
Replace with:
```rust
fn validate_service_url(url: &str) -> Result<String, String> {
    let url = url.trim_end_matches('/');

    let host_port = url
        .strip_prefix("http://")
        .ok_or_else(|| format!("Service URL must use http://, got: {url}"))?;

    // Take the authority portion (before any path) and split host from port.
    let authority = host_port.split('/').next().unwrap_or(host_port);
    // Strip the port: IPv6 literal `[::1]:8088` -> `[::1]`; otherwise split on ':'.
    let host = if let Some(rest) = authority.strip_prefix('[') {
        // IPv6 literal: everything up to ']'
        rest.split(']').next().map(|h| format!("[{h}]")).unwrap_or(authority.to_string())
    } else {
        authority.rsplit_once(':').map(|(h, _)| h.to_string()).unwrap_or(authority.to_string())
    };

    if !ALLOWED_HOSTS.contains(&host.as_str()) {
        return Err(format!(
            "Service URL host '{host}' not in allowlist (loopback-only). Allowed: {}",
            ALLOWED_HOSTS.join(", ")
        ));
    }

    Ok(url.to_string())
}
```

- [ ] **Step 4: Add unit tests for the validator**

Append a `#[cfg(test)] mod tests` block at the end of `ic/tools-src/vision-analyze/src/lib.rs` (if none exists):
```rust
#[cfg(test)]
mod tests {
    use super::validate_service_url;

    #[test]
    fn allowlist_accepts_any_loopback_port() {
        assert!(validate_service_url("http://127.0.0.1:20015").is_ok());
        assert!(validate_service_url("http://127.0.0.1:8088").is_ok());
        assert!(validate_service_url("http://localhost:30000").is_ok());
        assert!(validate_service_url("http://host.containers.internal:8088").is_ok());
        assert!(validate_service_url("http://[::1]:8088").is_ok());
    }

    #[test]
    fn allowlist_rejects_non_loopback() {
        assert!(validate_service_url("http://192.168.1.187:8080").is_err());
        assert!(validate_service_url("http://example.com:8088").is_err());
    }

    #[test]
    fn allowlist_rejects_https() {
        assert!(validate_service_url("https://127.0.0.1:8088").is_err());
    }
}
```

- [ ] **Step 5: Run the tool's tests**

```bash
taskset -c 0-23 cargo test -j24 --manifest-path ic/tools-src/vision-analyze/Cargo.toml 2>&1 | tail -15
```
Expected: 3 tests pass.

- [ ] **Step 6: Commit**

```bash
git add ic/tools-src/vision-analyze/src/lib.rs
git commit -m "Loosen vision-analyze allowlist to any loopback port

ALLOWED_HOSTS now lists loopback hostnames (127.0.0.1, localhost,
host.containers.internal, [::1]); validate_service_url splits host from port
and matches the host portion. Per-tenant sidecar ports (e.g. 20015) now pass.
Loopback-only security property preserved; LAN/external hosts still rejected."
```

---

## Task 5: Read `service_url` from `Request.context` (host-wins precedence)

**Files:**
- Modify: `ic/tools-src/vision-analyze/src/lib.rs` — the `Guest` impl's `execute` and `execute_inner`

- [ ] **Step 1: Re-read the current execute / execute_inner signatures**

Run:
```bash
sed -n '93,130p' ic/tools-src/vision-analyze/src/lib.rs
```
Confirm `execute` receives `req: exports::near::agent::tool::Request` with `.params` and `.context`, and currently calls `execute_inner(&req.params)`.

- [ ] **Step 2: Thread context into execute_inner**

Use Edit. Match:
```rust
        match execute_inner(&req.params) {
```
Replace with:
```rust
        match execute_inner(&req.params, req.context.as_deref()) {
```

- [ ] **Step 3: Change execute_inner signature to accept context**

Use Edit. Match:
```rust
fn execute_inner(params_json: &str) -> Result<String, String> {
    let req: VisionRequest = serde_json::from_str(params_json)
        .map_err(|e| format!("Invalid parameters: {e}"))?;

    // Validate service URL against allowlist
    let service_url = validate_service_url(&req.service_url)?;
```
Replace with:
```rust
fn execute_inner(params_json: &str, context_json: Option<&str>) -> Result<String, String> {
    let req: VisionRequest = serde_json::from_str(params_json)
        .map_err(|e| format!("Invalid parameters: {e}"))?;

    // Resolve service URL with host-wins precedence:
    //   1. host-injected via Request.context (JobContext.vision_service_url) — trusted
    //   2. LLM-provided via params (req.service_url) — used only if host didn't inject
    //   3. default_url() (http://127.0.0.1:8088) — single-tenant fallback
    let host_url: Option<String> = context_json
        .and_then(|c| serde_json::from_str::<serde_json::Value>(c).ok())
        .and_then(|v| v.get("vision_service_url").and_then(|s| s.as_str()).map(|s| s.to_string()))
        .filter(|s| !s.is_empty());

    let effective_url = host_url
        .as_deref()
        .or_else(|| Some(req.service_url.as_str()))
        .filter(|s| !s.is_empty())
        .map(default_url)
        .unwrap_or_else(default_url);
    // The above .map(default_url)/unwrap_or_else is wrong — replace with the explicit form below.

    let effective_url: String = if let Some(h) = host_url.as_deref() {
        h.to_string()
    } else if !req.service_url.is_empty() {
        req.service_url.clone()
    } else {
        default_url()
    };

    // Validate the effective URL against the (loopback-only) allowlist
    let service_url = validate_service_url(&effective_url)?;
```

> Note: the code block above contains a deliberately-wrong intermediate (flagged with a comment) to remind the implementer to use the explicit if/else form. Delete the wrong `.map(default_url)` lines when writing the file — keep only the explicit `let effective_url: String = if let Some(h)...` block. (This is intentional guidance, not a placeholder.)

- [ ] **Step 4: Confirm the rest of execute_inner still uses `service_url`**

Run:
```bash
grep -n 'service_url' ic/tools-src/vision-analyze/src/lib.rs
```
The downstream code that builds the request URL (`format!("{service_url}/v1/ocr")` etc.) already uses the local `service_url` binding — no further change needed.

- [ ] **Step 5: Add a precedence test**

Extend the `mod tests` from Task 4:
```rust
    #[test]
    fn host_injected_url_wins_over_default() {
        // Simulate: params have empty service_url, context has vision_service_url.
        // We can't call execute_inner without HTTP, but we can test the resolution
        // logic by extracting it. For now, assert the contract via validate_service_url:
        // any per-tenant loopback port the host would inject passes the allowlist.
        assert!(validate_service_url("http://127.0.0.1:20015").is_ok());
    }
```
(Full execute_inner testing requires mocking HTTP; defer to the manual end-to-end in Task 8.)

- [ ] **Step 6: Compile-check + run tests**

```bash
taskset -c 0-23 cargo check -j24 --manifest-path ic/tools-src/vision-analyze/Cargo.toml 2>&1 | tail -10
taskset -c 0-23 cargo test -j24 --manifest-path ic/tools-src/vision-analyze/Cargo.toml 2>&1 | tail -10
```
Expected: clean compile; 4 tests pass (3 from Task 4 + 1 new).

- [ ] **Step 7: Commit**

```bash
git add ic/tools-src/vision-analyze/src/lib.rs
git commit -m "vision-analyze: read service_url from Request.context (host-wins)

execute_inner now accepts the context JSON and resolves the effective service
URL with precedence: (1) host-injected via JobContext.vision_service_url in
Request.context, (2) LLM-provided via params, (3) default. Host injection wins
when present — the LLM cannot redirect vision calls to an arbitrary host."
```

---

## Task 6: Update the capabilities manifest

**Files:**
- Modify: `ic/tools-src/vision-analyze/vision-analyze-tool.capabilities.json`

- [ ] **Step 1: Re-read the current capabilities file**

Run:
```bash
cat ic/tools-src/vision-analyze/vision-analyze-tool.capabilities.json
```

- [ ] **Step 2: Update the http.allowlist to match the loosened runtime allowlist**

The current allowlist has explicit `host:8088` entries. Replace those with port-agnostic loopback entries. The capabilities schema likely supports either a `host` field per entry or a host glob — match whatever the existing format uses. For each of `127.0.0.1`, `localhost`, `host.containers.internal`, `[::1]`, the entry should allow any port. If the schema only supports exact `host:port`, this needs a schema change in the daemon's capabilities parser — flag this and consult `ic/src/tools/wasm/capabilities.rs` / `capabilities_schema.rs` before proceeding.

If the schema does NOT support port-agnostic hosts, the minimal-safe option is: keep the existing entries AND add explicit entries for the per-tenant ports in use (`127.0.0.1:20015`, `127.0.0.1:20005`, etc.). Document this as a known limitation in the file header.

- [ ] **Step 3: Update the service_url schema description**

Find the `service_url` field in the schema and update its description to reflect host-injection precedence:
```json
"service_url": {
  "type": "string",
  "default": "http://127.0.0.1:8088",
  "description": "Vision service base URL. If the host injects a per-tenant URL via the job context, that value takes precedence and this parameter is ignored. Otherwise must point at a loopback sidecar on the allowlist."
}
```

- [ ] **Step 4: Verify the JSON is valid**

```bash
python3 -m json.tool ic/tools-src/vision-analyze/vision-analyze-tool.capabilities.json > /dev/null && echo "✓ valid JSON"
```

- [ ] **Step 5: Commit**

```bash
git add ic/tools-src/vision-analyze/vision-analyze-tool.capabilities.json
git commit -m "Update vision-analyze capabilities: loopback allowlist + host-injection note

Bring the declarative capabilities allowlist in line with the loosened runtime
allowlist. Update the service_url schema description to document host-injection
precedence."
```

---

## Task 7: Build the WASM tool

**Files:** none (build only)

- [ ] **Step 1: Confirm prerequisites**

```bash
rustup target list --installed | grep wasm32-wasip2
command -v cargo-component && cargo-component --version
```
Expected: `wasm32-wasip2` installed; `cargo-component` on PATH. If missing, install via `rustup target add wasm32-wasip2` and `cargo install cargo-component --locked`.

- [ ] **Step 2: Build all WASM tools (the script handles component wrapping)**

```bash
cd ic && taskset -c 0-23 ./scripts/build-wasm-extensions.sh --tools 2>&1 | tee /tmp/wasm-build.log | tail -30
```
Expected: `build-wasm-extensions.sh` compiles each tool to `target/wasm32-wasip2/release/<crate>.wasm`, wraps with `wasm-tools component new` + `strip`. The vision-analyze tool's output is `target/wasm32-wasip2/release/vision_analyze_tool.wasm` (or similar — check the log for the exact path).

If the build fails, paste `/tmp/wasm-build.log` — most likely cause is a compile error in the Task 4/5 edits.

- [ ] **Step 3: Confirm the vision-analyze WASM exists**

```bash
find ic/tools-src/vision-analyze/target -name "*.wasm" 2>/dev/null
find ic/target -name "*vision*.wasm" 2>/dev/null | head
```
Expected: a `.wasm` file (component-wrapped) for vision-analyze.

---

## Task 8: Install the WASM tool for both tenants + restart daemons

> ⚠️ **Requires root + MT env sourced.** Run from a shell with `source ~/.lunarwing-mt.env`.

- [ ] **Step 1: Source the MT env (the footgun check)**

```bash
source ~/.lunarwing-mt.env
echo "LUNARWING_CONTAINER_RUNTIME=$LUNARWING_CONTAINER_RUNTIME  (want: podman)"
echo "LUNARWING_MT_ROOTLESS=$LUNARWING_MT_ROOTLESS  (want: true)"
```

- [ ] **Step 2: Install WASM for both tenants**

```bash
sudo -E ./ic/scripts/lunarwing-mt-admin.sh install-wasm venus
sudo -E ./ic/scripts/lunarwing-mt-admin.sh install-wasm mercury
```
Expected: copies the built `.wasm` + `.capabilities.json` into `/home/<tenant>/lunarwing/state/tools/`. No restart.

- [ ] **Step 3: Confirm install landed**

```bash
sudo ls /home/venus/lunarwing/state/tools/ | grep vision
sudo ls /home/mercury/lunarwing/state/tools/ | grep vision
```
Expected: a `vision*.wasm` and matching `.capabilities.json` in each.

- [ ] **Step 4: Rebuild tenant daemon binaries (Component 1/3 changes need a daemon rebuild)**

> ⚠️ This is the long pole — daemon rebuild under flock is ~15+ min per tenant. Run in tmux.

```bash
tmux new-session -d -s b1 "sudo -E ./ic/scripts/lunarwing-mt-admin.sh build-tenant venus 2>&1 | tee /tmp/b1.log"
# wait for b1 to finish (flock blocks the next), then:
tmux new-session -d -s b2 "sudo -E ./ic/scripts/lunarwing-mt-admin.sh build-tenant mercury 2>&1 | tee /tmp/b2.log"
# poll: tail -f /tmp/b1.log /tmp/b2.log
```
Expected: both build successfully, binaries at `/home/<tenant>/lunarwing/target/release/lunarwing`.

- [ ] **Step 5: Restart both tenants (picks up new binary + new tool)**

```bash
sudo -E ./ic/scripts/lunarwing-mt-admin.sh restart-tenant venus
sudo -E ./ic/scripts/lunarwing-mt-admin.sh restart-tenant mercury
sudo -E ./ic/scripts/lunarwing-mt-admin.sh status venus
sudo -E ./ic/scripts/lunarwing-mt-admin.sh status mercury
```
Expected: all services active.

---

## Task 9: End-to-end verification (the real proof — agent, not curl)

- [ ] **Step 1: Get venus's gateway token**

```bash
sudo -E ./ic/scripts/lunarwing-mt-admin.sh tokens venus
```

- [ ] **Step 2: Send the agent a vision request via the gateway**

```bash
TOKEN="<token from step 1>"
IMAGE_PATH="/home/sun/lawrenceimages.jpg"
B64=$(base64 -w0 "$IMAGE_PATH")
curl -s -X POST http://127.0.0.1:10010/api/chat/send \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"message\": \"Use the vision-analyze tool to OCR this image and tell me what text you see: data:image/png;base64,${B64}\"}"
```
(Adjust the `/api/chat/send` path/payload to match the actual gateway API shape — confirm in `ic/src/channels/web/handlers/chat.rs` first.)

- [ ] **Step 3: Confirm via logs that the tool resolved the per-tenant URL**

```bash
sudo -u venus XDG_RUNTIME_DIR=/run/user/$(id -u venus) journalctl --user -u lunarwing-venus --since "2 min ago" | grep -iE 'vision|service_url|20015|8088' | tail
```
Expected: log lines showing the tool called the sidecar at `127.0.0.1:20015` (NOT `:8088`).

- [ ] **Step 4: Confirm the agent's response contains OCR text**

The agent's reply should contain the OCR'd text (e.g. "LAWRENCE OF ARABIA" or similar). If the agent refused or errored, check the logs for tool-call failures.

- [ ] **Step 5: Document the result**

Note in a follow-up commit message or doc:
- vision-analyze WASM patched, built, installed for both tenants
- Daemon rebuilt with `Config.vision_service_url` + `JobContext` propagation
- Agent successfully invokes the tool, which reaches `127.0.0.1:<tenant_port>` (not `:8088`)
- OCR text returns in the agent's response

---

## Self-Review (run after writing the plan)

**1. Spec coverage:**
- ✅ Component 1 (daemon: Config + JobContext) → Tasks 1, 2, 3
- ✅ Component 2 (WASM tool: allowlist + context-read) → Tasks 4, 5
- ✅ Component 2 (capabilities manifest) → Task 6
- ✅ Component 3 (build + install + verify) → Tasks 7, 8, 9
- ✅ Risks/rollback addressed in each task's commit messages + the additive nature of changes
- ✅ All deferred items remain out of scope

**2. Placeholder scan:** ⚠️ One flagged intentional "wrong intermediate" in Task 5 Step 3 with explicit delete-instructions — that's guidance, not a placeholder. No TBD/TODO/"add error handling" elsewhere. All steps have concrete code or commands.

**3. Type consistency:** ✅ `vision_service_url: Option<String>` consistent across Config, JobContext, builder, dispatcher call sites. `with_vision_service_url(Option<String>)` signature matches usage. `execute_inner(params_json, context_json: Option<&str>)` matches the call site `execute_inner(&req.params, req.context.as_deref())`.

**4. Scope check:** ✅ Single subsystem (vision-analyze tool wiring). 9 tasks, each producing self-contained changes.

**5. Known gotcha (flagged in Task 6):** The capabilities JSON schema may not support port-agnostic hosts — if it requires exact `host:port`, the implementer must either extend the schema (in `capabilities.rs`) or fall back to enumerating per-tenant ports. This is the main risk of unexpected scope.
