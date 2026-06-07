# WeeChat channel — see WEECHAT-CHANNEL-ARCHITECTURE.md

This stub has been superseded. The authoritative reference for the WeeChat channel —
components, end-to-end message flow, the polling/latency model, configuration precedence
(and the `setup_fields` shadowing trap), and known issues with fix status — is:

➡ **[WEECHAT-CHANNEL-ARCHITECTURE.md](WEECHAT-CHANNEL-ARCHITECTURE.md)**

The old note here ("dynamically update port in capabilities.json") is resolved: per-tenant
ports are now sourced from the environment via capability `env` fields — see the
[Configuration & precedence](WEECHAT-CHANNEL-ARCHITECTURE.md#4-configuration--precedence)
section and `docs/ops/WEECHAT-MULTITENANT-PORT-BUG.md`.
