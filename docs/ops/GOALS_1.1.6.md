# PRE-RELEASE CHECKLIST for 1.1.6 Codename `Reversable Extinction`
**Open TODOs (1.1.6) — Multi-Feature Release**

1. [x] Render + register babysitter -sup OpenRC units for PG, nanocode, pebble containers
2. [ ] Finish plan for external worker enhancements, including full testing and validation
2. [x] Helper script installed to /usr/local/sbin/ via ensure_babysitter_helper() in mt-admin.sh
3. [x] Babysitter stop ordering: deregister -sup BEFORE stopping container (prevents respawn race)
4. [x] Watchdog cleanup guarded: does not remove helper while -sup units exist
5. [x] PG status() uses pg_isready health check (container running AND DB accepting connections)
6. [ ] Fault-injection test: podman kill → verify <2s respawn via supervise-daemon (no automated test exists for this currently)
7. [ ] Fault-injection test: verify crash-loop exhaust → self-heal backstop after respawn_max
8. [ ] Finalize goals list
9. [ ] Bump crate versions to 1.1.6 and subsequently run all cargo tests
10. [ ] Fix broken cargo tests
11. [ ] Test migration route updates since 1.1.5
12. [ ] Test upgrade in place route
13. [ ] Run automated testing scripts
14. [ ] Need a full extensive test using testing_guide and other testing scripts. See docs/guides/TESTING_GUIDE.md and ic/scripts/release-test.sh
15. [ ] Write up release notes (at root of repo) for v1.1.6 explaining all changes since v1.1.5 as well as accurate known issues list
16. [ ] Update release notes (at root of repo) with any minor known issues that may not be fully resolved (after #15)
17. [ ] Create new branch to correspond with release
18. [ ] Create GH release tag and add release notes to it like other releases already have

---

