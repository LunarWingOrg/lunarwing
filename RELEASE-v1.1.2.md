# Release Notes for LunarWing v1.1.2 - Codename TBD

**Release Date:** TBD (in preparation)

## Overview

Per the release cadence (`docs/ops/RELEASE_CADENCE.md`), even-numbered releases are feature releases — but in practice v1.1.2 is predominantly polish, hardening, and fixes built on top of the v1.1.1 foundation. The two headline changes are a **more robust fix for the long-standing empty-response "lapse" bug** (now recovering tool calls that GLM/Qwen-style models emit in the `<function=NAME>…</function>` XML dialect instead of misreporting them as empty responses) and a **substantial round of XMPP inbound file-transfer hardening** (XEP-0030/0115 capability advertisement so clients will actually offer to send files, XEP-0454 `aesgcm://` encrypted-media download + AES-256-GCM decryption, bounded-concurrency downloads, and streamed size enforcement). The release also **removes the remaining Google tool extensions** (Gmail, Calendar, Drive, Docs, Sheets, Slides) as part of LunarWing's proprietary-extension cleanup, and carries forward release-process tooling/documentation and the usual housekeeping. One item targeted for this cycle — healthcheck/self-healing enhancements — remains in progress at the time of this draft (see *Planned for v1.1.2*).

---

## Changes

### Reasoning Tool-Call Recovery — "Lapse" Bug, Better Implementation (continued from v1.1.0)

v1.1.0 first addressed the "momentary lapse" where reasoning models returned content that `clean_response()` stripped to empty, producing a silent "I'm not sure how to respond to that." fallback. v1.1.2 fixes a **recurrence with a different root cause**: some GLM/Qwen-style models emit a *well-formed tool call* as plain text in the `<function=NAME><parameter=KEY>value</parameter></function>` XML dialect, with the structured `tool_calls` field left empty. Those calls were being stripped to empty and misreported as empty responses, re-triggering the fallback instead of executing the tool. This was the deferred "better implementation of the memory lapse bug fix" item from the v1.1.1 notes.

Implemented in `ic/src/llm/reasoning.rs`:

- **`recover_function_xml_calls()`** — New recovery function that scans raw content for `<function=NAME>` blocks (with or without the surrounding `<tool_call>` wrapper), extracts each `<parameter=KEY>VALUE</parameter>` into the arguments object, and returns a `ToolCall` only when `NAME` matches a known tool. Parameter values are JSON-parsed when valid (so `true` and numbers keep their type) and otherwise kept as a trimmed string (so a multi-word search query stays a string). A `seed_offset` continues the caller's ID numbering so recovered IDs stay unique across recovery formats.
- **Wired into `recover_tool_calls_from_content()`** — Joins the existing recognized dialects: JSON inside `<tool_call>`/`<function_call>` (incl. pipe-delimited), a bare tool name inside `<tool_call>`, and the `[Called tool \`name\` with arguments: {...}]` bracket form.
- **`strip_function_xml_tags()`** — New `clean_response()` step (6c) that strips any leftover `<function=…>` blocks so unrecovered ones never leak into user-facing text. An unclosed `<function=` drops the trailing partial XML, mirroring the strict handling of unclosed thinking tags.
- **8 new tests** — `<function=…>` with parameters (type coercion), without parameters, unwrapped (no `<tool_call>`), unknown-tool-ignored, string-value-not-coerced, unique IDs, `clean_response` strips tags, plus an async `respond_with_tools()` regression (`test_respond_with_tools_recovers_function_xml_dialect`) driven by `StubLlm` that asserts the dialect is recovered and executed rather than returning the fallback. Test payloads mirror the exact content captured in production logs.
- **Docs** — `ic/src/llm/CLAUDE.md` updated to document the tool-call recovery path and the dialects it recognizes.

### XMPP Inbound File Transfer Hardening (Capability Advertisement, Encrypted Media, Download Safety)

v1.1.1 shipped the first inbound XMPP file pipeline (OOB extraction + download) but it had **not** been validated end-to-end and lacked several robustness and protocol pieces. v1.1.2 delivers a substantial hardening pass to the XMPP client (`ic/src/channels/xmpp/mod.rs`, +627 lines) across four phases. (Note: a chunk of this work was originally scheduled for v1.1.5; the core landed early.)

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

### Removal of Google Tool Extensions

Following the earlier removal of the proprietary Slack, Discord, WhatsApp, and Feishu channels, v1.1.2 retires the six **Google tool extensions** that previously shipped in the registry — **Gmail, Google Calendar, Google Drive, Google Docs, Google Sheets, and Google Slides** — in keeping with the Lunarpunk direction.

