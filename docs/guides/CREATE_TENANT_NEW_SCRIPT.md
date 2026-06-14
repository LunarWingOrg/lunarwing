

● Done. ic/scripts/create-tenant.sh is the generic version — executable, bash -n + shellcheck clean, and I won't run it (it's a root/sudo provisioner for you).

  Usage

  sudo ic/scripts/create-tenant.sh <name> [options]

  The name is positional and gets sanitized to [a-z0-9-] (e.g. Vex_Test → vex-test, with a note). Everything name-specific is derived: JID
  <name>@xmpp.your.domain, token-<name> LLM key, /home/<name>/... paths, and the WeeChat tmux instructions.

  sudo ic/scripts/create-tenant.sh vex                                   # == the bespoke vex script
  sudo ic/scripts/create-tenant.sh acme --xmpp-jid acme@xmpp.example.org --yes
  sudo ic/scripts/create-tenant.sh scratch --minimal                     # core daemon only, no workers/docker-group
  sudo ic/scripts/create-tenant.sh bot --no-pebble --no-nanocode
  sudo ic/scripts/create-tenant.sh --help

  What carried over / what's new

  - Same 5-step flow + WeeChat tmux instructions as the vex script, all parameterized by $TENANT.
  - Every knob is now a flag (with env-var fallback): --xmpp-jid, --xmpp-domain, --xmpp-password, --llm-api-key, --gotify-url, --[no-]docker-group,
  --[no-]nanocode, --[no-]pebble, --[no-]wasm, --[no-]ensure-toolchain, --minimal, --yes.
  - Defaults are full-featured (docker-group + nanocode + pebble + wasm + cargo-component bootstrap all on), so sudo create-tenant.sh vex is identical to 
  create-tenant-vex.sh.
  - Same safety guards: refuses if the tenant already exists, root/jq/MT checks, host-dep report, --help/missing-name/unknown-flag handling all verified.
