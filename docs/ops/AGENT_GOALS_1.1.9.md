# AGENT PRE-RELEASE CHECKLIST for 1.1.9.0 Codename `Kiyome (きよめ/清め)`
**Open TODOs (1.1.9.0) — To be done before release**

### Helps to do items in order (generally)

NOTE: TODO: edit dev autonomous loop routine to use this file. ensure that checkbox is checked off in the corresponding branch before committing and pushing and opening pr

1. [x] Ensure references to 1.2.0 in the code and documentation are replaced by 2.0.0 (where applicable only of course)
2. [x] Prepare fully detailed report detailing all remaining nearai/near/ironclaw/nearcloud/nearagent/near::agent/telegram references in the source code and documentation. put it in docs/internal as a new markdown document
3. [x] There are old automated testing scripts in this repo. Bring them up to date (within reason - totally fine if stuff is missing; just document what is)
4. [x] The new mt admin setup cli wrapper needs to have upgrade in place functionality. enhance it to make this possible. or if it has it already by this point, verify it has it already. The human will test later so there's no need to run any tests at this time.
5. [x] Go thru all the issues and make a report in docs/ops of the status of each issue and see if each is solved already or not https://github.com/LunarWingOrg/lunarwing/issues
6. [x] inspect status of cargo crates and create documented report of any crates that might still need to be updated
7. [x] inspect recent changes made to cargo crates sinced 1.1.8 and attempt to identify any problems in the builds of the binaries OR the WASM tools and channels. Document all findings to a document in docs.
8. [ ] Go through all documents under architecture directory in docs/ and update all outdated documentation. Then, consolidate documents.
9. [ ] Go through all documents under bugs directory in docs/ and update all outdated documentation. Then, consolidate documents.
10. [ ] Go through all documents under guides directory in docs/ and update all outdated documentation. Then, consolidate documents.
11. [ ] Go through all documents under internal directory in docs/ and update all outdated documentation. Then, consolidate documents.
12. [ ] Go through all documents under proposals directory in docs/ and update all outdated documentation. Then, consolidate documents.
13. [ ] Go through all documents under reviews directory in docs/ and update all outdated documentation. Then, consolidate documents.
14. [ ] Update README.md - purge all outdated sections. Include the new MT Admin CLI wrapper into the README.md as part of the new, improved up to date getting started section. You may also refer to the actual mt admin setup script which the new CLI wrapper references since it offers far greater control.
15. [x] Write up FIRST DRAFT release notes (at root of repo) for v1.1.9.0 (note the version schema change) explaining all relevant changes since v1.1.8 as well as revising and including an ACCURATE VERSION OF `known issues list`. Use previous release notes in docs/release for reference as to how to write up this document. The codename for this release is: `Kiyome (きよめ/清め)` - The file you write will be RELEASE-v1.1.9.0.md and should be written to the ROOT of the repo.
16. [ ] Improve accuracy of RELEASE-v1.1.9.0.md (from item #15)

---

