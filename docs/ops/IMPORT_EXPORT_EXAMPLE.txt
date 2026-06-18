testbot state: marker present (rehearsal-20260618-144126), PG running rootful on 10013, and crucially state/xmpp/ (OMEMO store) exists
export's quiesce-then-tar path will actually be exercised

Export worked end-to-end — and live-validated the loopback LLM_BASE_URL policy (http://127.0.0.1:10014/v1 → not carried), DB role/db parsed from
DATABASE_URL, quiesce→consistent OMEMO snapshot, and an 0600 bundle.
import-ready here (read-only, streaming members so no secret values touch disk or the log)

Source-side rehearsal: fully validated.

The untested helper and export-tenant.sh both worked on first run, and the bundle is correct and import-ready

  ┌──────────────────────────────────────────────────┬────────────────────────────────────────────────────────────────────────────────┐                        
  │                      Check                       │                                     Result                                     │                        
  ├──────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────┤                        
  │ Bundle + manifests perms                         │ 0600 root ✓                                                                    │                        
  ├──────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────┤                        
  │ meta.txt                                         │ tenant/version/runtime=podman/pg=lunarwing/postgres ✓                          │                        
  ├──────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────┤                        
  │ SECRETS_MASTER_KEY carried                       │ yes ✓                                                                          │
  ├──────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────┤
  │ LLM_BASE_URL (loopback)                          │ not carried ✓ (policy works live)                                              │
  ├──────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────┤
  │ Intra-host tokens (gateway/bridge/webhook/relay) │ not carried ✓ (new host mints fresh)                                           │
  ├──────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────┤
  │ db.dump                                          │ PGDMP magic ✓                                                                  │
  ├──────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────┤
  │ state/config.toml in state tar                   │ excluded ✓                                                                     │
  ├──────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────┤
  │ *.wasm in state tar                              │ excluded ✓                                                                     │
  ├──────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────────┤
  │ OMEMO state/xmpp in tar                          │ included ✓ — real prekeys, snapshotted after quiescing the bridge (consistent) │
  └──────────────────────────────────────────────────┴────────────────────────────────────────────────────────────────────────────────┘
Bundle: /var/lib/lunarwing-migrate/testbot-migrate-20260618-150358.tar (132K). The testbot is now stopped here (export = cutover), so the rollback is intact
and --old-stopped is legitimately true

Transfer the bundle, then:
  # transfer (from new host, over ssh)
  rsync -av -e ssh damed:/var/lib/lunarwing-migrate/testbot-migrate-20260618-150358.tar /var/lib/lunarwing-migrate/

  # import (forces the rootless+Quadlet target path on the new host)
  sudo LUNARWING_CONTAINER_RUNTIME=podman ic/scripts/import-tenant.sh \
    /var/lib/lunarwing-migrate/testbot-migrate-20260618-150358.tar --start --old-stopped

  # verify the marker survived (expect: rehearsal-20260618-144126)
  sudo -u testbot env XDG_RUNTIME_DIR=/run/user/$(id -u testbot) podman exec lunarwing-pg-testbot \
    psql -U lunarwing -d lunarwing -tAc \
    "SELECT note FROM migration_rehearsal_marker ORDER BY id DESC LIMIT 1"
  
