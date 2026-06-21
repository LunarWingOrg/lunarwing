# PRE-RELEASE CHECKLIST for 1.1.5 Codename `Kawarimi`
**Open TODOs (1.1.5) — Polishing Release**
1. [x] Finalize goals list (see #5)
2. [x] Bump crate versions to 1.1.5 and subsequently run all cargo tests
3. [x] Test migration route — machine migration (`export → import → start`) live-validated on a production tenant (2026-06-20)
4. [x] Test upgrade in place route — *partial:* same-host `upgrade-tenant-version.sh` (v1.0.9 → v1.1.2) live-validated on a production tenant; rootless-adopt `upgrade-tenant.sh` (v1.1.0 → v1.1.4) still pending
5. [x] investigate roadmap to add additional items to goals
6. [x] Run automated testing scripts
7. [x] Need a full extensive test using my testing_guide and other testing scripts. can also try docs/guides/TESTING_GUIDE.md and ic/scripts/release-test.sh
8. [x] Write up release notes (at root of repo) for v1.1.5 explaining all changes since v1.1.4 as well as accurate known issues list
9. [x] Update release notes (at root of repo) with any minor known issues that may not be fully resolved (after #8)
10. [ ] Create new branch to correspond with release
11. [ ] Create GH release tag and add release notes to it like other releases already have

---

