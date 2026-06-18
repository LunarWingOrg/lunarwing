# PRE-RELEASE CHECKLIST for 1.1.4 Codename `Phoenix`
**Open TODOs (1.1.4) — Feature Release**
1. [x] Finalize goals list
2. [x] Bump crate versions to 1.1.4 and subsequently run all cargo tests
3. [x] Continue to make improvements to health check and self healing
4. [x] Continue to test Healthcheck and Self-Healing Enhancements
5. [x] Test all changes related to ICHC on an existing **Systemd** development VM - adding new tenant *(✓ Arch VM: fresh tenant `springfeather` clean add → build → start → **all-green ICHC (8/8 incl. nanocode + pebble workers)**; F1/F2/F3 validated live; F8/F10/F12 found + fixed. See `docs/bugs/SYSTEMD-MT-1.1.4-ISSUES.md`)*
6. [ ] Test all changes related to ICHC on an existing **OpenRC/Gentoo** development VM - adding new tenant
7. [ ] go over issues from OPENRC-MT-1.1.4-ISSUES.md and anything else pending for #6
8. [ ] Test all changes related to ICHC on a NEW **Systemd** development VM with same configuration - adding new tenants
9. [ ] Test all changes related to ICHC on a NEW **OpenRC/Gentoo** development VM with same configuration - adding new tenants
10. [ ] Test all changes on existing live tenant of MT PROD machine with tenant on version > 1.1.0 - via direct upgrade or migration (only after #5-#9 are done)
11. [ ] Test all changes on new tenant of MT PROD machine (only after #5-#9 are done)
12. [ ] Run automated testing scripts
13. [ ] Need a full extensive test using my testing_guide and other testing scripts. can also try docs/guides/TESTING_GUIDE.md and ic/scripts/release-test.sh
14. [x] Record all Systemd MT / ICHC issues found during testing and propose fixes (tracked in `docs/bugs/SYSTEMD-MT-1.1.4-ISSUES.md`)
15. [x] Fix the provisioning code so new tenants are no longer left half-baked (F1–F6, F8, F10, F12 fixed; adversarial-reviewed; ICHC suite 229/229) — **verified by provisioning a brand-new tenant end-to-end**: clean add → build → start → **all-green ICHC (8/8 incl. nanocode + pebble workers)**. Remaining (minor): F7 (telegram unsupported, yanked dep), F11 (nanocode ~6 GB image distribution — perf follow-up); F9 investigated → invalid. See `docs/bugs/SYSTEMD-MT-1.1.4-ISSUES.md`
16. [x] Write up release notes (at root of repo) for v1.1.4 explaining all changes since v1.1.3 as well as accurate known issues list
17. [ ] Update release notes (at root of repo) with any minor known issues that may not be fully resolved (after #16)
18. [ ] Create new branch to correspond with release
19. [ ] Create GH release tag and add release notes to it like other releases already have

---
