# Roadmap

## Formerly: Features and changes deferred to future releases

Items are grouped to respect the release cadence (`docs/ops/RELEASE_CADENCE.md`): odd-numbered releases focus on bug fixes / security / polish / cleanup, even-numbered releases focus on features, and major versions such as 1.2.0 or 1.3.0 will typically include massive overhauls of existing systems.

| Feature | Target |
|---------|--------|
| Existing external worker, Pebble, Codex, Nanocode polishing | v1.1.3 |
| Lunarvision K.E.R.S. system setup polishing | v1.1.3 |
| Update funding.json with actual payment addresses, additional info | v1.1.3 |
| Multica bridge and channel refinements and agent orchestration workflow improvements (currently marked as pre-release/experimental; more testing required) | v1.1.4 |
| Lunartica UI reskin | v1.1.4 |
| XMPP OMEMO MUC fallback fix | v1.1.5 |
| XMPP file transfer — remaining polish (live end-to-end validation, optional SSRF guard, further round of hardening) | v1.1.5 |
| Drop support for the custom TensorZero proxy (verified no longer necessary; local models handle all tool calls over TensorZero directly) — disable on existing tenants and by default on new ones | v1.1.5 |
| External Worker planned enhancements | v1.1.6 |
| Add rootless docker and rootless podman as mechanisms for mt-admin setup | v1.1.6 |
| List of planned suggested features to pre-emptively improve security via input validation | v1.1.7 |
| Additional WASM Channel Polishing | v1.1.7 |
| Rename ironclaw references in WeeChat channel and adapter | v1.1.7 |
| Rename ironclaw references in Gotify tool | v1.1.7 |
| Add the custom Git WASM workspace tool source code created months ago back to LunarWing, test again | v1.1.8 |
| Upgrade version of tensorzero, plus optional tighter integration across deployments, plus expansion of healthcheck tests for Clickhouse Database | v1.1.8 |
| Proprietary channel removal continuation (Telegram) | v1.1.9 |
| Decision to remove GitHub extension | v1.1.9 |
| implementation of v2 engine, LunarWing UI Performance Overhaul | v1.2.0 |
| Better githooks for repo | v1.2.1 |
| LunarWing developer CI/CD pipeline | v1.2.1 |
| LunarWing decision on switching to Codeberg or self-hosted GitLab rather than GitHub to host the monorepo (GH can still be used as a mirror) | v1.2.1 |
| Character Lorebook support / Agent Profile enhancements / Workspace Seeding improvements / Agent Profile switching / User Profile switching (further planning required) | v1.2.4 |
| New suite of planned features adopting concepts from Hermes Agent (Human Delay mode already landed in a prior release); comprehensive documentation to accompany each | v1.2.4 |
| LunarVoice (further planning required) | v1.2.6 |
| Stabilization & polish buffer — reserved for v2 engine and LunarVoice fallout (no new features planned; fill from bugs found across 1.2.0–1.2.6) | v1.2.7 |