Removed:

- **Tool sources** — the WASM tool crates under `ic/tools-src/{gmail,google-calendar,google-docs,google-drive,google-sheets,google-slides}/` and their entries in the `ic/Cargo.toml` workspace `exclude` list.
- **Registry manifests** — `ic/registry/tools/{gmail,google-*}.json`, so the tools no longer appear in `lunarwing registry list` or build via `scripts/build-wasm-extensions.sh`. The embedded registry catalog (generated by `build.rs`) regenerates automatically without them.
- **Bundles** — the `google` ("Google Suite") bundle in `ic/registry/_bundles.json` is deleted, and Gmail/Calendar/Drive are dropped from the `default` ("Recommended Set") bundle, now just GitHub + Telegram.
- **Advertised docs & CLI help** — the Google section of `ic/tools-src/TOOLS.md`, the bundle list in `ic/src/registry/mod.rs`, and the `registry` CLI help examples that referenced `google` / `tools/gmail`.
- **e2e scenarios** — six gmail-based pytest/Playwright scenarios that installed the real `gmail` extension to exercise OAuth and WASM-lifecycle machinery (`test_oauth_refresh`, `test_extension_oauth`, `test_oauth_url_parameters`, `test_oauth_credential_fallback`, `test_routine_oauth_credential_injection`, `test_wasm_lifecycle`), plus the now-dead `gmail` intent in `mock_llm.py`.

**Retained** — these are Google as an identity/LLM *provider* or shared *infrastructure*, not installable tool extensions, and are intentionally unaffected for the timebeing:

- **Security & infrastructure** — the leak detector's Google-API-key pattern, the `metadata.google.internal` SSRF block, the GCP Cloud-SQL-proxy download, and the Google Fonts CDN reference all remain.

**Verification:** `cargo check` (default and `--no-default-features --features libsql`), `cargo test --lib` (3940 passed), `cargo fmt --check`, and clippy all pass with no new warnings from the removal; every remaining e2e Python module compiles.

### Code Formatting Pass

A `rustfmt` pass tidied four files touched by recent security/registry work with no behavior change: `ic/src/app.rs` (ghost-seed cleanup call + sentinel get/set), `ic/src/bridge/router.rs` (clamping test fixtures), `ic/src/channels/wasm/setup.rs` (env-source override test assertions), and `ic/src/extensions/registry.rs` (hidden-entry filtering in `all_entries()`).

### Release Process Tooling & Documentation

- **`docs/ops/RELEASE-COMMANDS.md`** — New draft reference capturing the command sequence used to cut a release (branch, tag, archive notes, GH release).
- **Release notes archival** — `RELEASE-v1.1.1.md` moved from the repo root to `docs/ops/RELEASE-v1.1.1.md`, continuing the convention established in v1.1.1 of preserving historical release notes under `docs/ops/`.
- **Goals tracking** — `GOALS_1.1.1.md` renamed to `docs/ops/GOALS_1.1.2.md` and updated with the v1.1.2 pre-release checklist.

## Bug Fixes

- **Empty-response "lapse" recurrence via the `<function=…>` dialect** — GLM/Qwen-style models that emit tool calls as `<function=NAME><parameter=KEY>value</parameter></function>` text (with an empty structured `tool_calls` field) had those calls stripped to empty and misreported as empty responses, returning the "I'm not sure how to respond to that." fallback instead of executing the tool. Now recovered via `recover_function_xml_calls()`; any unrecovered blocks are stripped from user-facing text by `strip_function_xml_tags()`. See *Reasoning Tool-Call Recovery* above.
- **XMPP clients refused to send files to the agent** — The client did not answer `disco#info`/IQ requests, so capability-checking clients timed out and treated the agent as an invalid recipient. The client now advertises identity + features (XEP-0030/0115) and answers every IQ (`build_iq_reply()`), so clients recognize the agent as a valid file recipient.
- **XMPP inbound files with extensionless/opaque names were dropped** — `filename_from_url()` now keeps opaque last-path segments (e.g. XEP-0363 UUIDs), preventing distinct files from collapsing onto the same `oob-{filename}` storage key.
- **Unbounded buffering / serialized downloads on inbound attachments** — Inbound downloads now enforce the 20 MB cap while streaming, bound the per-stanza URL count (10) and the download concurrency (4), so a crafted stanza cannot exhaust memory or stall the single client event loop.

## Documentation

