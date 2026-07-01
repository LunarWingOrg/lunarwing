# Port IronClaw Reborn Architecture Mechanisms to LunarWing

**Date:** 2026-06-30
**Status:** Analysis complete. No code implemented. Selective mechanism backport — **not** a Reborn adoption.
**Kind:** Architecture-level analysis (not a per-release delta). Appends to the `OLDPROJECT_PORT_ANALYSES/` series (0.28.1 / 0.28.2 / 0.29.0 / 0.29.1).

## Context

"Reborn" is IronClaw's ground-up re-architecture (~April 2026 onward) from the legacy `src/` monolith into ~76 `ironclaw_*` crates split along a kernel (security perimeter) / userland boundary, shipped as a separate beta `ironclaw-reborn` binary alongside the still-default legacy monolith. LunarWing forked from IronClaw **≈0.29.x in Feb 2026 — before Reborn** — so it is the pre-Reborn monolith (`ic/src/` + 4 extracted crates: `lunarwing_common` / `safety` / `skills` / `engine`). This analysis triages which Reborn *mechanisms* are worth grafting onto the monolith, not whether to adopt Reborn (it isn't — see Skip).

**Two framing facts that shape everything below:**

1. **Reborn is unfinished upstream.** The shipping `ironclaw` binary is still the legacy monolith; the Reborn crates are `0.1.0` with ~105 `todo!/unimplemented!` markers. Several "structurally enforced" properties are real, but production wiring (secrets, channels, SSE) is not done. So this is "mine good ideas," never "catch up to upstream."
2. **`lunarwing_engine` (Engine v2) is now a permanent fork.** Reborn **condemned `ironclaw_engine`** — it appears only in *forbidden*-dependency lists in `crates/ironclaw_architecture/tests/reborn_dependency_boundaries.rs` (17×), no Reborn crate depends on it, and Reborn docs label it "legacy." Reborn didn't reject Engine v2's ideas; it **promoted** them out of the executor crate into kernel contract crates (`Thread→ironclaw_threads`, `Capability→ironclaw_capabilities`, event-sourcing→`ironclaw_events`, `Project→ironclaw_projects`, `Step/turns→ironclaw_turns`+`ironclaw_agent_loop`, authority→`ironclaw_authorization`/`ironclaw_approvals`/`ironclaw_run_state`). **Consequence:** stop diffing `lunarwing_engine` against upstream `ironclaw_engine` (LunarWing is the sole maintainer now); when a mechanism is worth backporting, mine it from the **kernel crate that re-homed it** and graft it onto `lunarwing_engine` via the existing `bridge/` seam. Worth recording in `FORK_CONTEXT.md`.

**Relationship to existing proposals:** the built-in `http` tool's SSRF posture is already documented in `../HTTP_TOOL_SSRF_PROTECTIONS.md` (that path is at parity with Reborn — see Already Present). P1-A below covers a *different* egress path (the sandbox proxy). P1-B overlaps the MULTICA "bare-`*` host allowlist" item in the series `README.md` — see the reconciliation note there.

**Crates analyzed:** `ironclaw_capabilities`, `ironclaw_authorization`, `ironclaw_approvals`, `ironclaw_trust`, `ironclaw_secrets`/`ironclaw_auth`, `ironclaw_network` + `ironclaw_host_runtime/egress`, `ironclaw_events`/`event_projections`/`event_streams`/`reborn_event_store`, `ironclaw_host_api` (ids/scope), `ironclaw_architecture` (boundary tests).

---

## Changes NOT Applicable to LunarWing (Skip)

