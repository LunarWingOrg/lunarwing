# Roadmap

## Formerly: Features and changes deferred to future releases

Items are grouped to respect the release cadence (`docs/ops/RELEASE_CADENCE.md`): odd-numbered releases focus on bug fixes / security / polish / cleanup, even-numbered releases focus on features, and major versions such as 1.2.0 or 1.3.0 will typically include massive overhauls of existing systems.

### Near-term

| Feature | Target |
|---------|--------|
| External Worker planned enhancements; Multica bridge/channel refinements and agent orchestration workflow improvements; Lunartica UI reskin continuation | v1.1.7 |
| Remaining migration/upgrade work (live-validate the rootless-adopt v1.1.0 → v1.1.4 `upgrade-tenant.sh`; extend `upgrade-tenant-version.sh` to source versions older than v1.0.9; spot-check OMEMO/secret continuity on a migration) | v1.1.7 |
| XMPP OMEMO MUC fallback fix *(was targeted v1.1.5 — slipped)* | v1.1.7 |
| XMPP file transfer — remaining polish (live e2e validation, optional SSRF guard, further hardening) *(was targeted v1.1.5 — slipped)* | v1.1.7 |
| Lunarvision K.E.R.S. system setup polishing *(was targeted v1.1.5 — slipped)* | v1.1.7 |
| Per-tenant WeeChat health-glob gate (fix the flap / `render-units` footgun) | v1.1.7 |
| Rootless Podman per-tenant container parent-supervision babysitter (`podman wait`, crash-recovery latency) | v1.1.7 |
| Drop support for the custom TensorZero proxy (toggle off existing, default-disabled on new); planned input-validation security improvements; remaining `ironclaw` → `lunarwing` renames (WeeChat channel/adapter, Gotify tool) | v1.1.7 |
| Re-add the custom Git WASM workspace tool; TensorZero upgrade + optional tighter integration across deployments + ClickHouse healthcheck test expansion | v1.1.8 |

### Longer-term

| Feature | Target |
|---------|--------|
| Decision to remove GitHub extension | v1.1.9 |
| v2 engine implementation + LunarWing UI performance overhaul; self-healing expansion | v1.2.0 |
| Better githooks for repo | v1.2.1 |
| LunarWing developer CI/CD pipeline | v1.2.1 |
| LunarWing decision on switching to Codeberg or self-hosted GitLab rather than GitHub to host the monorepo (GH can still be used as a mirror) | v1.2.1 |
| Character Lorebook support / Agent Profile enhancements / Workspace Seeding improvements / Agent Profile switching / User Profile switching (further planning required) | v1.2.2 |
| Proprietary channel removal conclusion (Telegram) | v1.2.3 |
| New suite of planned features adopting concepts from Hermes Agent (Human Delay mode already landed in a prior release); comprehensive documentation to accompany each | v1.2.4 |
| Additional WASM Channel Polishing | v1.2.5 |
| LunarVoice (further planning required) | v1.2.6 |
| Stabilization & polish buffer — reserved for v2 engine, LunarVoice, other new features from after 1.1.8 | v1.2.7 |

---