- `docs/architecture/XMPP_FILE_TRANSFERS.md` — Substantially expanded: capability-advertisement section (XEP-0030/0115/0199), the `aesgcm://` (XEP-0454) encrypted-media path, the updated inbound flow (`extract_inbound_attachments` → `collect_oob_urls`/`collect_aesgcm_urls` → bounded-concurrency download → streamed size cap), updated limits table, a Security Notes section, and an Implementation Status section describing the four phases and what remains.
- `docs/ops/XMPP_KNOWN_ISSUES.md` — Reconciled: inbound uploads now described as implemented (incl. encrypted media) with live e2e validation pending; new note that inbound downloads have no SSRF guard (deferred).
- `ic/src/llm/CLAUDE.md` — Documented the tool-call recovery path and the `<function=…>` dialect that caused the v1.1.2 lapse recurrence.
- `docs/ops/RELEASE-COMMANDS.md` — New release-command reference (draft).
- `docs/ops/GOALS_1.1.2.md` — v1.1.2 pre-release checklist (renamed from `GOALS_1.1.1.md`).
- `RELEASE-v1.1.1.md` archived to `docs/ops/`.
- **Google extension removal** — `ic/tools-src/TOOLS.md`, `ic/src/registry/mod.rs`, `ic/src/cli/registry.rs`, and `ic/tests/e2e/CLAUDE.md` updated to drop the removed Google tools from the catalog, bundle list, CLI help, and e2e scenario table. See *Removal of Google Tool Extensions* above.

## Known Issues (not a complete list — see `docs/bugs` for more)

- **XMPP inbound file transfer — implemented (incl. encrypted media), live e2e validation pending.** The full receive pipeline (capability advertisement → OOB/`aesgcm://` extraction → bounded download → decrypt → WASM channel decode) is unit-tested and the bridge builds in release, but it has **not** yet been exercised end-to-end against a real server (Conversations/Gajim → agent over a working XEP-0363 host). This is the one real file-transfer caveat for the release. See `docs/ops/XMPP_KNOWN_ISSUES.md` and `docs/architecture/XMPP_FILE_TRANSFERS.md`.
- **Inbound XMPP downloads have no SSRF guard (deferred).** The client fetches sender-supplied OOB / `aesgcm://` URLs without blocking private/loopback/metadata IPs. Deployments rely on the network boundary and the `ALLOW_PRIVATE_IPS` model; a future phase can reuse `config/helpers.rs::validate_base_url`.
- **`wasm-tools` not found on build** — Cosmetic warning during `build-tenant --with-wasm`. Raw WASM files are copied without stripping/componentizing. Functionality is unaffected; install `wasm-tools` to eliminate the warning.
- **Gotify skill frontmatter** — Legacy `GOTIFYSKILL.md` files from Ironclaw may have missing YAML frontmatter delimiters, causing a skill load warning on startup. Does not affect Gotify native WASM tool functionality.
- **Logs download endpoint has no UI button** — `/api/logs/download` is available as a backend API but the corresponding gateway UI "download logs" button has not been added yet.
- **`e2e_advanced_traces` bootstrap-greeting tests failing** — `bootstrap_greeting_fires` and `bootstrap_onboarding_clears_bootstrap` fail because the static bootstrap greeting doesn't arrive in the test rig. Pre-existing (surfaced once the v1.1.1 `cargo test` compile blocker was fixed); not LLM/`StubLlm`-related. See `docs/bugs/BUG-e2e-bootstrap-greeting-tests.md`.
- **Multica Bridge** — May require significant improvements; remains pre-release/experimental.
- **Multi-tenant admin script** — A flag exists to set an API key for a model endpoint, but no equivalent flag exists to set an HTTP URL automatically via this method.

## Upgrade Notes

1. **No new database migrations.** v1.1.2 adds no schema changes; the existing V18–V21 migrations from prior releases still run automatically on first startup of an older instance. **Back up your database before upgrading** as a matter of course. PostgreSQL 15+ remains required for V21's `NULLS NOT DISTINCT` syntax.
2. **Rebuild the XMPP bridge for inbound file transfer.** The bridge contract's `attachments` field is `#[serde(default)]` (backward compatible), so older bridge binaries keep working with attachments empty — but rebuild `ic/bridges/xmpp-bridge` to pick up the capability advertisement, `aesgcm://` decryption, and download hardening. Restart cascades: `xmpp-bridge.service` has `PartOf=lunarwing.service`.
3. **Crate version bump (pending).** Workspace crates are still at `1.1.1` at the time of this draft and must be bumped to `1.1.2` before tagging (see the `docs/ops/GOALS_1.1.2.md` checklist).
4. **No action required for the lapse fix.** The reasoning tool-call recovery is transparent — no configuration changes — and benefits deployments running GLM/Qwen-style local models behind the TensorZero/`openai_compatible` path.
5. **Already-installed Google tools persist until removed.** This change stops LunarWing from shipping and registering the Google tools, but an instance that previously installed them keeps the WASM artifacts in its base dir and the extension rows in its database. They can no longer be reinstalled from the registry; remove them per-instance with `lunarwing tool remove <name>` (or the gateway Extensions UI) if desired. Nothing breaks if they remain.