| Reborn mechanism | What it is | Why skip |
|---|---|---|
| 76-crate kernel/userland topology + `ironclaw_reborn_composition` + `ironclaw-reborn` binary | The whole re-split | No end-user value; XL multi-quarter migration; upstream itself still ships the monolith (0.1.0/stubbed). Extract *mechanisms*, never the graph. |
| `AgentLoopDriver` / `DriverRegistry` / `LoopExitApplier` (`ironclaw_turns`, `ironclaw_reborn`) | Hot-swap multiple versioned loop *implementations* behind a trusted exit handshake | LunarWing already has one `run_agentic_loop()` + `LoopDelegate` (Chat/Job/Container) + Engine v2. No need to register/version multiple driver impls. |
| `ironclaw_telegram_v2_adapter`, `ironclaw_slack_v2_adapter`, `ironclaw_product_adapters*` | Proprietary channels behind a normalized product-adapter contract | Charter rejects proprietary channels; LunarWing uses WASM channels + a separate XMPP/OMEMO bridge (structurally different model). |
| `ironclaw_webui_v2*`, `ironclaw_reborn_openai_compat*`, `ironclaw_reborn_webui_ingress` (signed-session) | New browser UI + OpenAI-compat host + OIDC signed session | LunarWing already ships `src/channels/web/` + `src/channels/web/openai_compat.rs`; Reborn versions are duplicative rewrites tied to the composition stack. Attestation story is XMPP/OMEMO, not signed browser sessions. |
| `FirstParty`/`System` runtime lanes + `ironclaw_scripts` (Docker `ironclaw_process_sandbox`) | Host-minted trust lanes + a Docker script-runner lane | LunarWing first-party == native compiled-in code already mediated by `ToolDispatcher`; a Docker process-sandbox lane contradicts the WASM-first, lightweight self-hosted posture. |
| `ExecutionContext::validate()` 7-axis `ResourceScope` coherence check | tenant/user/agent/project/mission/thread/invocation coherence gate | Tenancy in LunarWing is **physical** (per-tenant OS user/PG/port/bridge), so there's no in-process `tenant_id`/`agent_id` axis; `validate()` only pays off once you've built the duplicated-context problem it exists to catch. Port only the `UserId` axis (P2-B). |

---

## Already Present in LunarWing (no port needed)

- **Exact-invocation / one-shot / no-replay approvals.** Reborn's fingerprinted `CapabilityLease` guards "approve A / execute B" and replay. LunarWing's `gate/` achieves the *same guarantee by a stronger mechanism for its architecture*: `PendingGate` freezes the exact `{action, call_id, parameters}` + an **unforgeable random `request_id` UUID nonce**; `PendingGateStore::take_verified` atomically consumes under one Mutex (`test_concurrent_take_only_one_succeeds` pins exactly-one-winner); resume executes the **frozen snapshot**, and the resume payload structurally cannot carry parameters (`{request_id, action, thread_id}` only). Since each tenant is a separate process, the in-process Mutex is a sufficient atomicity boundary — Reborn's cross-process CAS-over-filesystem lease solves a race LunarWing doesn't have. *Backporting the fingerprint machinery would be net-negative complexity.* (Optional P2-F tamper tripwire below.)
- **Effect/grant default-deny model** — already exists in `lunarwing_engine` (`EffectType`, `ActionDef.effects`, `CapabilityLease`, `PolicyEngine` Deny>RequireApproval>Allow, default-deny enforcement in `executor/structured.rs`). Don't add a *third* authorization model; converge on this one (P2-D).
- **Secret redaction** — `DecryptedSecret` wraps `secrecy::SecretString` with a `[REDACTED, N bytes]` `Debug`; records hold names/handles only; crypto errors carry no plaintext. Audited: no `.expose_secret()` call site logs a value. Reborn's `[REDACTED]`-Debug pattern buys nothing here.
- **SSRF hardening on the primary `http` tool** — `src/tools/builtin/http.rs` already does DNS-resolve-then-pin (`resolve_to_addrs`), per-hop redirect revalidation, streamed size caps, IPv4-mapped-IPv6 handling, and blocks private IPs unconditionally — at parity with `ironclaw_network`. Documented in `../HTTP_TOOL_SSRF_PROTECTIONS.md`. (The gaps are on the *other two* egress paths — see P1-A.)
- **XMPP non-UUID conversation-scope isolation** — already fixed via `scoped_conversation_id()` (stable UUID-v5, length-prefixed) in the 0.29.1 port. Typed IDs would *not* have prevented it (it was a parse-fallback, not type confusion).

