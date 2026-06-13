# Release Notes for LunarWing v1.1.2 - Codename Kunai

**Release Date:** TBD

## Overview

Per the release cadence (`docs/ops/RELEASE_CADENCE.md`), even-numbered releases are feature releases. v1.1.2 carries two headline feature efforts alongside a substantial round of hardening, cleanup, and fixes built on the v1.1.1 foundation:

1. **XMPP inbound file-transfer hardening** — XEP-0030/0115 capability advertisement (so capability-checking clients will actually offer to send files), XEP-0454 `aesgcm://` encrypted-media download + AES-256-GCM decryption, bounded-concurrency downloads, and streamed size enforcement.
2. **Infrastructure self-healing + a chaos engineering test suite** — the `lunarwing-self-heal.sh` watchdog gains cross-tick exponential backoff with jitter, a grace period / flapping guard, post-restart health verification, and state pruning; a new four-layer bash test suite exercises the entire health-check → self-heal pipeline. This is the "healthcheck/self-healing enhancements" item that was *in progress* at the last draft — **it has now landed.** (It is groundwork for the larger self-healing epic targeted at v1.2.0.)

Supporting changes round out the release: a **more robust fix for the empty-response "lapse" bug** (now recovering tool calls that GLM/Qwen-style models emit in the `<function=NAME>…</function>` XML dialect instead of misreporting them as empty responses), a **clippy zero-warning gate cleanup** across the workspace and vendored libsignal, **removal of the remaining Google tool extensions** (Gmail, Calendar, Drive, Docs, Sheets, Slides) as part of LunarWing's proprietary-extension cleanup, a **WeeChat duplicate-reply fix**, **UTF-8-safe DarkIRC message splitting**, a native **Raspberry Pi build script**, and release-process tooling/documentation plus the usual housekeeping.

---

## Changes

### Reasoning Tool-Call Recovery — "Lapse" Bug, Better Implementation (continued from v1.1.0)

v1.1.0 first addressed the "momentary lapse" where reasoning models returned content that `clean_response()` stripped to empty, producing a silent "I'm not sure how to respond to that." fallback. v1.1.2 fixes a **recurrence with a different root cause**: some GLM/Qwen-style models emit a *well-formed tool call* as plain text in the `<function=NAME><parameter=KEY>value</parameter></function>` XML dialect, with the structured `tool_calls` field left empty. Those calls were being stripped to empty and misreported as empty responses, re-triggering the fallback instead of executing the tool. This was the deferred "better implementation of the memory lapse bug fix" item from the v1.1.1 notes.

Implemented in `ic/src/llm/reasoning.rs`:

- **`recover_function_xml_calls()`** — New recovery function that scans raw content for `<function=NAME>` blocks (with or without the surrounding `<tool_call>` wrapper), extracts each `<parameter=KEY>VALUE</parameter>` into the arguments object, and returns a `ToolCall` only when `NAME` matches a known tool. Parameter values are JSON-parsed when valid (so `true` and numbers keep their type) and otherwise kept as a trimmed string (so a multi-word search query stays a string). A `seed_offset` continues the caller's ID numbering so recovered IDs stay unique across recovery formats.
- **Wired into `recover_tool_calls_from_content()`** — Joins the existing recognized dialects: JSON inside `<tool_call>`/`<function_call>` (incl. pipe-delimited), a bare tool name inside `<tool_call>`, and the `[Called tool \`name\` with arguments: {...}]` bracket form.
- **`strip_function_xml_tags()`** — New `clean_response()` step (6c) that strips any leftover `<function=…>` blocks so unrecovered ones never leak into user-facing text. An unclosed `<function=` drops the trailing partial XML, mirroring the strict handling of unclosed thinking tags.
- **8 new tests** — `<function=…>` with parameters (type coercion), without parameters, unwrapped (no `<tool_call>`), unknown-tool-ignored, string-value-not-coerced, unique IDs, `clean_response` strips tags, plus an async `respond_with_tools()` regression (`test_respond_with_tools_recovers_function_xml_dialect`) driven by `StubLlm` that asserts the dialect is recovered and executed rather than returning the fallback. Test payloads mirror the exact content captured in production logs.
- **Docs** — `ic/src/llm/CLAUDE.md` updated to document the tool-call recovery path and the dialects it recognizes; `docs/bugs/BUG-LAPSE.md` records the symptoms, root cause, and fix.

### XMPP Inbound File Transfer Hardening (Capability Advertisement, Encrypted Media, Download Safety)

