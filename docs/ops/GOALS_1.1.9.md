# PRE-RELEASE CHECKLIST for 1.1.9 Codename `Kiyome きよめ`
**Open TODOs (1.1.9) — To be done before release**

### Helps to do items in order (generally)

1. [ ] Finalize goals
2. [x] IC->LW rename cleanup for active commands, documentation, repository directories, CI, and registry surfaces. Current status: WebSocket subprotocol is `lunarwing-agent-v1` with legacy `ironclaw-agent-v1` still accepted for the 1.1.9 compatibility window; dropping that legacy offer is deferred to 2.0.0 and tracked in `docs/ops/ROADMAP_2026.md`. Shell completions are generated for `lunarwing`; internal env vars prefer `LUNARWING_*` while still accepting or dual-writing required `IRONCLAW_*` aliases for upgraded tenants. Registry manifests no longer carry prebuilt artifact URLs and affected extensions are source-build-only. the release-plz LunarWing Cloud owner guard is gone; obsolete GCP VM bootstrap paths are removed from active workflows. Remaining LunarWing Cloud provider references are intentional live provider/config names, not stale branding. Deferred follow-up: final legacy protocol/env/repo compatibility removal in 2.0.x.
3. [ ] test a fresh tenant on systemd machine with all the bells and whistles (darkirc, all external workers, etc). document any failures/issues (do some of the other stuff first, do this multiple times)
4. [ ] re-test changes with fresh tenant on openrc machine with all the bells and whistles. document any failures/issues (do some of the other stuff first, do this multiple times)
5. [ ] test with 1.1.7/1.1.8 (or lower) tenant -> in place upgrade on systemd machine using in-place upgrade feature of mt-admin-setup. document any failures/issues (do some of the other stuff first, do this multiple times)
6. [ ] test with 1.1.7/1.1.8 (or lower) tenant -> in place upgrade on openrc machine using in-place upgrade feature of mt-admin-setup. document any failures/issues (do some of the other stuff first, do this multiple times)
7. [x] Remove deprecated Codex external worker from project
8. [x] Remove support for all (or at least, some of) the other random unsupported LLM providers
9. [x] Remove the following non-LunarWing third party skills from default installation: linear, github
10. [x] Drop support for the custom TensorZero proxy (toggle off existing, default-disabled on new)
11. [x] Enhance Onboarding Process for new users and fresh tenants with an interactive version of multi admin setup (still kind of an in-planning stage thing but want local http web gui and/or interactive cli application for this - Current plan is at docs/proposals/MT-ONBOARDING-CLI.md ) — **CLI scaffold shipped in `lunarwing_mt_onboard/`**: interactive questionary+rich flow, `TenantConfig` JSON save/resume, thin wrapper over `mt-admin.sh` (add→build→start), post-start verify, 19 unit tests, smoke-test script (`ic/scripts/test-mt-onboard.sh`), `setup-instance.sh` deprecation banner (item #12). Phase 2 web UI still deferred.
12. [x] Related to the above, deprecate or update legacy setup scripts
13. [x] Remove/archive stale documentation
14. [x] Ensure that references in documentation which refer to 1.2.0 correctly mention 2.0.0 - 1.2.0 will be 2.0.0 from now on
15. [x] Further updating and re-organization of repository documentation
16. [x] Self-Healing capability expansion, decided to defer this to 2.0.0 (find the missing mysterious 1.1.8 self healing expansion doc first)
17. [x] Refine defaults of new mt admin interactive program 
18. [x] Refine deploy workspace defaults for agents
19. [ ] fix warnings in clippy and cargo. So: cargo warnings look fixed for cargo check, but the clippy warnings not fixed. the branch rarity/item-19-20260706-2000 with PR: https://github.com/LunarWingOrg/lunarwing/pull/186 still has the same 5 clippy warnings.
20. [x] Bump crate versions to 1.1.9
21. [x] Ensure all relevant crates are bumped to 1.1.9 and build works properly
22. [x] Update repo root-level README.md
23. [x] Update ROADMAP file to reflect accuracy
24. [ ] Purge other unecessary code from repo _thr
25. [x] Run all cargo tests — full `--all-features --no-fail-fast` run: lib 4087 passed/0 failed/4 ignored; all integration binaries + doctests pass except the 6 known-deferred `multi_tenant_system_prompt` architectural, e2e_advanced_traces `bootstrap-greeting` See `docs/proposals/CARGO_TESTS_FIX.md`. Fix any remaining broken cargo tests and ensure updated documentation. Create (or rewrite) new tests if necessary. then re-run cargo tests to ensure — Fixed the 3 stale `lib` failures this cycle: `registry::embedded::tests::test_load_embedded_parses` (github→ssh sentinel), `cli::tests::test_help_output` + `test_long_help_output` (accepted rebranded insta snapshots). Lib re-run: 4087 passed/0 failed. The 6 remaining failures are documented known-deferred (architectural / harness), not regressions.
26. [x] Cherrypick item-25-20260707-0500
27. [x] Plan unified upgrade harness (combine legacy upgrade with regular upgrade script if avail) v3/v4
28. [ ] Fix these issues with kawarimi: https://github.com/LunarWingOrg/lunarwing/issues/161
29. [ ] Address items from this issue: https://github.com/LunarWingOrg/lunarwing/issues/180
30. [ ] Address items from this issue: https://github.com/LunarWingOrg/lunarwing/issues/140
31. [ ] Run automated testing scripts if still relevant. If not, bring them up to speed and document properly
32. [ ] Need a full extensive test using testing_guide and other testing scripts (if they are still relevant) See docs/guides/TESTING_GUIDE.md and ic/scripts/release-test.sh
33. [ ] Retest kawarimi tenant migration (export/import full process, incorporate early numbers for this too when performing full range of tests, i.e. a 1.1.8 or 1.1.7 tenant or even lower version kawarimi'd to 1.1.9 pre-release build)
34. [ ] Full integrated testing (makes it easier to use kawarimi tenant for this item actually)
35. [ ] Write up FIRST DRAFT release notes (at root of repo) for v1.1.9 explaining all changes since v1.1.8 as well as revising and including an ACCURATE VERSION OF `known issues list`
36. [ ] Go over every single section of first draft of release notes (at root of repo) to correct all sections since information is now outdated 
37. [ ] Update release date in release notes prior to last two steps below
38. [ ] Create new branch to correspond with releases
39. [ ] Create GH release tag and add release notes to it like other releases already have
40. [ ] Maintain 1.1.9.X going forward as stable supported build. Backport easy high priority bug fixes to it. The next release after 1.1.9 is the 2.0.0 release which will overhaul several systems

---