---

## P0 — Security / Correctness

**None.** No analyzed mechanism exposes a LunarWing vulnerability severe enough for P0 (no unauth RCE / silent-auto-approve / plaintext-secret-leak). The two security items below are P1.

---

## P1 — High Priority

### P1-A: Sandbox proxy follows redirects → domain-allowlist bypass / SSRF from worker containers
**Reborn source:** `ironclaw_network/transport.rs` (`redirect::Policy::none()` + revalidate) | **Complexity:** S | **Dependencies:** none (reqwest already dep) | **Adapt-not-copy**

**Why:** `src/sandbox/proxy/http.rs` builds `ProxyState.http_client` with `reqwest::Client::new()` and **no redirect policy** — reqwest 0.12 then follows up to 10 redirects that are **never re-checked against the allowlist**. `decider.decide()` runs once *before* `forward_request`; the `Location` host is never re-validated. This proxy is the **sole egress boundary for untrusted Docker worker containers** (`manager.rs` build_and_start). Net effect: an allowlisted (or container-influenced) host can `302` a container's request to **any** host — including `169.254.169.254` or the operator's private network — and the proxy fetches it and returns the body, carrying any header/query-injected credentials across the redirect. Confirmed trust-boundary bypass + SSRF. Not P0 only because it requires the sandbox enabled + already-sandboxed container code, and it's exfil, not host RCE. Complements the `http`-tool hardening in `../HTTP_TOOL_SSRF_PROTECTIONS.md` — this is the one egress path that lacks equivalent protection.

**What to change:** Set `redirect::Policy::none()` on `ProxyState.http_client`; in `forward_request`, return the upstream `3xx` to the container unmodified (a container re-request re-enters `decider.decide()`) **or** re-run `state.decider.decide()` on the `Location` host before following. This is Reborn's disable+revalidate applied to the one LunarWing egress path lacking it.

**LunarWing files:** `src/sandbox/proxy/http.rs` (client build ~L89, `forward_request` ~L327-441), `src/sandbox/proxy/policy.rs`, `src/sandbox/manager.rs`.
**IronClaw reference:** `crates/ironclaw_network/src/transport.rs` (redirect::none + per-hop revalidate).
**Adaptation:** Orthogonal to IP policy — **do not** import `deny_private_ip_ranges`; `ALLOW_PRIVATE_IPS=1` / TensorZero `192.168.1.157` / local Ollama stay working.

### P1-B: WASM tool credential-injection ceiling — a community tool may exfiltrate a pre-provisioned host secret
**Reborn source:** `ironclaw_trust` `AuthorityCeiling` (the *ceiling* idea, not the type-trick) | **Complexity:** M | **Dependencies:** `trust_level` column already exists (PG+libSQL) | **Adapt-not-copy**

> **Reconciliation / verify-first:** The series `README.md` lists a landed MULTICA "Bare-`*` host allowlist" fix at `capabilities.rs:238`, but the current code still treats bare `*` as match-all in both `HttpCapability::host_matches` (`capabilities.rs`) and `host_matches_pattern` (`credential_injector.rs`, tested at `host_matches_pattern("localhost","*") == true`). Also, `CredentialInjector` **does** gate secrets via `is_secret_allowed` / `allowed_secrets` (used by the builtin `http` tool), but the **WASM host path** `resolve_host_credentials` (`wrapper.rs`) calls `store.get_decrypted(user_id, &mapping.secret_name)` directly and appears **not** to apply that gate. **Confirm both against current `main` before implementing** — the exact residual surface may be narrower than described if later hardening landed.

