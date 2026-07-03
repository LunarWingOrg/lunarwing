# Roadmap Document

Items are grouped to respect the release cadence (`docs/ops/RELEASE_CADENCE.md`): odd-numbered releases focus on bug fixes / security / polish / cleanup, even-numbered releases focus on features, and major versions such as 1.2.0 or 1.3.0 will typically include massive overhauls of existing systems.

## Notes about the roadmap

* The roadmap does not normally track items and goals related to the upcoming release. The roadmap contains a list which begins with the release after the next one.
* i.e. If the current stable release is 1.1.7 and the upcoming release is 1.1.8, the roadmap would begin with 1.1.9

### Near-term (prior to next significant release)

| Feature | Target |
|---------|--------|
| Some remaining IC->LW renames for commands, documentation, and repository directories (WeeChat channel/adapter, DarkIRC, Gotify tool, connection protocol names) | v1.1.9 |
| Remove deprecated Codex external worker from project | v1.1.9 |
| Remove support for all (or at least, some of) the other random unsupported LLM providers | v1.1.9 |
| Remove rest of non-LunarWing third party extensions/tools/skills from default installation | v1.1.9 |
| Drop support for the custom TensorZero proxy (toggle off existing, default-disabled on new) | v1.1.9 |
| Per-tenant WeeChat health-glob gate (fix the flap / `render-units` footgun) | v1.1.9 |
| Enhance Onboarding Process for fresh tenants with interactive version of multi admin setup | v1.1.9 |
| Remove/archive stale documentation | v1.1.9 |
| Update outdated documentation | v1.1.9 |
| Further re-organization of repository documentation | v1.1.9 |

### Longer-term (including next significant release and beyond)

| Feature | Target |
|---------|--------|
| LunarWing UI performance overhaul | v1.2.0 |
| Several large proposals to ship | v1.2.0 |
| Engine crate Refactor | v1.2.0 |
| XMPP file transfer — remaining polish (further hardening) | v1.2.1 |
| Further polishing of Lunarvision AND XMPP file sharing integration - see XMPP_LUNARVISION_INTEGRATION.md in docs/proposals for some information | v1.2.1 |
| In-place Upgrade Harness v3/v4 to cover ALL version upgrades, rather than seperate legacy and non-legacy upgrade scripts | v1.2.1 |
| Migrate from Github to Forgejo. Multi-arch CI/CD pipeline for development | v1.2.1 |
| Better githooks for repo | v1.2.1 |
| Lorebook support / Agent Profile enhancements / Workspace Seeding improvements / Agent Profile switching / User Profile switching (further planning required) | v1.2.2 |
| Self-Healing Capability Expansion - deferred from 1.1.8 | v1.2.2 |
| Self-Healing Capabilities analysis of any missing pieces from all the new components. Implementation of missing pieces to follow | v1.2.2 |
| Proprietary channel and code removal for Telegram | v1.2.3 |
| Lunartica UI reskin continuation | v1.2.3 |
| Upgrade old testing harness | v1.2.3 |
| Further external worker polishing | v1.2.3 |
| Feature set of concepts adopted from Hermes Agent (Human Delay mode already landed in a prior release); comprehensive documentation to accompany each | v1.2.4 |
| Input-validation security improvements | v1.2.4 |
| ONNX Runtime speech to text model support necessary for LunarVoice | v1.2.4 |
| Additional WASM Channel Polishing | v1.2.5 |
| Additional Opencode/Paseo External Worker Polishing | v1.2.5 |
| Reflex Compiler polishing and improvements | v1.2.5 |
| LunarVoice Two Way Voice Communication | v1.2.6 |
| Deprecate Nanocode external Worker | v1.2.7 |
| Additional LunarVoice polishing | v1.2.7 |
| A surprise | v1.2.8 |

---


