# suggested

 Release-blocking / correctness                                                
  1. Propagate the 4 health-stack bug fixes to the canonical release/staging branch (and the systemd+Docker prod leg). The lock-fd leak, dead notifier,
  lost-escalation-state, and OpenRC env-file fixes live in the shared stack — the systemd leg has the env-file bug latent and the notifier/escalation bugs
  active. Make sure they don't stay stranded on the vm-ic branches.             
  2. Wire the health/self-heal pipeline for systemd, not just OpenRC. ensure_health_pipeline() is OpenRC-only; the prod leg gets the hardened scripts but no
  auto-scheduling. Render a systemd .timer/.service (or user timer) so G1/G2 close for systemd too.
  3. Finish the GOALS_1.1.4 pre-release checklist: bump crate versions 1.1.3 → 1.1.4 (workspace + 5 WASM channel crates), then run the full automated sweep
  (ic/scripts/release-test.sh, cargo test/--features integration, clippy/fmt, e2e) — we validated the self-heal stack live but not the broader suite.

  Validation / hardening (escalation is now live)                               
  4. One definitive live escalation→page demo — stage a throwaway unit (respawn disabled + always-fail command) so a real OpenRC restart cleanly fails →
  escalate → Gotify, closing the single staging gap.                            
  5. Reboot re-validation of the full stack now that the fcron health schedule, escalation, and weechat-on-all are in place (earlier reboot test predated
  them).                                                                        
  6. Escalation robustness (CHAOS_FOLLOWUP P0/R4/R5): escalation rate-limit/cooldown (avoid Gotify floods), truncated-state.json recovery, and an
  escalation-script timeout — worth doing now that pages go out for real.       

  Cleanliness / config                                                          
  7. Resolve WeeChat end-to-end: it's half-on (services run but loop-reconnect — relay unconfigured). Either configure the relay per tenant (Quickstart Part 2)
  or prune it, per the consistency proposal.                                    
  8. Prune/configure the noisy WASM channels (telegram/darkirc/multica error every poll with no token/daemon) — execute the pruning proposal to quiet the logs.
  9. Document the pipeline in the production docs: MULTITENANCY-PRODUCTION.md + a health.env toggles reference (SELF_HEAL_REMEDY_LOGICAL, HEALTHCHECK_NOTIFY,
  the probe toggles, MAX_REPORT_AGE) currently only live in the MT-GENTOO doc + commit messages.

  Enhancement                                                                   
  10. Per-tenant app-level health (Pattern C): the host-global pipeline checks service liveness only; add a per-tenant deep check (curl each gateway's
  /api/gateway/status channel health) for true app-level self-heal.  
