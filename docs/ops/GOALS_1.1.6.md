# PRE-RELEASE CHECKLIST for 1.1.6 Codename `Reversible Extinction`
**Open TODOs (1.1.6) — To be done before release**

### Helps to do items in order (generally)

1. [x] Render + register babysitter -sup OpenRC units for PG, nanocode, pebble containers
2. [x] Finish plan for external worker enhancements, including full testing and validation
3. [x] Helper script installed to /usr/local/sbin/ via ensure_babysitter_helper() in mt-admin.sh
4. [x] Babysitter stop ordering: deregister -sup BEFORE stopping container (prevents respawn race)
5. [x] Watchdog cleanup guarded: does not remove helper while -sup units exist
6. [x] PG status() uses pg_isready health check (container running AND DB accepting connections)
7. [x] Update stale documentation
8. [x] Update ROADMAP file to reflect accuracy
9. [x] Fault-injection test: podman kill → verify <2s respawn via supervise-daemon
10. [x] Fault-injection test: verify crash-loop exhaust → self-heal backstop after respawn_max
11. [x] Finalize goals list
12. [x] Bump crate versions to 1.1.6
13. [x] Run all cargo tests
14. [x] Fix any remaining broken cargo tests and ensure updated documentation. Create (or rewrite) new tests if necessary
15. [x] Test migration route updates since 1.1.5
16. [x] Perform successful upgrade in place route with legacy upgrade harness. Document legacy upgrade harness success and plan unified upgrade harness v2
17. [x] Run automated testing scripts
18. [x] Need a full extensive test using testing_guide and other testing scripts. See docs/guides/TESTING_GUIDE.md and ic/scripts/release-test.sh
19. [ ] Finish testing external worker enhancements for systemd/openrc hosts. see docs/proposals/SESSION-AUDIT-MT-DARKIRC-EWE-2026-06-23.md
20. [ ] Finish testing darkirc enhancements for systemd/openrc hosts. see docs/proposals/SESSION-AUDIT-MT-DARKIRC-EWE-2026-06-23.md
21. [ ] full integrated test using new plan
22. [ ] Write up release notes (at root of repo) for v1.1.6 explaining all changes since v1.1.5 as well as accurate known issues list
23. [ ] Update release notes (at root of repo) with any minor known issues that may not be fully resolved (only after #22)
24. [ ] Create new branch to correspond with release
25. [ ] Create GH release tag and add release notes to it like other releases already have

---

