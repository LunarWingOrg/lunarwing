# PRE-RELEASE CHECKLIST for 1.1.8 Codename `Unknown`
**Open TODOs (1.1.8) — To be done before release**

### Helps to do items in order (generally)

1. [ ] Finalize goals
2. [x] rm gh extension and verify it does not show up
3. [x] rm default mcps and verify they do not show up on fresh installation
4. [x] ssh agent adjustments (option #2 and #3 and hardening)
5. [x] Agent SSH Rust Tool
6. [x] Agent SSH WASM TOOL
7. [x] Self-Healing capability expansion (find the missing mysterious 1.1.8 self healing expansion doc first)
8. [ ] add new external worker, opencode. trim nc 1st
9. [ ] test add-tenant and add-tenants enhancements. xmpp_jid_from, llm_model, gateway-host. also interactive onboarding in 1.1.8 or 1.1.9 - make note of decision later
10. [x] see what else we can do from roadmap planned for 1.1.9 a little earlier
11. [x] darkirc multi-tenant fix to make actually disabled and NOT BUILT unless enabled and build-darkirc flag also enabled
12. [x] finish improvements to routines - See docs/proposals/ROUTINE_ENGINE_IMPROVEMENTS.md
13. [x] Bump crate versions to 1.1.8
14. [x] Ensure all relevant crates are bumped to 1.1.8
15. [ ] Update stale documentation, including repo root-level README.md
16. [ ] Update ROADMAP file to reflect accuracy
17. [ ] Run all cargo tests
18. [ ] Fix any remaining broken cargo tests and ensure updated documentation. Create (or rewrite) new tests if necessary. then re-run cargo tests to ensure
19. [ ] Retest kawarimi tenant migration
20. [ ] Perform successful upgrade in place route with legacy upgrade harness. Document legacy upgrade harness success and plan unified upgrade harness v3
21. [ ] Run automated testing scripts if still relevant
22. [ ] Need a full extensive test using testing_guide and other testing scripts. See docs/guides/TESTING_GUIDE.md and ic/scripts/release-test.sh
23. [ ] Full integrated testing (makes it easier to use kawarimi tenant for this)
24. [ ] Write up FIRST DRAFT release notes (at root of repo) for v1.1.8 explaining all changes since v1.1.7 as well as revising and including an ACCURATE VERSION OF `known issues list`
25. [ ] Go over every single section of first draft of release notes (at root of repo) to correct all sections since information is now outdated (only after #24)
26. [ ] make cool community button for readme. I have some unique idea about this  (see #15)
27. [ ] Update release date in release notes prior to last two steps below
28. [ ] Create new branch to correspond with releases
29. [ ] Create GH release tag and add release notes to it like other releases already have

---

