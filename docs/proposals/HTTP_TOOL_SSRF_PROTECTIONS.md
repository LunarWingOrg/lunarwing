# Agent HTTP Tool SSRF Protections Investigation

## Status

- Investigation completed 2026-06-27
- No code changes — protections are deliberate security controls
- If private-network downloads are needed for test harness, add gated `ALLOW_PRIVATE_IPS` bypass

## Problem

The agent's built-in `http` tool refuses certain URLs, preventing the agent from downloading files. The LLM narrates these failures as "SSRF protection" or "only https:// allowed" but conflates the actual mechanisms.

## The 4 Protections

All in `ic/src/tools/builtin/http.rs`:

### 1. HTTPS-only scheme allowlist (lines 117-121)
```rust
if parsed.scheme() != "https" {
    return Err(ToolError::NotAuthorized("only https URLs are allowed".to_string()));
}
```
- Blocks `aesgcm://`, `http://`, `ftp://`, etc.
- Prevents MITM injection of malicious content into agent context
- Re-checked on every redirect hop (line 677)

### 2. SSRF private-IP blocklist (lines 210-239)
- Blocks: private (10.x, 172.16-31.x, 192.168.x), loopback, link-local (169.254.x including cloud metadata 169.254.169.254), multicast, unspecified, carrier-grade NAT (100.64-127.x)
- Also catches IPv4-mapped IPv6 (`::ffff:10.0.0.1`)
- Prevents agent from hitting cloud metadata endpoints, localhost admin APIs, or internal services

### 3. Redirect re-validation (lines 600-714)
- reqwest built with `Policy::none()` (no auto-redirect)
- Simple GETs (no body, no headers): follow up to 3 redirects, each re-validated against #1 and #2
- Non-simple requests (POST, custom headers): redirects hard-blocked with "blocked to prevent SSRF"

### 4. Approval gating (lines 846-864)
- Plain GET with no headers: `ApprovalRequirement::Never` (no approval needed)
- GET with auth headers or credential-registry match: `UnlessAutoApproved`
- Blocks requests with credentials unless auto-approved

## Why These Should Not Be Removed

AGENTS.md explicitly states: *"Do not weaken bearer-token auth, webhook auth, CORS/origin checks, body limits, rate limits, allowlists, or secret-handling guarantees."*

Removing any of these would allow:
- Agent to access cloud metadata (credential theft)
- Agent to hit internal admin APIs
- MITM injection of poisoned content
- Uncontrolled redirect chains

## If Private-Network Downloads Are Needed

For test harness / development only, add a gated bypass:

```rust
fn allow_private_ips() -> bool {
    std::env::var("ALLOW_PRIVATE_IPS")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}
```

This pattern already exists in:
- `ic/src/config/helpers.rs:256` (config-time URL validation)
- `ic/src/tools/wasm/wrapper.rs.ALLOW_PRIVATE_IPS.patch` (WASM tool wrapper)

But is **missing** from `ic/src/tools/builtin/http.rs`. Adding it there, gated behind the env var, would allow test harness downloads while keeping production secure.

## Note on aesgcm:// URLs

The `aesgcm://` scheme should never reach the agent's HTTP tool. The XMPP channel handles `aesgcm://` download + decryption before the attachment reaches the agent (see `download_aesgcm_file()` in `ic/src/channels/xmpp/mod.rs:3060`). The OMEMO URL leak fix (commit `1fdcf362`) ensures the raw URL is stripped from the message body. If `aesgcm://` URLs are still reaching the agent after that fix, the WASM attachment trap (see `XMPP_WASM_ATTACHMENT_TRAP.md`) is the likely upstream cause.
