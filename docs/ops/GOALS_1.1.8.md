# PRE-RELEASE CHECKLIST for 1.1.8 Codename `Unknown`
**Open TODOs (1.1.8) — To be done before release**

### Helps to do items in order (generally)

1. [ ] Finalize goals
2. [x] rm gh extension and verify it does not show up
3. [x] rm default mcps and verify they do not show up on fresh installation
4. [x] ssh agent adjustments (option #2 and #3 and hardening)
5. [x] Agent SSH Rust Tool
6. [x] Agent SSH WASM TOOL
7. [x] Self-Healing capability expansion, decided to defer this (find the missing mysterious 1.1.8 self healing expansion doc first)
8. [x] Add new external worker, opencode. Landed: `opencode4lunarwing/` (Bun/TypeScript bridge + `@opencode-ai/sdk`, `ironclaw-agent-v1` protocol), port registry v10→v11 migration (`opencode_wss`/`opencode_health`), full mt-admin lifecycle (build/configure/start/stop/doctor/status/list), `--with-opencode`, `--opencode-model`/`--opencode-base-url`. Optional Paseo MCP integration wired behind `PASEO_URL`/`PASEO_TOKEN`. Polish follow-ups and repo-doc updates tracked in DEFERRED-2026-07-02-OPENCODE-EXTERNAL-WORKER.md
9. [ ] Test Opencode external worker properly (might help to update some of the old test scripts too) 
10. [ ] test add-tenant and add-tenants enhancements. xmpp_jid_from, llm_model, gateway-host. also interactive onboarding in 1.1.8 or 1.1.9 - make note of decision later
11. [x] see what else we can do from roadmap planned for 1.1.9 a little earlier
12. [x] darkirc multi-tenant fix to make actually disabled and NOT BUILT unless enabled and build-darkirc flag also enabled
13. [x] finish improvements to routines - See docs/proposals/ROUTINE_ENGINE_IMPROVEMENTS.md
14. [x] Bump crate versions to 1.1.8
15. [x] Ensure all relevant crates are bumped to 1.1.8
16. [ ] Update any stale documentation, including repo root-level README.md
17. [ ] Update ROADMAP file to reflect accuracy
18. [ ] Run all cargo tests
19. [ ] Fix any remaining broken cargo tests and ensure updated documentation. Create (or rewrite) new tests if necessary. then re-run cargo tests to ensure
20. [ ] Retest kawarimi tenant migration
21. [ ] Perform successful upgrade in place route with legacy upgrade harness. Document legacy upgrade harness success and plan unified upgrade harness v3
22. [ ] Run automated testing scripts if still relevant
23. [ ] Need a full extensive test using testing_guide and other testing scripts (if they are still relevant) See docs/guides/TESTING_GUIDE.md and ic/scripts/release-test.sh
24. [ ] Full integrated testing (makes it easier to use kawarimi tenant for this item actually)
25. [ ] Write up FIRST DRAFT release notes (at root of repo) for v1.1.8 explaining all changes since v1.1.7 as well as revising and including an ACCURATE VERSION OF `known issues list`
26. [ ] Go over every single section of first draft of release notes (at root of repo) to correct all sections since information is now outdated (only after #25)
27. [ ] make cool community button for readme. I have some unique idea about this  (see #16)
28. [ ] Update release date in release notes prior to last two steps below
29. [ ] Create new branch to correspond with releases
30. [ ] Create GH release tag and add release notes to it like other releases already have

---