v1.1.1 shipped the first inbound XMPP file pipeline (OOB extraction + download) but it had **not** been validated end-to-end and lacked several robustness and protocol pieces. v1.1.2 delivers a substantial hardening pass to the XMPP client (`ic/src/channels/xmpp/mod.rs`, ~620 lines added) across four phases. (Note: a chunk of this work was originally scheduled for v1.1.5; the core landed early — remaining polish stays targeted at v1.1.5 in `docs/ops/ROADMAP_2026.MD`.)

**Phase 1 — Capability advertisement (XEP-0030 / XEP-0115).** The client now answers incoming IQ stanzas rather than dropping them — required by RFC 6120 §8.2.3, and the reason capability-checking clients (Conversations, Gajim, Dino) will offer to send files at all. Without this, clients time out and treat the agent as unable to receive files (some then fall back to Jingle/XEP-0234, which the agent does not implement).

- `lunarwing_disco_info()` — single source of truth: identity `client/bot "LunarWing"`, features `http://jabber.org/protocol/disco#info`, `jabber:x:oob`, `urn:xmpp:ping`.
- `build_iq_reply()` — `disco#info` get → `<iq type='result'>`; `urn:xmpp:ping` get → empty result; any other get/set → `<error type='cancel'><service-unavailable/></error>` (no silent drops). `iq_service_unavailable()` builds the error.
- Initial presence carries a XEP-0115 `<c/>` caps element whose `ver` is computed (`caps::compute_disco` + `caps::hash_caps`) from the same `disco#info`, so the advertised hash always matches the response. Caps node: `https://lunarwing.chat`.

**Phase 2 — Download hardening.**

- `extract_inbound_attachments(payloads, body)` replaces the previous single-purpose extractor and orchestrates collection + download.
- `collect_oob_urls()` parses `<x xmlns='jabber:x:oob'>` elements, capped at `MAX_OOB_ATTACHMENTS` (10) per stanza.
- Downloads run with **bounded concurrency** (`MAX_CONCURRENT_OOB_DOWNLOADS` = 4, via `buffered`) so one slow URL can't serialize the batch and stall the single client event loop; results stay in stanza order, and per-URL failures are logged and skipped.
- `read_capped_body()` enforces the size cap **while streaming** over `response.bytes_stream()`, aborting the moment the body exceeds `OOB_MAX_FILE_SIZE` (20 MB) so a missing or understated `Content-Length` cannot cause unbounded buffering. A `Content-Length` above the cap is also rejected up front.

**Phase 3 — Encrypted media (`aesgcm://`, XEP-0454).**

- `collect_aesgcm_urls()` scans the **decrypted** OMEMO body for `aesgcm://` URLs (deduped, same per-stanza cap), covering clients that omit the cleartext OOB element to avoid leaking the URL to the server. Plain `https://` links that appear only in a body are intentionally **not** auto-downloaded — only the explicit `aesgcm://` scheme is.
- `download_aesgcm_file()` / `parse_aesgcm_url()` / `decrypt_aesgcm()` — fetch the ciphertext via the https form (same streaming cap), split the `IV‖key` from the URL `#fragment`, and AES-256-GCM-decrypt locally. Both the standard 12-byte IV and the legacy 16-byte IV are supported. MIME is inferred from the URL filename (`mime_guess`) since the server stores ciphertext; the original `aesgcm://` URL is kept as `source_url` so body deduplication still matches.

**Phase 4 — Filename robustness.**

- `filename_from_url()` uses the last URL path segment with any query/fragment stripped, and keeps extensionless/opaque names (e.g. an XEP-0363 UUID segment). This prevents distinct files from colliding on the downstream `oob-{filename}` storage key — previously such names were dropped.

**Status:** Implemented and unit-tested (`cargo test channels::xmpp`; ~11 new tests across IQ reply, OOB collection, capped-body streaming, `aesgcm://` parse/decrypt round-trips, and filename handling), and the standalone `xmpp-bridge` builds in release. Live end-to-end validation against a real server (Conversations/Gajim → agent over a working XEP-0363 host) is still pending — see *Known Issues*.

| Limit | Value | Enforced at |
|-------|-------|-------------|
| OOB/`aesgcm` URLs processed per stanza | 10 (`MAX_OOB_ATTACHMENTS`) | XmppChannel |
| Concurrent inbound downloads | 4 (`MAX_CONCURRENT_OOB_DOWNLOADS`) | XmppChannel |
| Per-file download size (enforced while streaming) | 20 MB (`OOB_MAX_FILE_SIZE`) | XmppChannel |
| Download timeout | 30 seconds | XmppChannel (reqwest client) |
| Per-attachment store | 20 MB | WASM host (`store_attachment_data`) |
| Total attachment store per callback | 50 MB | WASM host |

### Infrastructure Self-Healing — Resilience Hardening

