# Draft

* Pending Cleanup round 3
___
**Open TODOs (1.0.8~) — Feature Release**                                                          
                                                                                                  
1. [ ] Improve the OCR and Image Recognition, LunarVision aka K.E.R.S.                            
2. [ ] Introduce Lunartica for multi-agent coordination (forked Multica; self-hostable FOSS)      
3. [ ] Continue to remove cruft, including some or all unsupported channels. Telegram will be a pain. Start with Discord and Slack.
4. [ ] Begin work on audio input/output interface (no plan yet; needs proper planning; could save it for 1.0.8 or 1.0.9 since 1.0.7 will already add TONs of new features)
5. [ ] bump lunarwing crate version
6. [ ] Migrate at least one file-based libsql instances over to a live MT setup to thoroughly test everything gets migrated successfully
7. [ ] Log OMEMO MUC bug in bugs documentation (discovered 2026-05-12: posting in MUC room triggers ~20 OMEMO fallback spam notices in private chat even when OMEMO disabled for 1:1 JID). There is other bug where processing loop gets stuck sometimes that happens super rarely (only once ever). Log this too.
8. [ ] Ensure all ^previous 1.0.7 checklist items were completed
9. [ ] first iteration of reflex compiler added to staging
10. [ ] test reflex compiler over period of time
11. [ ] test new codex container
12. [ ] Character Lorebooks and profile enhancements. Profile onboarding already added in previous release but adding this to testing suite would be appreciated.
13. [ ] Enhance automated testing scripts. number 11 is related to this.
14. [ ] need a full extensive test using my testing_guide and other testing scripts
15. [ ] Complete tests of everything that was changed since 1.0.6
16. [ ] Write up release notes for v1.0.7 explaining all changes since v1.0.6
17. [ ] Create a new branch to correspond with release
18. [ ] Create GH release tag and add release notes to it like other releases already have


### Possibly postponed for future release

#### To be created
___
##### Feature Branches for v1.1.0 or later+

| Branch | Status | Description |
|--------|--------|-------------|
| `Lunartica` | Not yet merged | Lunartica/Multica bridge WASM tool for task management integration |
| `LunarVoice` | Not yet started | Voice capabilities (TBD) | 1.1.2+
| `IdeasFromDocumentWrench` | Not started except for human delay mode | 1.1.0+
