# Roadmap Document

Items are grouped to respect the release cadence (`docs/ops/RELEASE_CADENCE.md`): odd-numbered releases focus on bug fixes / security / polish / cleanup, even-numbered releases focus on features, and major versions such as 2.0.0 or 2.1.0 will typically include massive overhauls of existing systems.

| Feature | Target |
|---------|--------|
| Drop legacy `ironclaw-agent-v1` subprotocol offer from the daemon (delete the `SUBPROTOCOL_LEGACY` offer in `ic/src/orchestrator/external_worker.rs`) and `git rm` the 1.1.9-only repo-root compat symlinks `ironclaw_weechat_wss`, `darkirc_channel_for_ironclaw` (deployed tenants must have re-run mt-admin unit regen by then) — deferred from 1.1.9 item #2 | v2.0.0 |
| LunarWing UI performance overhaul | v2.0.0 |
| Several large proposals to ship | v2.0.0 |
| Engine crate Refactor | v2.0.0 |
| XMPP file transfer — remaining polish (further hardening) | v2.0.1 |
| Drop legacy `ironclaw-agent-v1` acceptance from external workers (pebble/lunarcode/opencode `LEGACY_SUBPROTOCOL` constants + negotiation fallback), one release after the daemon stops offering it | v2.0.1 |
| Org/registry decisions deferred from 1.1.9 item #2: re-host registry WASM artifacts or make them source-build-only (nearai/ironclaw release URLs in `ic/registry/*.json` + `installer.rs` allowlist), fix or delete the `release-plz.yml` `repository_owner == 'nearai'` guard — fits alongside the Forgejo/CI migration. The Docker Hub image namespace was moved to `ggmethos/*` and the obsolete GCP VM bootstrap path was removed in 1.1.9 cleanup. | v2.0.1 |
| Further polishing of Lunarvision AND XMPP file sharing integration - see XMPP_LUNARVISION_INTEGRATION.md in docs/proposals for some information | v2.0.1 |
| In-place Upgrade Harness v3/v4 to cover ALL version upgrades, rather than separate legacy and non-legacy upgrade scripts | v2.0.1 |
| Migrate from Github to Forgejo. Multi-arch CI/CD pipeline for development | v2.0.1 |
| Better githooks for repo | v2.0.1 |
| Lorebook support / Agent Profile enhancements / Workspace Seeding improvements / Agent Profile switching / User Profile switching (further planning required) | v2.0.2 |
| Self-Healing Capability Expansion - deferred from 1.1.8 | v2.0.2 |
| Self-Healing Capabilities analysis of any missing pieces from all the new components. Implementation of missing pieces to follow | v2.0.2 |
| Per-tenant WeeChat health-glob gate (fix the flap /`render-units` footgun) | v2.0.3 |
| Proprietary channel and code removal for Telegram | v2.0.3 |
| Lunartica UI reskin continuation | v2.0.3 |
| Upgrade old testing harness | v2.0.3 |
| Further external worker polishing | v2.0.3 |
| Feature set of concepts adopted from Hermes Agent (Human Delay mode already landed in a prior release); comprehensive documentation to accompany each | v2.0.4 |
| Input-validation security improvements | v2.0.4 |
| ONNX Runtime speech to text model support necessary for LunarVoice | v2.0.4 |
| Additional WASM Channel Polishing | v2.0.5 |
| Additional Opencode/Paseo External Worker Polishing | v2.0.5 |
| Reflex Compiler polishing and improvements | v2.0.5 |
| LunarVoice Two Way Voice Communication | v2.0.6 |
| Deprecate Nanocode external Worker | v2.0.7 |
| Additional LunarVoice polishing | v2.0.7 |
| A surprise | v2.0.8 |

---

