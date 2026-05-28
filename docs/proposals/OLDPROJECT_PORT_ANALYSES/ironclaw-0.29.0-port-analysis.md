# Port IronClaw 0.29.0 Changes to LunarWing

**Date:** 2026-05-27 (audited 2026-05-28)
**Status:** Analysis complete. Advisory audit run 2026-05-28 via `cargo deny check advisories` — see [Audit Findings](#audit-findings-2026-05-28). P0-A's named simple-bump path turned out to be empty in the current lockfile; the wasmtime exposure (P0-B) accounts for 12 of 19 current advisories.

## Context

IronClaw v0.29.0 (tag `ironclaw-v0.29.0`, 16 commits after the 0.28.2 release) shipped on
2026-05-26. This document identifies which changes are worth porting to LunarWing 1.0.7,
prioritized by security impact and alignment with LunarWing's privacy-first, self-hosted mission.

0.29.0 is a feature-and-hardening release: a new proprietary channel (skipped here), one
externally-provided-tools feature for the Responses API (which LunarWing only stubs), two
operability features (log download in the gateway and the TUI), an engine safety flag, an
embeddings crate extraction, and a batch of security dependency bumps. Unlike 0.27/0.28 (the
"reborn" substrate, multi-tenant isolation), 0.29.0 carries no large architectural rewrite.

> Note on scope: LunarWing forked from IronClaw around v0.21 and the locally-checked-out
> IronClaw tree is at 0.26. This analysis covers the **0.28.2 → 0.29.0 delta only**, matching the
> sibling `ironclaw-0.28.1-port-analysis.md` / `ironclaw-0.28.2-port-analysis.md` documents.

**Commits analyzed:**

| Commit | Description |
|--------|-------------|
| `cab708ed3` | feat(engine): `IRONCLAW_DISABLE_CODEACT` flag to disable v2 CodeAct (#3665) |
| `c93c45524` | feat(gateway): add logs download button (#3588) |
| `6fc4f3386` | feat(tui): Ctrl-S downloads logs from the Logs tab (#3658) |
| `e31f34c0d` | feat(web): support externally-provided tools in Responses API (#3122) |
| `2a95799ce` | feat: wecom channel (#2394) |
| `f1a8664da` | refactor: extract embeddings into `ironclaw_embeddings` crate (#3739) |
| `a91426c50` | chore(deps): update wasmtime to clear cargo-deny advisory (#4028) |
| `4fea8b354` | chore(deps): bump deps to address security advisories (#3719) |
| `201e2164f` | fix: `markdown_to_mrkdwn` — don't convert emphasis inside generated Slack links (#3532) |
| `d47dfa5ea` | fix(web): restore NEAR AI API Key + Fetch Models in configure UI (#3742) |
| `81be41c14` / `b825a6c8d` / `030cfeb0c` | ci: `/benchmark` slash-command dispatcher + permissions + "started" comment |
| `8a12959af` | fix(canary): accurate test counts, chat-install probe, strict xfails (#3682) |
| `b921b4299` | docs(api): document the Responses API end-to-end (#3709) |
| `f0abd23b9` | chore: v0.29.0 release (#4077) |

---

## Changes NOT Applicable to LunarWing (Skip)

| Commit | Description | Why Skip |
|--------|-------------|----------|
| `2a95799ce` | WeCom channel (#2394) | WeCom (WeChat for Work) is a proprietary channel. LunarWing's manifesto rejects proprietary channels (Slack/Discord/Telegram/WeChat). Do not port the channel. |
| `2a95799ce` (partial) | `extensions/manager.rs` setup-secret validation helpers (`validate_setup_secret_value`, placeholder/size/control-char checks) + persisted runtime-config overrides | These ~340 lines are mostly channel-agnostic and *could* harden LunarWing's own WASM-channel setup secret handling. But they landed entangled with WeCom and there is no current LunarWing pain point. Low-priority cherry-pick at best; not recommended now. |
| `6fc4f3386` | TUI Ctrl-S log download (#3658) | LunarWing has no TUI. There is no `lunarwing_tui` crate and no Ratatui/Crossterm front-end — users interact via the web gateway, CLI subcommands, or XMPP/WeeChat. No Logs tab exists to attach the keybinding to. |
| `201e2164f` | `markdown_to_mrkdwn` emphasis fix (#3532) | Slack-specific (`mrkdwn` angle-link formatting). LunarWing ships no Slack channel and XMPP formatting does not share this code path. |
| `e31f34c0d` | Externally-provided tools in the Responses API (#3122) | LunarWing's `src/channels/web/responses_api.rs` is a **stub** ("requires DB features not present in this build; routes are not registered"). There is no `/v1/responses` surface, no `ExternalToolCatalog`, and no `AppEvent::ExternalToolCall`. Porting the feature would first require building the entire Responses API — out of scope and of questionable value given "IronClaw compatibility is not a goal." **Defer.** |
| `d47dfa5ea` | Restore NEAR AI API Key + Fetch Models in configure UI (#3742) | This was a *regression* introduced by IronClaw's provider-facade refactor #3416 (shipped in 0.28.2). LunarWing deliberately did **not** adopt that facade refactor (see 0.28.2 analysis P1 notes), so the regression almost certainly never existed here. NEAR AI is LunarWing's default backend and is fully wired (`src/llm/nearai_chat.rs`, wizard, CLI `models`). *Verify the configure UI still lists the NEAR AI key + Fetch Models; if so, no action.* |
| `81be41c14`,`b825a6c8d`,`030cfeb0c`,`8a12959af` | `/benchmark` CI dispatcher, canary accuracy | IronClaw CI/release infrastructure. LunarWing has its own CI and release cadence (`docs/proposals/RELEASE_CADENCE.md`). Not shared. |
| `b921b4299` | Document the Responses API end-to-end (#3709) | Docs for a surface LunarWing only stubs. N/A until/unless the Responses API is built. |

---

## Already Present in LunarWing

These exist today and are the reason several 0.29.0 items are either easy to port or unnecessary:

- **Structured (non-CodeAct) executor path** — `crates/lunarwing_engine/src/executor/structured.rs`. This is the fallback target for the CodeAct disable flag (P1-A); LunarWing does not have to invent a second execution mode, only a runtime selector and prompt. **Update (2026-05-28):** lease accounting in all three executors (structured, scripting, orchestrator) was hardened so post-execution auth gates no longer refund lease use — `max_uses` budgets are now reliably enforced even when DISABLE_CODEACT routes execution through this path. See [0.28.2 P1-F + P1-G implementation note](./ironclaw-0.28.2-port-analysis.md#implementation-note-2026-05-28-p1-f--p1-g-pattern-fix-expansion).
- **NEAR AI as default backend** — `src/llm/nearai_chat.rs` (dual auth: `NEARAI_API_KEY` or session token), wizard entry, CLI `models`. This is why the NEAR-AI configure-UI fix (#3742) is almost certainly a no-op here.
- **Web log streaming + buffer** — `LogBroadcaster` (`src/channels/web/log_layer.rs`) exposed via `state.log_broadcaster`. The SSE handler `logs_events_handler` (`src/channels/web/handlers/static_files.rs:115`) already calls `broadcaster.recent_entries()` to replay history, and `/api/logs/level` (`server.rs:454`) controls level at runtime. The download endpoint (P2-A) is a thin addition on top of this.
- **Four embedding providers in-tree** — `src/workspace/embeddings.rs` (`OpenAiEmbeddings` with `with_base_url`, `NearAiEmbeddings`, `OllamaEmbeddings`, plus `openai_compatible`), config in `src/config/embeddings.rs`, cache in `src/workspace/embedding_cache.rs`.
- **Outbound network policy** — `NetworkPolicyDecider` trait + `ALLOW_PRIVATE_IPS` (`src/NETWORK_SECURITY.md`). Critical context for the embeddings SSRF item (P2-B): LunarWing intentionally talks to private IPs (default TensorZero endpoint `http://192.168.1.157:3002`, local Ollama).

---

## P0 — Security (Port / Audit First)

### P0-A: Targeted Dependency Advisory Bumps
**Commits:** `4fea8b354` (#3719), `a91426c50` (#4028) | **Complexity:** S–M | **Dependencies:** None | **Status (2026-05-28):** No actionable simple bumps in the current lockfile — see [Audit Findings](#audit-findings-2026-05-28).

**Why:** 0.29.0 cleared several RUSTSEC advisories. LunarWing's lockfile predates these and is
likely exposed to the same ones (it carries the legacy rustls 0.21 chain plus 0.22/0.23, and old
transitive crates). These are dependency-only changes with no fork-divergence risk.

Specific bumps from 0.29.0 and their relevance:

| Advisory / crate | IronClaw 0.29.0 | LunarWing today | Action |
|------------------|-----------------|-----------------|--------|
| **rustls-webpki** RUSTSEC-2026-0104 (reachable panic in CRL parsing) | `0.103.12 → 0.103.13` | check lockfile | Bump to ≥ 0.103.13. |
| **fast-uri** (transitive via ajv-formats) | forced `≥ 3.1.1` (resolved 3.1.2) | check lockfile | Force ≥ 3.1.1 if present. |
| **aws-sdk-bedrockruntime** legacy rustls 0.21 chain | `default-features = false` + minimal feature re-enable | LunarWing has no Bedrock backend | Likely N/A — confirm Bedrock isn't pulled transitively. |
| **tokio-tar** RUSTSEC-2025-0111 | tracked, *not yet fixed* upstream | check lockfile | If present, evaluate `astral-tokio-tar` or pinning; same open problem IronClaw has. |

**What to do:**
1. Run `cargo deny check advisories` in `ic/` to enumerate LunarWing's actual current exposure (LunarWing ships `deny.toml`). This is the authoritative list — do not assume IronClaw's set maps 1:1.
2. Apply the matching bumps (rustls-webpki, fast-uri at minimum), then `cargo update -p <crate> --precise <ver>` as needed.
3. Re-run `cargo deny check` and the full test matrix.

**LunarWing files:** `ic/Cargo.toml`, `ic/Cargo.lock`, `ic/deny.toml`.

**IronClaw reference:** `git show 4fea8b354` and `git show a91426c50` (Cargo.toml / Cargo.lock / deny.toml hunks).

---

### P0-B: Wasmtime 28 → 44 (Large, Separate Workstream)
**Commit:** `a91426c50` (the 0.29.0 piece: `43 → 44`) | **Complexity:** L | **Dependencies:** None — but big | **Status (2026-05-28):** 12 current advisories confirmed (11 on `wasmtime`, 1 on `wasmtime-wasi`) — see [Audit Findings](#audit-findings-2026-05-28).

**Why this is called out:** The 0.29.0 change itself is small (wasmtime `43.0.2 → 44.0.2`,
`wasmparser 0.245.1 → 0.246.2`). But auditing it surfaced a much larger pre-existing gap:

| Crate | IronClaw 0.29.0 | LunarWing 1.0.7 |
|-------|-----------------|-----------------|
| `wasmtime` / `wasmtime-wasi` | `44.0.2` | **`28.0.1`** |
| `wasmparser` | `0.246.2` | `0.220` |

Wasmtime is LunarWing's **sandbox boundary** for all third-party WASM tools and channels (XMPP,
WeeChat, DarkIRC, Gotify, etc.). ~16 major releases separate 28 from 44 — that span includes
multiple security fixes and CVE classes (component-model and Winch/Cranelift codegen hardening,
pooling-allocator and memory-bounds fixes). For a project whose threat model leans on the WASM
sandbox isolating untrusted extensions, this is the single most security-significant divergence
this audit found.

**Why it's a separate workstream (not folded into P0-A):** wasmtime is API-breaking across majors.
A 28 → 44 jump will require code changes in LunarWing's host runtime (`Engine`/`Store`/`Linker`
construction, `component::*` bindings, WASI context builder, resource limiter wiring) and a fresh
`scripts/build-wasm-extensions.sh` validation pass against `wasm32-wasip1`/`wasm32-wasip2`. It
cannot be a lockfile-only bump.

**Recommendation:** Do NOT bundle this with P0-A. Open a dedicated tracking task ("wasmtime
sandbox upgrade 28 → 44"), staged in increments (e.g., 28 → 34 → 40 → 44) with the WASM
channel/tool conformance suite run at each step. Until then, P0-A still clears the non-wasmtime
advisories independently.

**LunarWing files (upgrade scope, for the future task):** `ic/Cargo.toml`, WASM host runtime under
`ic/src/tools/wasm/` and the channel WASM host, `ic/wit/*.wit`, `ic/scripts/build-wasm-extensions.sh`.

---

## Audit Findings (2026-05-28)

`cargo deny check advisories` against LunarWing 1.0.7 surfaces **19 current advisories**. The doc's P0-A "S–M, bump 2–3 crates" scope turns out to have **zero straightforwardly-bumpable crates**: every real exposure is gated on a structural upstream change or is the P0-B wasmtime work.

### The doc's named P0-A items

| Named advisory / crate | Status in LunarWing |
|------------------------|---------------------|
| `rustls-webpki` RUSTSEC-2026-0104 | **Present** as one of three advisories on `rustls-webpki 0.102.8` (also RUSTSEC-2026-0098, RUSTSEC-2026-0099). Pinned via `libsql 0.6.0 → hyper-rustls 0.25 → rustls 0.22 → rustls-webpki 0.102.8` — same chain as the already-ignored RUSTSEC-2026-0049. Cannot be bumped without upgrading libsql to 0.9. |
| `fast-uri` (≥ 3.1.1) | **Not present in the lockfile.** No action needed. |
| `tokio-tar` RUSTSEC-2025-0111 | **Already ignored** in `deny.toml` ("sandbox containers only"). No action needed. |

### All 19 current advisories by package

| Package | Count | RUSTSEC IDs | Reverse-dep chain | Blocker |
|---------|-------|-------------|--------------------|---------|
| `wasmtime` 28.0.1 | 11 | 2026-0085, -0086, -0087, -0088, -0089, -0091, -0092, -0093, -0094, -0095, -0096 | Direct dep of `lunarwing` | **P0-B work** — need ≥ 36.0.7 (LTS line) or ≥ 44.0.2. API-breaking; not a lockfile-only bump. |
| `wasmtime-wasi` 28.0.1 | 1 | 2026-0149 (path_open(TRUNCATE) bypasses `FilePerms::WRITE`) | Direct dep | **P0-B work** (same upgrade). |
| `rustls-webpki` 0.102.8 | 3 | 2026-0098, -0099, -0104 | `libsql 0.6.0 → hyper-rustls 0.25 → rustls 0.22 → rustls-webpki 0.102.8` | Stuck on **libsql 0.6 → 0.9** (same chain as the already-ignored RUSTSEC-2026-0049). |
| `hickory-proto` 0.25.2 | 2 | 2026-0118 (NSEC3 DoS), 2026-0119 (CPU exhaustion) | `tokio-xmpp 5.0.0 → hickory-resolver 0.25 → hickory-proto 0.25` | `tokio-xmpp 5.0.0` is the latest crates.io release and locks `hickory-resolver ^0.25`. `cargo update --precise 0.26.1` was rejected by the resolver. Waiting on **upstream tokio-xmpp release**. |
| `failure` 0.1.8 | 2 | 2019-0036 (type-confusion unsound), 2020-0036 (officially unmaintained) | `vendor/libsignal-protocol` (in-tree vendored crate) | `failure` is deprecated upstream — no newer version exists. Real fix = **port `vendor/libsignal-protocol` off `failure` to `thiserror`/`anyhow`**. |

### Bottom line

- **P0-A scope is empty.** No simple bumps to apply. The original "bump 2–3 crates" recommendation does not match the current lockfile.
- **P0-B (wasmtime 28 → 36 LTS or → 44) is the only path to clear the largest single exposure** — 12 of 19 advisories live in the wasmtime stack.
- **Three additional structural blockers** — libsql 0.6 → 0.9 (3 webpki advisories), upstream tokio-xmpp release (2 hickory advisories), vendored libsignal off `failure` (2 advisories) — each is its own workstream.
- **No `deny.toml` or `Cargo.lock` changes were made** in this audit; `cargo deny check advisories` still fails as recorded above. Decisions on whether to add new entries to the `deny.toml` ignore list (e.g., to mirror the existing RUSTSEC-2026-0049 pattern for the new webpki advisories) are deferred.

**Reproducibility:** `cd ic && cargo deny check advisories` (cargo-deny `0.19.8` was installed during the audit; `deny.toml` carries the project's existing ignore list of 7 pre-existing tracked advisories).

---

## P1 — Safety / Architecture

### P1-A: `LUNARWING_DISABLE_CODEACT` — CodeAct Kill-Switch
**Commit:** `cab708ed3` (#3665) | **Complexity:** M | **Dependencies:** None

**Why:** IronClaw added `IRONCLAW_DISABLE_CODEACT` (matches `"true"`/`"1"`) to disable the v2 CodeAct
path — the Python-REPL execution mode — and fall back to provider-native **structured tool calls**.
For a privacy-first, self-hosted agent this is a strong-fit safety control: it lets an operator run
the agent without ever granting it an interpreter, trading some capability for a much smaller
execution-surface. LunarWing has full CodeAct (Monty interpreter, `executor/scripting.rs`) but
**no off-switch** today — the only engine env toggles are `ORCHESTRATOR_SELF_MODIFY`
(`executor/loop_engine.rs:247`) and `ENGINE_V2_TRACE` (`executor/trace.rs`).

**How IronClaw does it:** a `codeact_disabled()` helper in `crates/ironclaw_engine/src/executor/prompt.rs`
gates two things:
1. **Prompt builder** — swaps `CODEACT_PREAMBLE/POSTAMBLE` for `STRUCTURED_TOOL_PREAMBLE/POSTAMBLE`
   (instruct the model to emit only provider `tool_calls`, no Python).
2. **LLM adapter** — in `src/bridge/llm_adapter.rs::complete()`, when disabled it emits **all** actions
   to the provider tool list (instead of only the `emits_full_schema_tool()`-filtered subset), so
   compact-info actions remain callable as structured tools.

**What to change (LunarWing):**
1. `crates/lunarwing_engine/src/executor/prompt.rs` — today `build_codeact_system_prompt_inner` (line
   132) *unconditionally* prepends `CODEACT_PREAMBLE` (line 137) and appends `CODEACT_POSTAMBLE`
   (line 166). Add a `codeact_disabled()` env check (`LUNARWING_DISABLE_CODEACT`) and a
   `STRUCTURED_TOOL_PREAMBLE/POSTAMBLE` pair (new `prompts/*.md` via `include_str!`, per code style),
   branching on the flag.
2. `src/bridge/llm_adapter.rs` — in `complete()` (line 41), when disabled, build the provider
   `ToolDefinition` list from *all* actions rather than the filtered set.
3. **Executor selection** — confirm the loop can run purely on the structured path
   (`executor/structured.rs`) when CodeAct is off, i.e. that structured `tool_calls` are dispatched
   as actions without requiring the scripting executor. This is the main verification risk; LunarWing's
   structured executor already exists, but the runtime selector between scripting/structured must
   honor the flag.

**Default behavior:** unset → CodeAct stays enabled (no behavior change). This makes it a safe,
opt-in addition.

**IronClaw reference:** `git show cab708ed3` — `codeact_disabled()` in `executor/prompt.rs` and the
`complete()` branch in `src/bridge/llm_adapter.rs`.

---

## P2 — Operability / Evaluate

### P2-A: Logs Download Endpoint + Gateway Button
**Commit:** `c93c45524` (#3588) | **Complexity:** S | **Dependencies:** None

**Why:** LunarWing's gateway already streams logs over SSE and replays a recent-history buffer, but
there is no one-click export. For self-hosted operators (systemd/OpenRC), a "download logs" button is
a clean operability win — grab the recent buffer without scraping journald.

**What to change:**
1. `src/channels/web/server.rs` — add a route near the existing log routes (`~:453`), e.g.
   `.route("/api/logs/download", get(logs_download_handler))`.
2. `src/channels/web/handlers/static_files.rs` — add `logs_download_handler` that pulls
   `state.log_broadcaster`'s `recent_entries()`, serializes them (plain text or JSON lines), and
   returns with `Content-Disposition: attachment; filename="lunarwing-logs-<ts>.txt"`.
3. Static UI — add a download button next to the existing Logs view controls.

**Caveat to document in the UI/handler:** `recent_entries()` is an in-memory ring buffer (≈256
events), **not** the full on-disk log. Label the button accordingly (e.g. "Download recent logs") so
operators don't assume it's a complete export; full history still comes from journald / the log file.

**IronClaw reference:** `git show c93c45524` (gateway handler + static button).

---

### P2-B: Embeddings SSRF Hardening (Adapt — Do NOT Copy Verbatim)
**Commit:** `f1a8664da` (#3739, the `url_check.rs` portion) | **Complexity:** M | **Dependencies:** None

**Why:** The 0.29.0 embeddings extraction added a `url_check.rs` baseline that validates provider
base URLs before any request (rejects cloud-metadata IPs, non-`http(s)` schemes, and literal-IP
hosts) plus SSRF checks in `factory.rs::create_provider`. The *intent* — don't let a
mis/maliciously-configured `EMBEDDING_BASE_URL` become an SSRF primitive — is valuable for a
privacy-first agent that lets users point embeddings at arbitrary endpoints.

**Critical fork caveat:** IronClaw's check **rejects literal-IP and private hosts outright**. Ported
as-is it would **break LunarWing's normal configuration**:
- Default TensorZero proxy endpoint is `http://192.168.1.157:3002` (a private IP).
- Local Ollama embeddings default to `http://localhost:11434` / `127.0.0.1`.

So the port must **integrate with LunarWing's existing `NetworkPolicyDecider` / `ALLOW_PRIVATE_IPS`**
rather than hardcode a private-IP denylist. Concretely: validate scheme + reject cloud-metadata
ranges (`169.254.169.254`, etc.) always, but defer the private/loopback decision to the existing
network policy (which already says "private IPs allowed in these deployments").

**What to do first (verify):** Determine whether outbound embedding HTTP already flows through
`NetworkPolicyDecider`. If it does, LunarWing may already have most of this coverage and the gap is
just the metadata-IP / scheme checks. If embeddings bypass the policy, that bypass is itself the
finding to fix.

**LunarWing files:** `src/workspace/embeddings.rs` (the three `EmbeddingProvider` impls construct
URLs like `{base_url}/v1/embeddings`), `src/config/embeddings.rs`, and the network policy in
`src/NETWORK_SECURITY.md` / its decider implementation.

**IronClaw reference:** `git show ironclaw-v0.29.0:crates/ironclaw_embeddings/src/url_check.rs` and
`.../src/factory.rs`.

---

### P2-C: Extract Embeddings into a `lunarwing_embeddings` Crate
**Commit:** `f1a8664da` (#3739, the crate-extraction portion) | **Complexity:** M–L | **Dependencies:** P2-B (do them together if pursued)

**Why:** IronClaw moved `src/workspace/embeddings.rs` (≈794 lines) into a dedicated
`crates/ironclaw_embeddings` crate (sealed provider impls behind a `create_provider(&config, deps)`
factory, with `EmbeddingProvider`/`EmbeddingsCache`/`EmbeddingsConfig` as the public surface). This
matches LunarWing's existing crate-split pattern (`lunarwing_common`, `lunarwing_engine`,
`lunarwing_safety`, `lunarwing_skills`) and would improve incremental compile times and enforce the
provider boundary.

**Assessment:** This is **optional architectural cleanup**, not a fix. LunarWing's embeddings module
(643 lines) works fine in-tree. The real value (SSRF baseline) is captured by P2-B without the move.
Recommend only if/when there's appetite for the crate refactor; if pursued, fold P2-B's URL
validation into the new crate's `url_check`-equivalent. Lower priority than P0/P1.

**LunarWing files (if pursued):** new `crates/lunarwing_embeddings/`, plus call sites in `src/app.rs`,
`src/config/mod.rs`, `src/cli/` that currently reach into `workspace::embeddings`.

**IronClaw reference:** `git show f1a8664da --stat` for the full module map.

---

### P2-D: WIT `websocket-send-text` Capability — Evaluate for WeeChat-WSS
**Commit:** part of the 0.28.2→0.29.0 web work | **Complexity:** M | **Dependencies:** wasmtime currency (P0-B context)

**Why:** 0.29.0 bumped `wit/channel.wit` from `near:agent@0.3.0` to `0.3.1`, adding a host-provided
capability:

```wit
websocket-send-text: func(payload: string) -> result<_, string>;
```

It lets a WASM channel send raw WebSocket text frames through the host-managed runtime (transport-
agnostic; the channel builds the payload). LunarWing is still on `near:agent@0.3.0` and lacks it.

**Why it might matter here:** LunarWing ships a **WeeChat-over-WSS** channel (`ironclaw_weechat_wss/`,
sources under `channels-src/`). If that channel currently manages its own outbound WebSocket from
inside the sandbox, a host-managed `websocket-send-text` could simplify it and tighten the egress
boundary (host owns the socket; WASM only hands over text).

**What to do first (investigate):** Read the WeeChat-WSS channel to see how it currently sends frames.
If it already relies on the host `http-request` capability or manages its own socket happily, this is
a non-urgent ergonomics change. Only adopt the 0.3.1 interface bump if a LunarWing channel actually
needs host-managed WS sends — a WIT version bump touches the host runtime and every WASM
channel/tool's bindings, so it shouldn't be done speculatively (and interacts with the wasmtime
upgrade in P0-B).

**LunarWing files:** `ic/wit/channel.wit`, the WASM channel host, `channels-src/` (WeeChat-WSS).

**IronClaw reference:** `git diff ironclaw-v0.28.2..ironclaw-v0.29.0 -- wit/channel.wit`.

---

## Recommended Implementation Order

```
1. P0-A  Targeted advisory bumps                                                [S-M]  AUDITED 2026-05-28 — no actionable bumps (see Audit Findings)
2. P1-A  LUNARWING_DISABLE_CODEACT kill-switch                                  [M]    safety; best philosophy fit
3. P2-A  Logs download endpoint + button                                       [S]    clean operability win
4. P2-B  Embeddings SSRF hardening (via NetworkPolicyDecider)                   [M]    real hardening; verify policy coverage first
--- larger / optional, schedule separately ---
5. P0-B  Wasmtime 28 → 44 sandbox upgrade                                       [L]    biggest security gap (12/19 advisories — see Audit Findings); own staged workstream
6. P2-C  lunarwing_embeddings crate extraction                                 [M-L]  optional cleanup; bundle with P2-B if done
7. P2-D  WIT websocket-send-text                                               [M]    evaluate only if WeeChat-WSS needs it
```

P0-A and P2-A can each ship as a standalone PR. P1-A is the headline safety feature and warrants its
own PR plus tests for both flag states. P0-B is large enough to be its own multi-PR effort and should
not block the others.

## Verification

After each ported item, from `ic/`:

- `cargo fmt && cargo clippy --all --benches --tests --examples --all-features` (zero warnings)
- `cargo test`
- `cargo check --no-default-features --features libsql` and `--features postgres` (dual-backend)
- `scripts/pre-commit-safety.sh`

Item-specific:

- **P0-A / P0-B:** `cargo deny check advisories` before and after; confirm no new advisories and the
  targeted RUSTSEC IDs are cleared. For P0-B also run `scripts/build-wasm-extensions.sh` and the WASM
  channel/tool conformance path against `wasm32-wasip1`/`wasm32-wasip2`.
- **P1-A:** run a session with `LUNARWING_DISABLE_CODEACT=1` and confirm (a) the system prompt no
  longer contains the CodeAct preamble, (b) the model is offered all actions as structured tools, and
  (c) tool calls dispatch and complete via the structured executor with no Python execution. Then run
  unset and confirm CodeAct behavior is unchanged.
- **P2-A:** hit `/api/logs/download` and confirm it returns the recent buffer with an attachment
  filename; click the UI button end-to-end in the gateway.
- **P2-B:** confirm embeddings against the default TensorZero endpoint (`192.168.1.157`) and local
  Ollama still succeed (must not be blocked), while a cloud-metadata URL (`169.254.169.254`) and a
  non-`http(s)` scheme are rejected.