**Why:** The self-promotion vector Reborn's type-level trick guards **doesn't exist** in LunarWing (skills get trust by source dir with no manifest field; WASM `TrustLevel` isn't `Deserialize`). But the *other half* — trust as an enforced **authority ceiling** — is missing: `TrustLevel` is **vestigial** (only logged at `registry.rs`, never threaded into `to_capabilities()`). Given the two gaps above, a `TrustLevel::User` community WASM tool shipping `capabilities.json` with `credentials{secret_name:"google_oauth_token", host_patterns:["*"]}` + `allowlist host "*"` can inject a **pre-provisioned** OAuth token and reach any host — gated today only by SHA256-of-binary and a non-blocking install printout. Real supply-chain risk for the "self-hoster installs a registry tool" story.

**What to change:** Thread `trust_level` into the capability-build step (`capabilities_schema.rs::to_capabilities`, called from `loader.rs` which currently hardcodes `User`) and **attenuate the self-declared sidecar per level** for `User`-trust tools: (a) reject/strip credential mappings naming a pre-existing host secret the tool didn't provision (esp. OAuth tokens), or require tool-scoped secrets — i.e. apply an `allowed_secrets`-style gate on the WASM host path too; (b) deny wildcard `allowlist`/`host_patterns` `"*"` (force concrete hosts); (c) deny `tool_invoke` aliases resolving to privileged builtins (shell/file_write/http). Reserve unrestricted injection / wildcards for `Verified`/`System` (operator-set in DB). Add an **install-time consent gate** in `src/cli/tool.rs` for sensitive caps instead of print-and-proceed. Skills need no change.

**LunarWing files:** `src/tools/wasm/{storage.rs,loader.rs,capabilities.rs,capabilities_schema.rs,wrapper.rs,credential_injector.rs}`, `src/tools/registry.rs`, `src/cli/tool.rs`.
**IronClaw reference:** `crates/ironclaw_trust/src/decision.rs` (`AuthorityCeiling`), `policy.rs` (fail-closed Sandbox default).
**Adaptation:** Ceiling targets **which secrets + host breadth**, never IP class — a User tool legitimately reaching `192.168.x` must keep working; the `ALLOW_PRIVATE_IPS` branch in `wrapper.rs` is untouched. Single-user self-hosters bump their own tools to `Verified` in DB.

### P1-C: Durable event log + resumable SSE (fixes reconnect drift; adds per-tenant audit trail)
**Reborn source:** `ironclaw_events` (cursor/replay) + `ironclaw_event_streams` (rebase-on-gap) | **Complexity:** L | **Dependencies:** dual-backend migration | **Adapt-not-copy**

**Why:** LunarWing's SSE is fire-and-forget `tokio::broadcast` (buffer 256, lagged clients silently drop); frames set **no `id:`**, `chat_events_handler` reads **no Last-Event-ID/cursor**, and the frontend papers over it with a `loadHistory()` reload that only rebuilds persisted `conversation_messages` — so **ephemeral events (`gate_required`, `approval_needed`, `tool_started`, `thread_state_changed`, `extension_status`) are permanently lost across a missed window.** For an XMPP/mobile-first agent whose SSE drops constantly (sleep/roaming/tunnels), the UI diverges from backend state — the exact drift class Reborn's `#2792` epic was built to kill. Second win: LunarWing has **no restart-surviving audit trail** (`ActionRecord` is in-memory); a durable per-`(user,thread)` append log gives each tenant real self-host/forensic value it lacks entirely. **Cost is bounded because LunarWing already ships this pattern once** — `job_events` (`BIGSERIAL PK` = cursor, `(job_id,id)` index, append-only) — it just isn't cursor-parameterized or wired to chat SSE.

**What to change:** (1) Generalize `job_events` → `chat_events(id monotonic, user_id, thread_id, event_type, data, created_at)` with `append_chat_event` / `list_chat_events_after` on a dual-backend sub-trait (`BIGSERIAL`→libSQL `INTEGER` autoincrement; the id *is* the cursor); best-effort emit (append failure logs, never aborts the turn). (2) Append-then-broadcast for the high-value emitters among the 38 broadcast sites; keep `Heartbeat`/`StreamChunk` transport-only (mirror IronClaw's allowlist). (3) Set `Event::id(cursor)` on every frame; read `Last-Event-ID` in `chat_events_handler`, replay-then-attach deduping by cursor, emit a `rebase`+snapshot marker when the cursor predates the earliest row; drop the frontend `>10s loadHistory` heuristic. **Skip** the projection-DTO/redaction-validator superstructure and tenant/agent `EventStreamKey` richness — `(user_id, thread_id)` is enough for a monolith. Reuse `lunarwing_safety` redaction before persist/broadcast.

**LunarWing files:** `src/channels/web/{sse.rs,server.rs,static/app.js,types.rs}`, `src/db/mod.rs` (+`postgres.rs`/`libsql/`), `migrations/` (+ new `VN__chat_events.sql`), `src/context/memory.rs` / `src/tools/tool.rs` (in-memory `ActionRecord`).
**IronClaw reference:** `crates/ironclaw_events/src/{cursor,sink,error}.rs`, `crates/ironclaw_event_streams/src/manager.rs`, `.claude/rules/gateway-events.md`.
**Note:** Even upstream's *legacy* gateway lacks this — genuinely new capability, argued on its own merits. Not P0 (a dropped `approval_needed` strands the UI, never auto-approves).

### P1-D: Project static-file handlers take no `AuthenticatedUser` (missing ownership check) — *verify first*
**Reborn source:** the "cross-scope = non-existence" convention | **Complexity:** S | **Dependencies:** none

**Why:** Surfaced during scope analysis: `src/channels/web/handlers/static_files.rs` `project_file_handler`/`project_index_handler` take only a `Path` with **no `AuthenticatedUser`** (while `logs_events_handler` in the same file *does*), and hand-roll a `contains('/')||".."` guard on `project_id` — so they appear to never verify the project belongs to the requester. If confirmed, that's an IDOR on project files. **Flagged for direct verification before implementing** (it's a side-observation, not the core of a Reborn mechanism).

**What to change:** Add the `AuthenticatedUser` extractor + ownership check (reuse `TenantScope`'s existing non-existence-on-mismatch behavior); replace the ad-hoc path guard with the P2-B `UserId`/path validation once available.
**LunarWing files:** `src/channels/web/handlers/static_files.rs`, `src/tenant.rs`.

---

## P2 — Medium Priority

### P2-A: Reorder credential injection vs. leak-scan on the built-in http tool
**Reborn source:** `ironclaw_host_runtime/egress` scan-then-inject ordering | **Complexity:** S | **Adapt-not-copy**

`src/tools/builtin/http.rs` injects the credential into `headers_vec` **then** leak-scans that same vector. Because `LeakDetector` has **Block** patterns for `github_token`/`google_api_key`/`aws_access_key`/etc., injecting a managed `Authorization: Bearer ghp_…` makes the tool **block its own legitimately-injected credential** (`SecretLeakBlocked → NotAuthorized`). Move the scan to run on **caller-provided URL/headers/body BEFORE injection** — kills the false-positive self-block while preserving exfiltration detection. While here, wire `record_usage()` on the injection paths that currently skip it (`http.rs`, `channels/wasm/wrapper.rs`, `config/mod.rs`) for per-secret audit. *(Fails-closed today, so P2 not P1.)*
**Files:** `src/tools/builtin/http.rs`, `crates/lunarwing_safety/src/leak_detector.rs`, `src/secrets/store.rs`.

### P2-B: Validated `UserId` newtype minted at channel ingress
**Reborn source:** `ironclaw_host_api/src/ids.rs` `validate_scope_id` | **Complexity:** S-M (incremental) | **Adapt-not-copy**

`user_id` is LunarWing's most security-critical axis, it **originates from untrusted XMPP JIDs** at ingress, and flows as a bare `String` through 48 DB methods into SQL `WHERE` clauses and (via `~/.lunarwing/projects/<id>/`) filesystem paths. Add a `UserId` newtype to `lunarwing_common` mirroring `validate_scope_id` (reject empty/>256B/`.`/`..`/`/`/`\`/control) minted **only** at `src/channels/channel.rs` ingress, then thread incrementally into `TenantScope::new` + the highest-value DB methods. Lets `static_files.rs` (P1-D) and project handlers drop hand-rolled guards. **Only the user axis** — not `TenantId`/`AgentId` (no in-process analog). Do **not** apply to conversation-scope strings (JIDs legitimately contain `/@.` — keep routing them through `scoped_conversation_id`). Not a 537-site big-bang.
**Files:** `crates/lunarwing_common/src/lib.rs`, `src/channels/channel.rs`, `src/tenant.rs`, `src/db/mod.rs`.

### P2-C: Stop `lunarwing_engine` `AccessDenied` from leaking cross-user existence
**Reborn source:** "non-existence not authz" convention | **Complexity:** S

15 `EngineError::AccessDenied { user_id, entity }` sites (`runtime/{conversation,manager,mission}.rs`) return a distinguishable authz error on cross-user access — an existence oracle, opposite to both Reborn's convention and LunarWing's own `TenantScope` (which returns `NotFound`). Return a `NotFound`-shaped result instead. `EngineError` does **not** derive `Serialize`, so this is a pure internal refactor (no wire migration). *(Echoes the caller's own `user_id`, so lower severity — the leak is the error type, not an id.)*

### P2-D: Obligations-style grant → WASM `Capabilities` derivation (closes "built tools get empty capabilities")
**Reborn source:** `ironclaw_authorization::obligations_for_grant` (the *shape*) | **Complexity:** M | **Adapt-not-copy**

The documented gap "built tools get empty capabilities; need UX for granting access" (`ic/CLAUDE.md` #5) is exactly what Reborn's obligations pattern solves: port the *shape* of `obligations_for_grant` as a function mapping an approved effect grant → `Capabilities` (`Network⇒http allowlist`, `UseSecret⇒secrets allowlist`, `ReadLocal⇒workspace_read`). Optionally give `lunarwing_engine`'s `CapabilityLease` a `(tenant_id,user_id)` principal key + a durable dual-backend store (note: `bridge/store_adapter.rs` already persists some leases to workspace JSON — fix that split-brain rather than greenfield). Add `effects()` to the legacy `Tool` trait so `seeded_default_permission` is effect-driven (any `WriteExternal`/`Financial` ⇒ ≥`AskEachTime`), unifying the two authorization models on **one** effect vocabulary instead of adding a third. Do **not** port `CapabilityHost`/CAS/trust-ceiling/spawn-auth.
**Files:** `src/tools/{tool.rs,permissions.rs,wasm/capabilities.rs}`, `crates/lunarwing_engine/src/capability/*`, `src/agent/scheduler.rs`.

### P2-E: Compile the orphaned boundary greps into CI + add a ToolDispatcher-bypass check
**Reborn source:** `ironclaw_architecture` (the *source-grep* style, not the crate-graph test) | **Complexity:** S | **Adapt-not-copy**

The cargo-metadata crate-graph test is **near-vacuous** for a 5-crate monolith (Rust already rejects dep cycles). But LunarWing **already wrote** the valuable checks in `scripts/check-boundaries.sh` (DB-driver isolation, `src/llm` isolation) — and **CI runs neither it nor `pre-commit-safety.sh`** (`quality_gate*.sh` = clippy + test only). Move those greps into a `tests/architecture_boundaries.rs` so they ride `cargo test`/CI, and add the highest-value missing check: **channels/handlers must not touch `state.{store,workspace,extension_manager,session_manager}` directly** (the "everything goes through `ToolDispatcher`" invariant, with a `// dispatch-exempt:` escape hatch) — LunarWing enforces this *nowhere* mechanically today. If a grep-based egress rule is added, assert "all egress via `NetworkPolicyDecider`/proxy," **never** "reject private IPs."
**Files:** `scripts/check-boundaries.sh`, `scripts/ci/quality_gate*.sh`, new `tests/architecture_boundaries.rs`, `src/tools/dispatch.rs`.

### P2-F (optional): Gate tamper-tripwire
**Complexity:** Trivial. Belt-and-suspenders only, since approvals are already solid: at `PendingGate` insert store `content_digest = sha256(canonical_json(action_name+parameters))`; recompute before `execute_pending_gate_action` and assert equality. Add a regression test asserting resolve paths (web/XMPP/CLI) carry **no** resume-time parameters (the invariant that makes fingerprinting unnecessary). Note the one looser binding: `find_lease_for_action` resolves by action *name* — fine today because params come from the frozen snapshot, but don't let name-based lookup become the authorization boundary.

---

## Recommended Implementation Order

```
Security first, cheap-and-confined first:
1.  P1-A  Sandbox proxy: disable+revalidate redirects            [S]  security, confined
2.  P2-A  Reorder http-tool leak-scan before injection           [S]  fixes self-block; trivial
3.  P1-D  Verify + fix project static-file ownership check        [S]  IDOR — CONFIRM FIRST
4.  P1-B  WASM credential-injection ceiling + install consent     [M]  supply-chain — RECONCILE w/ MULTICA first
5.  P2-C  Engine AccessDenied -> non-existence                    [S]  internal, no wire migration
6.  P2-B  Validated UserId newtype at ingress (incremental)      [S-M] forward hardening
7.  P1-C  Durable chat_events log + resumable SSE                [L]  correctness + per-tenant audit
8.  P2-D  Grant->Capabilities derivation (built-tools gap)       [M]  UX; unify on one effect vocab
9.  P2-E  Boundary greps -> cargo test + dispatch-bypass check   [S]  CI wiring
10. P2-F  Gate tamper-tripwire + no-resume-params test           [Trivial] optional
```

## Verification

- Per item: `cargo fmt && cargo clippy --all --benches --tests --examples --all-features` (zero warnings); `cargo test`; `cargo check --no-default-features --features libsql` (dual-backend); `scripts/pre-commit-safety.sh`. Every fix needs a regression test (commit-msg hook enforced).
- **P1-A:** test that a `302` from an allowlisted host to an off-allowlist host is **not** fetched by the proxy.
- **P1-B:** test that a `User`-trust tool declaring `host:"*"` + `google_oauth_token` injection is capped/denied; that a `Verified` tool is not. (First re-confirm the residual surface against current `main`.)
- **P1-C:** reconnect with `Last-Event-ID` replays missed `gate_required`/`approval_needed`; a stale cursor triggers rebase; dual-backend parity.
- **P2-A:** a `ghp_`-shaped secret injected as an http credential is **not** blocked, but a `ghp_` value in a caller-supplied body **is**.
- **P1-D:** user A cannot fetch user B's project file (returns not-found, not the file).

---

**Net read:** Reborn is mostly *not* for LunarWing — the topology, loop framework, product adapters, and new surfaces are all skip. The payoff is a short list of **security-mechanism grafts**, and the two that matter most (P1-A proxy SSRF, P1-B WASM credential-exfil ceiling) are real holes in LunarWing *today*, findable only because Reborn's contracts gave a checklist to audit against. Everything is adapt-not-copy onto the monolith + `lunarwing_engine`; none of it touches `ALLOW_PRIVATE_IPS`.
