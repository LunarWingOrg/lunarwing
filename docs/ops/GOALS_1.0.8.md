# PRE-RELEASE CHECKLIST

___
**Open TODOs (1.0.8~) — Feature Release**
1. [ ] first iteration of reflex compiler added to staging
2. [ ] Run automated testing scripts. number 11 is related to this.
3. [ ] need a full extensive test using my testing_guide and other testing scripts. can also try docs/guides/TESTING_GUIDE.md and ic/scripts/release-test.sh and ONE MORE TEST SCRIPT I WILL ADD
4. [ ] Complete tests of everything that was changed since 1.0.7 (might help if we generate release notes first)
5. [ ] Write up release notes for v1.0.8 explaining all changes since v1.0.7
6. [ ] Create a new branch to correspond with release
7. [ ] Create GH release tag and add release notes to it like other releases already have

### Possibly postponed for future release

#### To be created
___
##### Feature Branches for v1.1.0 or later+

| Branch | Status | Description |
|--------|--------|-------------|
| `Lunartica` | Not yet merged | Lunartica/Multica bridge WASM tool for task management integration |
[ ] Introduce Lunartica for multi-agent coordination (forked Multica; self-hostable FOSS)      
| `LunarVoice` | Not yet started | Voice capabilities (TBD) | 1.1.2+
[ ] Begin work on audio input/output interface (no plan yet; needs proper planning; could save it for 1.0.8 or 1.0.9 since 1.0.7 will already add TONs of new features)
| `IdeasFromDocumentWrench` | Not started except for human delay mode | 1.1.0+
| `Improve the OCR and Image Recognition, LunarVision aka K.E.R.S.` | ?
[ ] Continue to remove cruft, including some or all unsupported channels. Telegram will be a pain. Start with Discord and Slack
[ ] Migrate at least one file-based libsql instances over to a live MT setup to thoroughly test everything gets migrated successfully
[ ] extensively test new codex container
[ ] extensively test new pebble external worker
[ ] test reflex compiler over LONGER period of time
[ ] Character Lorebooks and profile enhancements. Profile onboarding already added in previous release but adding this to testing suite would be appreciated.
[ ] Enhance automated testing scripts. number 11 is related to this.


###### Mystery:
* Pending Cleanup round 3 (what is this?)
