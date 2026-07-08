# AGENT PRE-RELEASE CHECKLIST for 1.1.9 Codename `Kiyome きよめ`
**Open TODOs (1.1.9) — To be done before release**

### Helps to do items in order (generally)

NOTE: TODO: edit dev autonomous loop routine to use this file. ensure that checkbox is checked off in the corresponding branch before committing and pushing and opening pr

1. [x] Ensure references to 1.2.0 in the code and documentation are replaced by 2.0.0 (where applicable only of course)
2. [x] Prepare fully detailed report detailing all remaining nearai/near/ironclaw/nearcloud/nearagent/near::agent/telegram references in the source code and documentation. put it in docs/internal as a new markdown document
3. [ ] There are old automated testing scripts in this repo. Bring them up to date (within reason - totally fine if stuff is missing; just document what is)
4. [ ] The new mt admin setup cli wrapper needs to have upgrade in place functionality. enhance it to make this possible. or if it has it already by this point, verify it has it already. The human will test later so there's no need to run any tests at this time.
5. [ ] Go thru all the issues and make a report in docs/ops of the status of each issue and see if each is solved already or not https://github.com/LunarWingOrg/lunarwing/issues
6. [ ] Update README.md - purge outdated sections. include the new MT Admin CLI wrapper into the README.md as part of a new up to date getting started section
7. [ ] Write up FIRST DRAFT release notes (at root of repo) for v1.1.9 explaining all relevant changes since v1.1.8 as well as revising and including an ACCURATE VERSION OF `known issues list`. Use previous release notes in docs/release for reference as to how to write up this document.

---
