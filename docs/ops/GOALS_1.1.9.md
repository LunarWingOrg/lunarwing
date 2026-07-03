# PRE-RELEASE CHECKLIST for 1.1.9 Codename `???`
**Open TODOs (1.1.9) — To be done before release**

### Helps to do items in order (generally)

1. [ ] Finalize goals
2. [ ] Some remaining IC->LW renames for commands, documentation, and repository directories (WeeChat channel/adapter, DarkIRC, Gotify tool, connection protocol names) — Done in `501f9c92`+`031b1f78`: dirs renamed with 1.1.9-only compat symlinks (`ironclaw_weechat_wss`, `darkirc_channel_for_ironclaw`); subprotocol now `lunarwing-agent-v1` with dual-accept legacy alias (drop offer in 1.2.0); completions regenerated; internal env vars dual-write LUNARWING_*/IRONCLAW_*. Deferred pending org decisions: nearai artifact URLs/installer allowlist, nearaidev Docker Hub CI images, release-plz owner guard, GCP deploy path. codex4lunarwing left for item #3; nearai provider refs for item #4; experimental TZ proxy files for item #6.
3. [ ] Remove deprecated Codex external worker from project
4. [ ] Remove support for all (or at least, some of) the other random unsupported LLM providers
5. [ ] Remove rest of non-LunarWing third party extensions/tools/skills from default installation
6. [ ] Drop support for the custom TensorZero proxy (toggle off existing, default-disabled on new)
7. [ ] Per-tenant WeeChat health-glob gate (fix the flap /`render-units` footgun)
8. [ ] Enhance Onboarding Process for new users and fresh tenants with an interactive version of multi admin setup
9. [ ] Related to the above, deprecate or update legacy setup scripts
10. [ ] Remove/archive stale documentation
11. [ ] Update outdated documentation
12. [ ] Further re-organization of repository documentation
13. [ ] Self-Healing capability expansion, decided to defer this (find the missing mysterious 1.1.8 self healing expansion doc first)
14. [ ] Bump crate versions to 1.1.9
15. [ ] Ensure all relevant crates are bumped to 1.1.9
16. [ ] Update repo root-level README.md — release-notes link fixed (v1.1.7→v1.1.8, broken root path → docs/releases/), DarkIRC hard-disable/opt-in noted (intro + Features section), worker-count language reconciled (nanocode/pebble/opencode external + built-in/sandbox), Agent SSH Harness v1.1.8 tooling completion noted, new "Upgrading & Migration" section added (kawarimi + legacy upgrade tooling, all links verified). Community button (#28) deferred pending maintainer design input.
17. [ ] Update ROADMAP file to reflect accuracy
18. [ ] Run all cargo tests — full`--all-features --no-fail-fast` run: lib 4087 passed/0 failed/4 ignored; all integration binaries + doctests pass except the 6 known-deferred (4`multi_tenant_system_prompt` architectural, 2`e2e_advanced_traces` bootstrap-greeting). See`docs/proposals/CARGO_TESTS_FIX.md`.
19. [ ] Fix any remaining broken cargo tests and ensure updated documentation. Create (or rewrite) new tests if necessary. then re-run cargo tests to ensure — Fixed the 3 stale`lib` failures this cycle:`registry::embedded::tests::test_load_embedded_parses` (github→ssh sentinel),`cli::tests::test_help_output` +`test_long_help_output` (accepted rebranded insta snapshots). Lib re-run: 4087 passed/0 failed. The 6 remaining failures are documented known-deferred (architectural / harness), not regressions.
20. [ ] Perform successful upgrade in place route with legacy upgrade harness. Document legacy upgrade harness success and plan unified upgrade harness v3/v4
21. [ ] Run automated testing scripts if still relevant
22. [ ] Need a full extensive test using testing_guide and other testing scripts (if they are still relevant) See docs/guides/TESTING_GUIDE.md and ic/scripts/release-test.sh
23. [ ] Retest kawarimi tenant migration (export/import full process)
24. [ ] Full integrated testing (makes it easier to use kawarimi tenant for this item actually)
25. [ ] Write up FIRST DRAFT release notes (at root of repo) for v1.1.9 explaining all changes since v1.1.8 as well as revising and including an ACCURATE VERSION OF `known issues list`
26. [ ] Go over every single section of first draft of release notes (at root of repo) to correct all sections since information is now outdated (only after #25)
27. [ ] Update release date in release notes prior to last two steps below
28. [ ] Create new branch to correspond with releases
29. [ ] Create GH release tag and add release notes to it like other releases already have

---

