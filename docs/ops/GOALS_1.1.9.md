# PRE-RELEASE CHECKLIST for 1.1.9 Codename `Kiyome きよめ`
**Open TODOs (1.1.9) — To be done before release**

See Issue:
https://github.com/LunarWingOrg/lunarwing/issues/140


### Helps to do items in order (generally)

1. [x] Finalize goals
2. [ ] Some remaining IC->LW renames for commands, documentation, and repository directories (WeeChat channel/adapter, DarkIRC, Gotify tool, connection protocol names) — Done in `501f9c92`+`031b1f78`: dirs renamed with 1.1.9-only compat symlinks (`ironclaw_weechat_wss`, `darkirc_channel_for_ironclaw`); subprotocol now `lunarwing-agent-v1` with dual-accept legacy alias (drop offer in 2.0.0); completions regenerated; internal env vars dual-write LUNARWING_*/IRONCLAW_*. Deferred pending org decisions: nearai artifact URLs/installer allowlist, nearaidev Docker Hub CI images, release-plz owner guard, GCP deploy path. codex4lunarwing (item#7); nearai provider refs for item #8 or item #10; experimental TZ proxy (#10) - Ensure all is documented
3. [ ] test a fresh tenant on systemd machine with all the bells and whistles (darkirc, all external workers, etc). document any failures/issues (do some of the other stuff first, do this multiple times)
4. [ ] re-test changes with fresh tenant on openrc machine with all the bells and whistles. document any failures/issues (do some of the other stuff first, do this multiple times)
5. [ ] test with 1.1.7/1.1.8 (or lower) tenant -> in place upgrade on systemd machine using in-place upgrade feature of mt-admin-setup. document any failures/issues (do some of the other stuff first, do this multiple times)
6. [ ] test with 1.1.7/1.1.8 (or lower) tenant -> in place upgrade on openrc machine using in-place upgrade feature of mt-admin-setup. document any failures/issues (do some of the other stuff first, do this multiple times)
7. [x] Remove deprecated Codex external worker from project
8. [x] Remove support for all (or at least, some of) the other random unsupported LLM providers
9. [x] Remove the following non-LunarWing third party skills from default installation: linear, github
10. [x] Drop support for the custom TensorZero proxy (toggle off existing, default-disabled on new)
11. [ ] Enhance Onboarding Process for new users and fresh tenants with an interactive version of multi admin setup (still kind of an in-planning stage thing but want local http web gui and/or interactive cli application for this - Current plan is at docs/proposals/MT-ONBOARDING-CLI.md )
12. [ ] Related to the above, deprecate or update legacy setup scripts
13. [x] Remove/archive stale documentation
14. [x] Ensure that references in documentation which refer to 1.2.0 correctly mention 2.0.0 - 1.2.0 will be 2.0.0 from now on
15. [x] Further updating and re-organization of repository documentation
16. [x] Self-Healing capability expansion, decided to defer this (find the missing mysterious 1.1.8 self healing expansion doc first)
17. [x] Bump crate versions to 1.1.9
18. [ ] Ensure all relevant crates are bumped to 1.1.9 and build works properly
19. [ ] Update repo root-level README.md
20. [ ] Update ROADMAP file to reflect accuracy
21. [ ] Run all cargo tests — full`--all-features --no-fail-fast` run: lib 4087 passed/0 failed/4 ignored; all integration binaries + doctests pass except the 6 known-deferred (4`multi_tenant_system_prompt` architectural, e2e_advanced_traces` bootstrap-greeting). See`docs/proposals/CARGO_TESTS_FIX.md`.
22. [ ] Fix any remaining broken cargo tests and ensure updated documentation. Create (or rewrite) new tests if necessary. then re-run cargo tests to ensure — Fixed the 3 stale`lib` failures this cycle:`registry::embedded::tests::test_load_embedded_parses` (github→ssh sentinel),`cli::tests::test_help_output` +`test_long_help_output` (accepted rebranded insta snapshots). Lib re-run: 4087 passed/0 failed. The 6 remaining failures are documented known-deferred (architectural / harness), not regressions.
23. [ ] Plan unified upgrade harness v3/v4
24. [ ] Run automated testing scripts if still relevant. If not, bring them up to speed and document properly
25. [ ] Need a full extensive test using testing_guide and other testing scripts (if they are still relevant) See docs/guides/TESTING_GUIDE.md and ic/scripts/release-test.sh
26. [ ] Retest kawarimi tenant migration (export/import full process, incorporate early numbers for this too when performing full range of tests, i.e. a 1.1.8 or 1.1.7 tenant or even lower version kawarimi'd to 1.1.9 pre-release build)
27. [ ] Full integrated testing (makes it easier to use kawarimi tenant for this item actually)
28. [ ] Write up FIRST DRAFT release notes (at root of repo) for v1.1.9 explaining all changes since v1.1.8 as well as revising and including an ACCURATE VERSION OF `known issues list`
29. [ ] Go over every single section of first draft of release notes (at root of repo) to correct all sections since information is now outdated (only after #28)
30. [ ] Update release date in release notes prior to last two steps below
31. [ ] Create new branch to correspond with releases
32. [ ] Create GH release tag and add release notes to it like other releases already have
33. [ ] Maintain 1.1.9.X going forward as stable supported build. Backport easy high priority bug fixes to it. The next release after 1.1.9 is the 2.0.0 release which will overhaul several systems

---

