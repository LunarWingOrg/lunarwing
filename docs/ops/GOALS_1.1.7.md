# PRE-RELEASE CHECKLIST for 1.1.7 Codename `Takamaru (タカ丸)`
**Open TODOs (1.1.7) — To be done before release**

### Helps to do items in order (generally)

1. [x] finish xmpp improvements for file transfers
2. [x] finish kers and lunarvision improvements
3. [x] finish improvements to routines
4. [x] Bump crate versions to 1.1.7
5. [x] Ensure all relevant crates are bumped to 1.1.7
6. [x] Update stale documentation, including repo root-level README.md
7. [x] Update ROADMAP file to reflect accuracy
8. [x] test routine improvements
9. [x] test xmpp improvements
10. [x] test ssh agent
11. [x] test kers/lunarvision improvements (on diff machine with 4090 or 5090)
12. [ ] Run all cargo tests
13. [ ] Fix any remaining broken cargo tests and ensure updated documentation. Create (or rewrite) new tests if necessary
14. [ ] Retest kawarimi tenant migration since NEW database migration is needed now since 1.1.6 (Use Starforce to test) 
15. [x] Perform successful upgrade in place route with legacy upgrade harness. Document legacy upgrade harness success and plan unified upgrade harness v3
16. [x] Run automated testing scripts if still relevant
17. [x] Need a full extensive test using testing_guide and other testing scripts. See docs/guides/TESTING_GUIDE.md and ic/scripts/release-test.sh
18. [x] Finish testing external worker enhancements for systemd/openrc hosts. see docs/proposals/SESSION-AUDIT-MT-DARKIRC-EWE-2026-06-23.md
19. [x] Finish testing darkirc enhancements for systemd/openrc hosts. see docs/proposals/SESSION-AUDIT-MT-DARKIRC-EWE-2026-06-23.md
20. [x] Full integrated testing
21. [x] fix problems. more testing
22. [x] Write up FIRST DRAFT release notes (at root of repo) for v1.1.7 explaining all changes since v1.1.6 as well as revising and including an ACCURATE VERSION OF `known issues list`
23. [x] Go over every single section of first draft of release notes (at root of repo) to correct all sections since information is now outdated (only after #22)
24. [ ] Update release date in release notes
25. [ ] Create new branch to correspond with releases
26. [ ] Create GH release tag and add release notes to it like other releases already have

---