The previously *in-progress* "healthcheck and self-healing enhancements" have landed. `ic-infrastructure-health-check/lunarwing-self-heal.sh` was substantially rewritten (the "merged best-of-both" of two parallel implementations — see `docs/ops/GOALS_1.1.2_INFRA_HEALTH_CHECK.md`) and is the subject of the new chaos suite below. The pipeline is unchanged in shape — `cron-wrapper.sh` runs `infrastructure-health-check.sh` (writes a JSON report under `$LUNARWING_BASE_DIR/workspace/reports/health/`) then `lunarwing-self-heal.sh` (reads the latest report and remediates) — but the self-healer is now far more robust:

- **Cross-tick exponential backoff with jitter** (`compute_backoff`, `next_attempt_at`). Retry spacing is *deferred to the next cron tick* rather than slept inside the run, so self-heal never blocks on a long backoff. A short fixed in-run settle (5 s) is kept separate from the jittered cross-tick gate. `linear` / `exponential` strategies are selectable, with an overflow guard and `/dev/urandom` jitter for delays beyond `$RANDOM`'s 15-bit range.
- **Grace period + flapping guard.** A service must be observed unhealthy for `--grace-checks` consecutive ticks before the first restart (absorbs transient blips). A `restart_history` window (`FLAP_MAX_RESTARTS` / `FLAP_WINDOW_SECS`) escalates instead of looping when a service keeps dying after grace; the history array is capped (20 entries) so chronic flappers don't grow `state.json` unboundedly.
- **Post-restart health verification.** After a restart, self-heal re-runs the component's own `health-*.sh` probe and checks `.status`, falling back to `systemctl is-active` only when the probe is inconclusive, missing, or non-executable — piggybacking on existing health-check infrastructure instead of fragile hardcoded HTTP probes.
- **State recovery & pruning.** Services the latest report calls healthy are cleared (report-as-truth `RECOVERED`) without round-tripping a separate check. Stale state entries are TTL-pruned (`--prune-ttl`), while escalated or still-unhealthy entries are preserved.
- **Multi-tenant remediation.** Each unhealthy unit is mapped back to its owning tenant via the port registry and restarted on that user's bus (`sudo -u <user> systemctl --user restart …`) or via `rc-service` on OpenRC; per-tenant discovery is handled by `health-systemd.sh` / `health-openrc.sh`. Host-wide install covers all current and future tenants automatically.
- **Escalation & locking.** After max retries (or on flap detection) the service is marked escalated, an escalation JSON report is written, and `send-notification.sh` fires a Gotify alert. A `flock` guard prevents concurrent self-heal instances.
- **New CLI flags:** `--backoff-base` / `--backoff-max` / `--backoff-strategy`, `--grace-checks`, `--prune-ttl`, `--verify-health`, `--dry-run`, `--report`, `--help`.

> Scope note: the script and chaos suite are internally versioned toward the larger v1.2.0 self-healing epic, but the code ships in v1.1.2. Self-healing remains a **host-level, manually installed and scheduled** facility — it is not wired into tenant provisioning. See `docs/architecture/SELF_HEAL_DEPLOYMENT_WIRING.md` and *Known Issues*.

### Chaos Engineering Test Suite (Self-Healing)

A new four-layer bash test suite under `ic-infrastructure-health-check/tests/` exercises the self-heal pipeline against synthetic health reports and a mock init system, with a documented test plan (`docs/proposals/CHAOS_ENGINEERING_TEST_PLAN.md`) whose section IDs map 1:1 to the assertions:

| File | Role |
|------|------|
| `lib.sh` | Shared harness: assertions, `mktemp -d` sandbox, synthetic report/state fixtures, a pure-function harness (`src_fn`), and a mock init system (fake `systemctl`/`rc-service`/`sudo` + component health scripts driven by `svcstate/` files). |
| `test-self-heal.sh` | Original regression suite (28 dry-run/state checks), retained as-is. |
| `test-self-heal-matrix.sh` | Phase 1 dry-run unit matrix, sections A–N (~115 assertions): report discovery, target/service mapping, init-system sub-unit remediation, per-tenant user units, grace period, backoff/retry spacing, max-retry escalation, flapping guard, post-restart verification, restart failure, state recovery/pruning, concurrency/locking, dry-run mode, and CLI argument validation. |
| `chaos-harness.sh` | Phase 2/3 end-to-end (CH1–CH13): real (non-dry) self-heal driven against the mock init system — per-component recovery, stuck-service and restart-command-failure escalation, tenant crash + multi-tenant blast-radius isolation, flapping cap, and grace-absorbed transient blips. |
| `run-all.sh` | Aggregates the three suites (`regression` → `matrix` → `chaos`) with per-suite tallies; supports subset selection and exits non-zero on any failure. |

