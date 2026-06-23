# Changes made for mt admin and docs for adding new flag
* Script (ic/scripts/lunarwing-mt-admin.sh):
  - Added tenant_darkirc_enabled() helper that reads enable_darkirc from the ports registry (defaults to false for missing field)
  - ports_allocate() now accepts and persists enable_darkirc per-tenant in the registry JSON
  - add-tenant and add-tenants CLI dispatch parse --enable-darkirc (default: disabled)
  - add_tenant() accepts the flag as 10th positional arg, gates write_tenant_darkirc_adapter_env and generate_darkirc_config
  - write_tenant_lunarwing_env() only appends DARKIRC_ADAPTER_URL/SECRET when enabled
  - render_tenant_systemd_units() only renders darkirc units and Wants=/After= deps when enabled
  - render_tenant_openrc_units() only renders darkirc init scripts, after deps, rc_need, and conf.d when enabled
  - start_tenant_systemd() and start_tenant_openrc() only enable/start darkirc services when enabled
  - status_tenant() only shows darkirc services when enabled
  - patch_tenant_env() only backfills darkirc env vars when enabled
  - Stop/uninstall functions unchanged (already best-effort)
  - Usage block updated with the new flag

  Documentation (4 files):
  - MULTITENANCY-PRODUCTION.md - flag added to Step 2 note and command reference
  - DARKIRC-MULTITENANT.md - prerequisite added, examples updated with --enable-darkirc
  - MT-ADMIN-QUICKSTART.md - tip added after add-tenant example
  - guide-for-spin-up-gentoo-tenants.md - flag added to optional flags list


