# PRE-RELEASE CHECKLIST for 1.1.9 Codename `???`
**Open TODOs (1.1.9) — To be done before release**

**TODO: FORMATTING**

### Helps to do items in order (generally)

| Some remaining IC->LW renames for commands, documentation, a
nd repository directories (WeeChat channel/adapter, DarkIRC, G
otify tool, connection protocol names) | v1.1.9 |             
| Remove deprecated Codex external worker from project | v1.1.
9 |                                                           
| Remove support for all (or at least, some of) the other rand
om unsupported LLM providers | v1.1.9 |                       
| Remove rest of non-LunarWing third party extensions/tools/sk
ills from default installation | v1.1.9 |                     
| Drop support for the custom TensorZero proxy (toggle off exi
sting, default-disabled on new) | v1.1.9 |                    
| Per-tenant WeeChat health-glob gate (fix the flap / `render-
units` footgun) | v1.1.9 |                                    
| Enhance Onboarding Process for new users and fresh tenants with an interactive version of multi admin setup | v1.1.9 |    
| Related to the above, deprecate or update legacy setup scripts | v1.1.9 |                                                 
| Remove/archive stale documentation | v1.1.9 |               
| Update outdated documentation | v1.1.9 |                    
| Further re-organization of repository documentation | v1.1.9 |

7. [] Finalize goals
2. [] rm gh extension and verify it does not show up
3. [] rm default mcps and verify they do not show up on fresh installation
4. [] ssh agent adjustments (option #2 and #3 and hardening)
5. [] Agent SSH Rust Tool
6. [] Agent SSH WASM TOOL
7. [] Self-Healing capability expansion, decided to defer this (find the missing mysterious 1.1.8 self healing expansion doc first)
8. [] Add new external worker, opencode. Landed: `opencode4lunarwing/` (Bun/TypeScript bridge + `@opencode-ai/sdk`, `ironclaw-agent-v1` protocol), port registry v10→v11 migration (`opencode_wss`/`opencode_health`), full mt-admin lifecycle (build/configure/start/stop/doctor/status/list), `--with-opencode`, `--opencode-model`/`--opencode-base-url`. Optional Paseo MCP integration wired behind `PASEO_URL`/`PASEO_TOKEN`. Polish follow-ups and repo-doc updates tracked in DEFERRED-2026-07-02-OPENCODE-EXTERNAL-WORKER.md
9. [] Test Opencode external worker properly (might help to update some of the old test scripts too) 
10. [] test add-tenant and add-tenants enhancements. xmpp_jid_from, llm_model, gateway-host. also interactive onboarding in 1.1.8 or 1.1.9 - make note of decision later
11. [] see what else we can do from roadmap planned for 1.1.9 a little earlier
12. [] darkirc multi-tenant fix to make actually disabled and NOT BUILT unless enabled and build-darkirc flag also enabled
13. [] finish improvements to routines - See docs/proposals/ROUTINE_ENGINE_IMPROVEMENTS.md
14. [] Bump crate versions to 1.1.8
15. [] Ensure all relevant crates are bumped to 1.1.8
16. [] Update any stale documentation
17. [] Update repo root-level README.md — release-notes link fixed (v1.1.7→v1.1.8, broken root path → docs/releases/), DarkIRC hard-disable/opt-in noted (intro + Features section), worker-count language reconciled (nanocode/pebble/opencode external + built-in/sandbox), Agent SSH Harness v1.1.8 tooling completion noted, new "Upgrading & Migration" section added (kawarimi + legacy upgrade tooling, all links verified). Community button (#28) deferred pending maintainer design input.
18. [] Update ROADMAP file to reflect accuracy
19. [] Run all cargo tests — full `--all-features --no-fail-fast` run: lib 4087 passed/0 failed/4 ignored; all integration binaries + doctests pass except the 6 known-deferred (4 `multi_tenant_system_prompt` architectural, 2 `e2e_advanced_traces` bootstrap-greeting). See `docs/proposals/CARGO_TESTS_FIX.md`.
20. [] Fix any remaining broken cargo tests and ensure updated documentation. Create (or rewrite) new tests if necessary. then re-run cargo tests to ensure — Fixed the 3 stale `lib` failures this cycle: `registry::embedded::tests::test_load_embedded_parses` (github→ssh sentinel), `cli::tests::test_help_output` + `test_long_help_output` (accepted rebranded insta snapshots). Lib re-run: 4087 passed/0 failed. The 6 remaining failures are documented known-deferred (architectural / harness), not regressions.
21. [] Retest expo
22. [] Perform successful upgrade in place route with legacy upgrade harness. Document legacy upgrade harness success and plan unified upgrade harness v3
23. [] Run automated testing scripts if still relevant
24. [] Need a full extensive test using testing_guide and other testing scripts (if they are still relevant) See docs/guides/TESTING_GUIDE.md and ic/scripts/release-test.sh
25. [] Retest kawarimi tenant migration (export/import full process)
26. [] Full integrated testing (makes it easier to use kawarimi tenant for this item actually)
27. [] Write up FIRST DRAFT release notes (at root of repo) for v1.1.8 explaining all changes since v1.1.7 as well as revising and including an ACCURATE VERSION OF `known issues list`
28. [] Go over every single section of first draft of release notes (at root of repo) to correct all sections since information is now outdated (only after #27)
29. [] make cool community button for readme. I have some unique idea about this — Added IRC chat badge (`#lunarwing` on Libera, links to web chat) in lunarpunk teal/black matching the existing zread badge aesthetic. Placed in both the top badge cluster and the Community section.
30. [] Update release date in release notes prior to last two steps below
31. [ ] Create new branch to correspond with releases
32. [ ] Create GH release tag and add release notes to it like other releases already have

---

