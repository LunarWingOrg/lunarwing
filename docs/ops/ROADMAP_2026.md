# Roadmap

## Formerly: Features and changes deferred to future releases

Items are grouped to respect the release cadence (`docs/ops/RELEASE_CADENCE.md`): odd-numbered releases focus on bug fixes / security / polish / cleanup, even-numbered releases focus on features, and major versions such as 1.2.0 or 1.3.0 will typically include massive overhauls of existing systems.


### TODO: ADD PASTA+SS to ROADMAP

### Near-term

| Feature | Target |
|---------|--------|
| Finish what was started in 1.1.6 with external worker improvements, will require new por migration | v.1.1.7 |
| Further polish of some existing channels | v1.1.7 |
| Multica bridge/channel refinements and agent orchestration workflow improvements; Lunartica UI reskin continuation | v1.1.7 |
| XMPP OMEMO MUC fallback fix *(was targeted v1.1.5 — slipped)* | v1.1.7 |
| XMPP file transfer — remaining polish (live e2e validation, optional SSRF guard, further hardening) *(was targeted v1.1.5 — slipped)* | v1.1.7 |
| Lunarvision K.E.R.S and Vision OCR Sidecar. system setup polishing. Extend health check for LunarVision system *(was targeted v1.1.5 — slipped)* | v1.1.7 |
| Per-tenant WeeChat health-glob gate (fix the flap / `render-units` footgun) | v1.1.7 |
| Rootless Podman per-tenant container parent-supervision babysitter (`podman wait`, crash-recovery latency) | v1.1.7 |
| Drop support for the custom TensorZero proxy (toggle off existing, default-disabled on new); planned input-validation security improvements; some remaining IC->LW renames for commands, documentation, and repository directories (WeeChat channel/adapter, DarkIRC, Gotify tool) | v1.1.7 |
| Agent SSH/Mosh Harness | v1.1.8 |
| Re-add the custom Git WASM workspace tool; Enhance Onboarding Process for fresh tenants with interactive version of multi admin setup; TensorZero upgrade + optional tighter integration across deployments + Gateway/ClickHouse/UI healthcheck test expansion | v1.1.8 |
| Add Opencode external worker similar to nanocode worker | v1.1.8 |
| Remove half-baked Codex external worker | v1.1.9 |
| Remove GitHub extension from the official project repo (not very useful anyway) | v1.1.9 |                                                                                      | Further re-organization of repository documentation as follow up to work done in 1.1.5 | v1.1.9 | 


### Longer-term

| Feature | Target |
|---------|--------|
| v2 engine implementation; LunarWing UI performance overhaul; self-healing capability expansion | v1.2.0 |
| Better githooks for repo | v1.2.1 |
| LunarWing developer CI/CD pipeline, including x86-64 and AARCH64 builds | v1.2.1 |
| LunarWing decision on switching to Codeberg or self-hosted GitLab on *source.lunarwing.org* rather than GitHub to host the monorepo (GH can still be used as a mirror) | v1.2.1 |
| Character Lorebook support / Agent Profile enhancements / Workspace Seeding improvements / Agent Profile switching / User Profile switching (further planning required) | v1.2.2 |
| Proprietary channel and code removal for Telegram | v1.2.3 |
| New suite of planned features adopting concepts from Hermes Agent (Human Delay mode already landed in a prior release); comprehensive documentation to accompany each | v1.2.4 |
| Additional WASM Channel Polishing | v1.2.5 |
| Reflex Compiler polishing and improvements | v1.2.5 |
| LunarVoice (further planning required) | v1.2.6 |
| Stabilization & polish buffer — reserved for v2 engine, LunarVoice, other new features from after 1.1.8 | v1.2.7 |

---

