# Roadmap

## Formerly: Features and changes deferred to future releases

Items are grouped to respect the release cadence (`docs/ops/RELEASE_CADENCE.md`): odd-numbered releases focus on bug fixes / security / polish / cleanup, even-numbered releases focus on features, and major versions such as 1.2.0 or 1.3.0 will typically include massive overhauls of existing systems.

                                                                                                                                                               
| Feature | Target |                                                                                                                                           
|---------|--------|                                                                                                                                           
| Remaining migration/upgrade work (live-validate the rootless-adopt v1.1.0 → v1.1.4 `upgrade-tenant.sh`; extend `upgrade-tenant-version.sh` to source versions
 older than v1.0.9; spot-check OMEMO/secret continuity on a migration) | v1.1.6 |                                                                              
| XMPP OMEMO MUC fallback fix *(was targeted v1.1.5 — slipped)* | v1.1.6 |                                                                                     
| XMPP file transfer — remaining polish (live e2e validation, optional SSRF guard, further hardening) *(was targeted v1.1.5 — slipped)* | v1.1.6 |             
| Lunarvision K.E.R.S. system setup polishing *(was targeted v1.1.5 — slipped)* | v1.1.6 |                                                                     
| Per-tenant WeeChat health-glob gate (fix the flap / `render-units` footgun) | v1.1.6 |                                                                       
| Rootless Podman per-tenant container parent-supervision babysitter (`podman wait`, crash-recovery latency) | v1.1.6 |                                        
| External Worker planned enhancements; Multica bridge/channel refinements; Lunartica UI reskin | v1.1.6 |                                                     
| Drop support for the custom TensorZero proxy (toggle off existing, default-disabled on new); planned input-validation security improvements; remaining `ironc
law` → `lunarwing` renames (WeeChat channel/adapter, Gotify tool) | v1.1.7 |                                                                                   
| Re-add the custom Git WASM workspace tool; TensorZero upgrade + ClickHouse healthcheck test expansion | v1.1.8 |                                             
| v2 engine implementation + LunarWing UI performance overhaul; self-healing expansion | v1.2.0 |                                                              
                                                                                                                                                               
---                                                                                                                                                            