**Safety model:** the matrix is dry-run only and never invokes real probes; the chaos harness runs self-heal *for real* but against the mock init on `PATH` (a "restart" flips a sandbox file) and pins `GOTIFY_TOKEN=''` so escalation short-circuits before any network call. The suite is safe on a dev box but should be run on a dedicated test machine, not a live multi-tenant host. The work was reviewed by Baud (`ic-infrastructure-health-check/tests/BAUD_REVIEW.md`, verdict: *ship it*) and the P1/P2 follow-ups were applied (commit `1f46f814`).

### Infrastructure Health-Check — Fixes & Cleanup

Hardening to the health-check/self-heal scripts surfaced and fixed a silent remediation failure plus removed a pile of pre-fork cruft:

- **jq precedence bug fixed (silent un-remediation).** The self-heal pass-2 init-system sub-unit filter aborted with `exit 5` ("Cannot index string with 'metrics'") because jq's `|` binds looser than `,`; the crash was masked by `2>/dev/null || true`, so **every systemd/OpenRC/launchd sub-unit failure was silently left un-remediated**. Fixed by fully parenthesizing each alternative and regression-guarded by `tests/test-self-heal.sh` (commit `e997ec5d`).
- **No more hardcoded `/tmp`.** `infrastructure-health-check.sh` now writes its parallel-check scratch files under a per-run `mktemp -d`, removing the multi-tenant collision risk and satisfying the repo's "never hardcode /tmp" rule.
- **Correct unit names.** `health-systemd.sh` now monitors the real units (`lunarwing.service`, `xmpp-bridge.service`, `tensorzero-gateway.service`) instead of stale `ironclaw-xmpp-bridge.*` names that reported false "critical".
- **Standard base-dir paths.** `send-notification.sh` and `health-ratelimit.sh` drop hardcoded `$HOME/.ironclaw` paths in favor of the standard `LUNARWING_BASE_DIR` fallback chain.
- **Pre-fork POC cruft removed.** Deleted stale `ic-infrastructure-health-check/icscripts/` (17 files), `icservices/` (3 files), and a duplicate top-level `ironclaw-watchdog.timer` — all unreferenced duplicates of the canonical `ic/scripts/` + `ic/systemd/` versions. The README's scheduling instructions were rewritten to a self-contained systemd-timer / cron setup (`ic-infrastructure-health-check/README.md`).
- **New regression coverage.** `ic/tests/stuck_lightweight_run_tests.rs` (3 tests) covers the lightweight stuck-run sweep query `list_stuck_lightweight_runs`, which previously had **zero** coverage in either DB backend.

### Removal of Google Tool Extensions

Following the earlier removal of the proprietary Slack, Discord, WhatsApp, and Feishu channels, v1.1.2 retires the six **Google tool extensions** that previously shipped in the registry — **Gmail, Google Calendar, Google Drive, Google Docs, Google Sheets, and Google Slides** — in keeping with the Lunarpunk direction.

Removed:

- **Tool sources** — the WASM tool crates under `ic/tools-src/{gmail,google-calendar,google-docs,google-drive,google-sheets,google-slides}/` and their entries in the `ic/Cargo.toml` workspace `exclude` list.
- **Registry manifests** — `ic/registry/tools/{gmail,google-*}.json`, so the tools no longer appear in `lunarwing registry list` or build via `scripts/build-wasm-extensions.sh`. The embedded registry catalog (generated by `build.rs`) regenerates automatically without them.
- **Bundles** — the `google` ("Google Suite") bundle in `ic/registry/_bundles.json` is deleted, and Gmail/Calendar/Drive are dropped from the `default` ("Recommended Set") bundle, now just GitHub + Telegram.
- **Advertised docs & CLI help** — the Google section of `ic/tools-src/TOOLS.md`, the bundle list in `ic/src/registry/mod.rs`, and the `registry` CLI help examples that referenced `google` / `tools/gmail`.
- **e2e scenarios** — six gmail-based pytest/Playwright scenarios that installed the real `gmail` extension to exercise OAuth and WASM-lifecycle machinery (`test_oauth_refresh`, `test_extension_oauth`, `test_oauth_url_parameters`, `test_oauth_credential_fallback`, `test_routine_oauth_credential_injection`, `test_wasm_lifecycle`), plus the now-dead `gmail` intent in `mock_llm.py`.

**Retained** — these are Google as an identity/LLM *provider* or shared *infrastructure*, not installable tool extensions, and are intentionally unaffected for the time being:

- **Security & infrastructure** — the leak detector's Google-API-key pattern, the `metadata.google.internal` SSRF block, the GCP Cloud-SQL-proxy download, and the Google Fonts CDN reference all remain.