## Planned for v1.1.2 (in progress, not yet landed)

These items are targeted for this release per the v1.1.1 deferral table but have **not** landed in staging as of this draft. They may ship in v1.1.2 if completed during the testing window, or slip to a later release:

- **Healthcheck and self-healing enhancements** — Further improvements to the infrastructure health-check suite and watchdog beyond the v1.1.1 baseline.

> The remaining-Google-extension removal originally tracked here **landed in this release** — see *Removal of Google Tool Extensions* under Changes. The GitHub extension decision remains deferred (currently targeted v1.1.9).

## Features and changes deferred to future releases

Items are grouped to respect the release cadence (`docs/ops/RELEASE_CADENCE.md`): odd-numbered releases focus on bug fixes / security / polish / cleanup, even-numbered releases focus on features, and major versions such as 1.2.0 or 1.3.0 will typically include massive overhauls of existing systems.

| Feature | Target |
|---------|--------|
| Existing external worker polishing | v1.1.3 |
| K.E.R.S. Lunarvision polishing | v1.1.3 |
| Update funding.json with actual payment addresses and additional info | v1.1.3 |
| Multica bridge and channel refinements and agent orchestration workflow improvements (currently marked as pre-release/experimental; more testing required) | v1.1.4 |
| Lunartica UI reskin | v1.1.4 |
| XMPP OMEMO MUC fallback fix | v1.1.5 |
| XMPP file transfer — remaining polish (live end-to-end validation, optional SSRF guard, further round of hardening) | v1.1.5 |
| Drop support for the custom TensorZero proxy (verified no longer necessary; local models handle all tool calls over TensorZero directly) — disable on existing tenants and by default on new ones | v1.1.5 |
| External Worker enhancements | v1.1.6 |
| Add rootless docker and rootless podman as mechanisms for mt-admin setup | v1.1.6 |
| List of planned suggested features to pre-emptively improve security via input validation | v1.1.7 |
| WASM Channel Polishing | v1.1.7 |
| Rename ironclaw references in WeeChat channel and adapter | v1.1.7 |
| Add the custom Git WASM workspace tool source code created months ago back to LunarWing, test again | v1.1.8 |
| Upgrade version of tensorzero, plus optional tighter integration across deployments, plus expansion of healthcheck tests for Clickhouse Database | v1.1.8 |
| Proprietary channel removal continuation (Telegram) | v1.1.9 |
| Decision to remove GitHub extension | v1.1.9 |
| v2 engine route, LunarWing UI Performance Overhaul | v1.2.0 |
| Better githooks for repo | v1.2.1 |
| LunarWing developer CI/CD pipeline | v1.2.1 |
| LunarWing decision on switching to Codeberg or self-hosted GitLab rather than GitHub to host the monorepo (GH can still be used as a mirror) | v1.2.1 |
| LunarVoice (further planning required) | v1.2.2 |
| Stabilization & polish buffer — reserved for v2 engine and LunarVoice fallout (no new features planned; fill from bugs found across 1.2.0–1.2.2) | v1.2.3 |
| Character Lorebook support / Agent Profile enhancements / Workspace Seeding improvements / Agent Profile switching / User Profile switching (further planning required) | v1.2.4 |
| New suite of planned features adopting concepts from Hermes Agent (Human Delay mode already landed in a prior release); comprehensive documentation to accompany each | v1.2.4 |

## Release Cadence

*A brief note about release cadence*

### LunarWing abides by a release cadence. This helps to organize introduction of new `feature` and `polish` focused releases.
### For more information, please see:
* docs/ops/RELEASE_CADENCE.md
#### Occasionally, exceptions are made to the release cadence guidelines, but the goal is to try to stay within this paradigm.

## Testing

*In accordance with developer guidelines, a brief testing period must begin before each release.*

*Testing for this release has **not yet commenced**. The pre-release checklist lives in `docs/ops/GOALS_1.1.2.md`; the full checklist is in `docs/ops/PRE-RELEASE-TESTING.md`; automated coverage is driven by `ic/scripts/release-test.sh` and `docs/guides/TESTING_GUIDE.md`.*

*Once evaluation begins, no new changes besides urgent fixes will be accepted into staging during the evaluation period.*