**Verification:** `cargo check` (default and `--no-default-features --features libsql`), `cargo test --lib` (3940 passed), `cargo fmt --check`, and clippy all pass with no new warnings from the removal; every remaining e2e Python module compiles.

### WeeChat — Duplicate-Reply Fix

The WeeChat relay's long-poll path (`ironclaw_weechat_wss/weechat_relay/src/lib.rs`) never updated the per-buffer `last_seen_ids` watermarks, so they went stale during long-poll. If the adapter restarted (cursor reset) or long-poll fell back to per-buffer polling, already-emitted events were redelivered to the agent — producing **duplicate replies**. `do_longpoll()` now loads the watermarks at the start of each tick, deduplicates events against them (dropping already-seen line IDs before they reach `handle_inbound_line`), and persists the updated watermarks after processing, with debug-level logging for skipped duplicates. This closes both the adapter-restart replay and the long-poll→poll mode-fallback double-delivery.

### DarkIRC — UTF-8-Safe Message Splitting

DarkIRC message splitting could break in the middle of a multi-byte UTF-8 codepoint, risking IRC protocol violations. Both sides were made byte-aware (`darkirc_channel_for_ironclaw/`):

- **Python adapter** — naive 400-char slicing replaced with `_split_message_bytes()`, which binary-searches by UTF-8 byte length, prefers breaking at newlines/spaces, and never splits a codepoint.
- **Rust WASM channel** — `split_message()` takes a `max_bytes` parameter and compares `as_bytes().len()` instead of character count, with CRLF/CR normalization and cleaned-up word-break logic. The shared limit `MAX_IRC_MESSAGE_BYTES` (400, conservative under IRC's 512-byte line limit) mirrors the adapter's `DARKIRC_MAX_MESSAGE_BYTES` (env-overridable) — keep both in sync.
- **Tests** — new `darkirc/adapter/test_split.py` (byte-boundary and break-point coverage).

### Code Quality — Clippy Zero-Warning Gate + Formatting

The full clippy gate (`cargo clippy --all --benches --tests --examples --all-features`) now passes with **zero warnings and zero errors**.

- **Gate compile repairs** (`ec487e96`) — the benches imported the stale `ironclaw::` crate name (broken since the fork rename, only surfaced under `--benches`); migrated to `lunarwing_safety` directly. Six `ToolCall` test literals in the feature-gated `bedrock` module gained the missing `reasoning: None` field added by the v1.1.2 reasoning work (only surfaced under `--tests --all-features`).
- **Workspace cleanup** (`93b8eb95`) — 44 lunarwing warnings cleared via a mechanical `clippy --fix` pass (collapsible-if → let-chains, clone-on-Copy, `contains()` → `iter().any()`, `is_multiple_of`, needless `Ok`/`?`, deref cleanups, and relocating the `history/store.rs` test module to end-of-file). Targeted `#[allow(clippy::too_many_arguments)]` was applied to 13 XMPP channel helpers and `run_external_task` (XMPP is protected runtime behavior; signature refactors deferred), plus `#[allow(dead_code)]` on two wire-protocol/slot fields.
- **Vendored libsignal** — 15 warnings cleared (removed-lint rename to `rustdoc::broken_intra_doc_links`, `default()`-on-unit-struct / `as_deref` / loop-index rewrites, and a handful of targeted allows for FFI and derive-macro cases).
- **Formatting** — an earlier `rustfmt` pass tidied four files touched by security/registry work with no behavior change: `ic/src/app.rs`, `ic/src/bridge/router.rs`, `ic/src/channels/wasm/setup.rs`, and `ic/src/extensions/registry.rs`.

Verified: full unit suite 3940 passed / 0 failed; integration binaries unchanged versus base (the 16 pre-existing, env-dependent e2e failures are confirmed identical on a clean HEAD — see *Known Issues*).

### Raspberry Pi Build Script

New `scripts/build-lunarwing.sh` builds the LunarWing (`ic`) crate **natively on aarch64**, designed for the Raspberry Pi 5 and similar low-resource ARM systems. It defaults to a release build with a low parallel-job count (to fit constrained memory), uses a dedicated `CARGO_TARGET_DIR` (default `$HOME/.cargo-target`), and by default kills stale `cargo`/`rustc` processes before starting. Flags: `--clean`, `--jobs N`, `--target DIR`, `--repo DIR`, `--profile {release|debug}`, `--wasm` (also build the Telegram WASM channel into a separate target dir), `--no-kill`, `--verbose`, `--help`; environment overrides via `CARGO_TARGET_DIR`, `LUNARWING_REPO`, and `BUILD_JOBS`.

### Release Process Tooling & Documentation

- **`docs/ops/ROADMAP_2026.MD`** — New consolidated roadmap. The forward-looking "deferred to future releases" table was extracted from the release notes into its own document so each release's notes can point to a single canonical source.
- **`docs/ops/RELEASE-COMMANDS.md`** — Reference capturing the command sequence used to cut a release (branch, tag, archive notes, GH release).
- **Documentation reorganization** — historical per-release prep checklists moved under `docs/ops/history/` (`GOALS_1.0.6`–`1.1.0`, `REBUILD-NANOCODE-WORKER.md`, `TESTING_1.0.8.md`, `STATUS_OF_REMOVAL_OF_PROPRIETARY_CHANNELS.md`) with a new `history/README.md` index; `RELEASE-v1.1.1.md` moved from the repo root to `docs/ops/`; `docs/README.md` index refreshed.
- **Goals tracking** — `GOALS_1.1.1.md` renamed to `docs/ops/GOALS_1.1.2.md` with the v1.1.2 pre-release checklist; `docs/ops/GOALS_1.1.2_INFRA_HEALTH_CHECK.md` captures the self-healing verification.

## Bug Fixes

- **Empty-response "lapse" recurrence via the `<function=…>` dialect** — GLM/Qwen-style models that emit tool calls as `<function=NAME><parameter=KEY>value</parameter></function>` text (with an empty structured `tool_calls` field) had those calls stripped to empty and misreported as empty responses, returning the "I'm not sure how to respond to that." fallback instead of executing the tool. Now recovered via `recover_function_xml_calls()`; any unrecovered blocks are stripped from user-facing text by `strip_function_xml_tags()`. See *Reasoning Tool-Call Recovery* above and `docs/bugs/BUG-LAPSE.md`.
- **XMPP clients refused to send files to the agent** — The client did not answer `disco#info`/IQ requests, so capability-checking clients timed out and treated the agent as an invalid recipient. The client now advertises identity + features (XEP-0030/0115) and answers every IQ (`build_iq_reply()`), so clients recognize the agent as a valid file recipient.
- **XMPP inbound files with extensionless/opaque names were dropped** — `filename_from_url()` now keeps opaque last-path segments (e.g. XEP-0363 UUIDs), preventing distinct files from collapsing onto the same `oob-{filename}` storage key.
- **Unbounded buffering / serialized downloads on inbound attachments** — Inbound downloads now enforce the 20 MB cap while streaming, bound the per-stanza URL count (10) and the download concurrency (4), so a crafted stanza cannot exhaust memory or stall the single client event loop.
- **Self-heal silently skipped sub-unit failures** — The pass-2 jq filter aborted (`exit 5`) on a precedence bug, masked by `2>/dev/null || true`, so init-system sub-unit failures (systemd/OpenRC/launchd) were never remediated. Fixed and regression-guarded. See *Infrastructure Health-Check — Fixes & Cleanup*.
- **WeeChat duplicate replies** — Stale per-buffer watermarks during long-poll caused already-emitted events to be redelivered after an adapter restart or a long-poll→poll fallback. Watermarks are now synced and deduplicated within each tick.
- **DarkIRC could split mid-codepoint** — Naive length-based splitting could break a multi-byte UTF-8 character, risking IRC protocol violations. Splitting is now UTF-8 byte-safe on both the Python adapter and Rust WASM channel.

## Documentation

- `docs/architecture/XMPP_FILE_TRANSFERS.md` — Substantially expanded: capability-advertisement section (XEP-0030/0115/0199), the `aesgcm://` (XEP-0454) encrypted-media path, the updated inbound flow (`extract_inbound_attachments` → `collect_oob_urls`/`collect_aesgcm_urls` → bounded-concurrency download → streamed size cap), updated limits table, a Security Notes section, and an Implementation Status section describing the four phases and what remains.
- `docs/ops/XMPP_KNOWN_ISSUES.md` — Reconciled: inbound uploads now described as implemented (incl. encrypted media) with live e2e validation pending; new note that inbound downloads have no SSRF guard (deferred).
- **Self-healing / chaos** — new `docs/proposals/CHAOS_ENGINEERING_TEST_PLAN.md` (test plan + matrix), `docs/proposals/SELF_HEALING_IMPROVEMENTS_2.md` (merged code review), `docs/architecture/SELF_HEAL_DEPLOYMENT_WIRING.md` (how the pipeline is installed/scheduled and why it's host-level, not per-tenant), `docs/ops/GOALS_1.1.2_INFRA_HEALTH_CHECK.md` (verification notes), and `ic-infrastructure-health-check/tests/BAUD_REVIEW.md` (suite assessment); `ic-infrastructure-health-check/README.md` scheduling instructions rewritten.
- `ic/src/llm/CLAUDE.md` — Documented the tool-call recovery path and the `<function=…>` dialect that caused the v1.1.2 lapse recurrence; `docs/bugs/BUG-LAPSE.md` records the bug.
- **Bug-tracker cleanup** (2026-06-08) — pruned superseded agent-transcript dumps (`LIST-OF-BUGS-BY-NOKO.md`, `PROPOSED-FIX-BY-NOKO-…`, `PROPOSED-FIX-BY-BAUD-…`, `BUGS-SUNBURST.md`, `docs/proposals/Bugs.md`) whose technical content is preserved in the canonical bug docs and the `docs/bugs/README.md` Open/Fixed index; added `BUG-LAPSE.md`; trimmed `WEECHAT-NO-SECRET-ACCESS.md`.
- `docs/ops/ROADMAP_2026.MD` — New consolidated roadmap; historical checklists archived under `docs/ops/history/`. `docs/README.md` index refreshed.
- `docs/ops/RELEASE-COMMANDS.md` — Release-command reference.
- `RELEASE-v1.1.1.md` archived to `docs/ops/`.
- **Google extension removal** — `ic/tools-src/TOOLS.md`, `ic/src/registry/mod.rs`, `ic/src/cli/registry.rs`, and `ic/tests/e2e/CLAUDE.md` updated to drop the removed Google tools from the catalog, bundle list, CLI help, and e2e scenario table. See *Removal of Google Tool Extensions* above.

## Known Issues (not a complete list — see `docs/bugs` for more)

- **XMPP inbound file transfer — implemented (incl. encrypted media), live e2e validation pending.** The full receive pipeline (capability advertisement → OOB/`aesgcm://` extraction → bounded download → decrypt → WASM channel decode) is unit-tested and the bridge builds in release, but it has **not** yet been exercised end-to-end against a real server (Conversations/Gajim → agent over a working XEP-0363 host). This is the one real file-transfer caveat for the release. See `docs/ops/XMPP_KNOWN_ISSUES.md` and `docs/architecture/XMPP_FILE_TRANSFERS.md`.
- **Inbound XMPP downloads have no SSRF guard (deferred).** The client fetches sender-supplied OOB / `aesgcm://` URLs without blocking private/loopback/metadata IPs. Deployments rely on the network boundary and the `ALLOW_PRIVATE_IPS` model; a future phase can reuse `config/helpers.rs::validate_base_url`.
- **Self-healing verified by dry-run + unit tests, not against live running services.** The self-heal hardening and chaos suite were verified on a dev host (dry-run + the mock init system + unit tests); the restart → verify → escalate path has **not** been exercised against running services on a real multi-tenant deployment. (Tracks with the v1.1.8 "expansion of healthcheck tests for ClickHouse" roadmap item.)
- **Self-heal is installed but not auto-scheduled, and not wired into provisioning.** `install-lunarwing-watchdog.sh` copies the self-heal / health-cron scripts into `/usr/local/sbin` but enables no timer for them, and the repo ships no health-check `.timer`/`.service` unit — so a fresh host has self-healing **dormant** until an operator both runs the installer and schedules `cron-wrapper.sh`. Tenant provisioning (`lunarwing-mt-admin.sh add-tenant`) installs none of it (it's a once-per-host concern). See `docs/architecture/SELF_HEAL_DEPLOYMENT_WIRING.md` (gaps G1/G2).
- **`wasm-tools` not found on build** — Cosmetic warning during `build-tenant --with-wasm`. Raw WASM files are copied without stripping/componentizing. Functionality is unaffected; install `wasm-tools` to eliminate the warning.
- **Gotify skill frontmatter** — Legacy `GOTIFYSKILL.md` files from Ironclaw may have missing YAML frontmatter delimiters, causing a skill load warning on startup. Does not affect Gotify native WASM tool functionality.
- **Logs download endpoint has no UI button** — `/api/logs/download` is available as a backend API but the corresponding gateway UI "download logs" button has not been added yet.
- **`e2e_advanced_traces` bootstrap-greeting tests failing** — `bootstrap_greeting_fires` and `bootstrap_onboarding_clears_bootstrap` fail because the static bootstrap greeting doesn't arrive in the test rig. Pre-existing (surfaced once the v1.1.1 `cargo test` compile blocker was fixed); not LLM/`StubLlm`-related. One of the 16 pre-existing, env-dependent e2e failures confirmed unchanged by this release's work. See `docs/bugs/BUG-e2e-bootstrap-greeting-tests.md`.
- **Multica Bridge** — May require significant improvements; remains pre-release/experimental.
- **Multi-tenant admin script** — A flag exists to set an API key for a model endpoint, but no equivalent flag exists to set an HTTP URL automatically via this method.

## Upgrade Notes

1. **No new database migrations.** v1.1.2 adds no schema changes; the existing V18–V21 migrations from prior releases still run automatically on first startup of an older instance. **Back up your database before upgrading** as a matter of course. PostgreSQL 15+ remains required for V21's `NULLS NOT DISTINCT` syntax.
2. **Rebuild the XMPP bridge for inbound file transfer.** The bridge contract's `attachments` field is `#[serde(default)]` (backward compatible), so older bridge binaries keep working with attachments empty — but rebuild `ic/bridges/xmpp-bridge` to pick up the capability advertisement, `aesgcm://` decryption, and download hardening. Restart cascades: `xmpp-bridge.service` has `PartOf=lunarwing.service`.
3. **Crate version bump (pending).** Workspace crates are still at `1.1.1` at the time of this draft and must be bumped to `1.1.2` before tagging (see the `docs/ops/GOALS_1.1.2.md` checklist).
4. **No action required for the lapse fix.** The reasoning tool-call recovery is transparent — no configuration changes — and benefits deployments running GLM/Qwen-style local models behind the TensorZero/`openai_compatible` path.
5. **Already-installed Google tools persist until removed.** This change stops LunarWing from shipping and registering the Google tools, but an instance that previously installed them keeps the WASM artifacts in its base dir and the extension rows in its database. They can no longer be reinstalled from the registry; remove them per-instance with `lunarwing tool remove <name>` (or the gateway Extensions UI) if desired. Nothing breaks if they remain.
6. **Self-healing is opt-in per host.** The hardened self-heal pipeline does not run unless an operator installs the watchdog (`ic/scripts/install-lunarwing-watchdog.sh`, once per host) **and** schedules `cron-wrapper.sh` on a timer/cron — it is not enabled by an upgrade and not installed by tenant provisioning. Existing self-heal installs should re-copy the updated `lunarwing-self-heal.sh` to pick up the jq fix and the resilience hardening. See `docs/architecture/SELF_HEAL_DEPLOYMENT_WIRING.md`.
7. **Raspberry Pi builds (ARM only).** On aarch64 hosts you can build natively with `scripts/build-lunarwing.sh` (Pi 5 / low-resource ARM); other platforms continue to use the standard `cargo build --release --bin lunarwing` flow.

## Previously "Planned for v1.1.2" — now landed

Both items listed as in-progress in the prior draft have **landed in this release**:

- **Improvements to compile warnings/errors** → see *Code Quality — Clippy Zero-Warning Gate + Formatting*. The full clippy gate is now green.
- **Healthcheck and self-healing enhancements** → see *Infrastructure Self-Healing — Resilience Hardening*, *Chaos Engineering Test Suite*, and *Infrastructure Health-Check — Fixes & Cleanup*.

The remaining-Google-extension removal also landed (see *Removal of Google Tool Extensions*). The GitHub extension decision remains deferred (currently targeted v1.1.9).

## Features and changes deferred to future releases

The full, canonical list now lives in **`docs/ops/ROADMAP_2026.MD`**. Items are grouped to respect the release cadence (`docs/ops/RELEASE_CADENCE.md`): odd-numbered releases focus on bug fixes / security / polish / cleanup, even-numbered releases focus on features, and major versions such as 1.2.0 or 1.3.0 will typically include massive overhauls of existing systems. Near-term highlights:

| Feature | Target |
|---------|--------|
| External worker (Pebble, Codex, Nanocode) polishing; Lunarvision K.E.R.S. setup polishing | v1.1.3 |
| Multica bridge/channel refinements; Lunartica UI reskin | v1.1.4 |
| XMPP file transfer remaining polish (live e2e, optional SSRF guard, more hardening); XMPP OMEMO MUC fallback fix; drop the custom TensorZero proxy | v1.1.5 |
| Self-healing epic (first-class, wired-in) | v1.2.0 |

## Release Cadence

*A brief note about release cadence*

### LunarWing abides by a release cadence. This helps to organize introduction of new `feature` and `polish` focused releases.
### For more information, please see:
* docs/ops/RELEASE_CADENCE.md
#### Occasionally, exceptions are made to the release cadence guidelines, but the goal is to try to stay within this paradigm.

## Testing

*In accordance with developer guidelines, a brief testing period must begin before each release.*

*Testing for this release has **not yet commenced**. The pre-release checklist lives in `docs/ops/GOALS_1.1.2.md`; the full checklist is in `docs/ops/PRE-RELEASE-TESTING.md`; automated coverage is driven by `ic/scripts/release-test.sh` and `docs/guides/TESTING_GUIDE.md`. The self-healing chaos suite (`ic-infrastructure-health-check/tests/run-all.sh`) should be run on a dedicated test machine, not a live multi-tenant host.*

*Once evaluation begins, no new changes besides urgent fixes will be accepted into staging during the evaluation period.*
