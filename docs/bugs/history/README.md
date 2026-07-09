# Archived Bug Docs

Resolved and historical bug reports kept for provenance. These are **not** active bugs — the
active bug tracker index is at [`../README.md`](../README.md).

| Doc | Resolution |
|-----|------------|
| [BUG-FIXED-LAPSE.md](BUG-FIXED-LAPSE.md) | `<function=NAME>` tool-call dialect recovered before response cleaning (`reasoning.rs`, commit `7a9aca2c`) |
| [BUG-FIXED-wasm-tools-not-found-on-build.md](BUG-FIXED-wasm-tools-not-found-on-build.md) | MT `build-tenant --with-wasm` now resolves the tenant's `~/.cargo/bin/wasm-tools` instead of root's PATH |
| [BUG-FIXED-WEECHAT-WARNINGS.md](BUG-FIXED-WEECHAT-WARNINGS.md) | Unused import fixed; `rand_check` stub (Low) still open |
| [BUG-FIXED-workspace-concurrency-fixes-v1.1.0.md](BUG-FIXED-workspace-concurrency-fixes-v1.1.0.md) | Fixed in v1.1.0 (migration V21 + atomic workspace ops) |
| [WEECHAT-NO-SECRET-ACCESS.md](WEECHAT-NO-SECRET-ACCESS.md) | Channel messages resolve under the owner credential scope (`resolve_message_scope`, `wrapper.rs:768`) |
| [XMPP-OMEMO-BUG-TO-DO.md](XMPP-OMEMO-BUG-TO-DO.md) | OMEMO MUC fallback-spam / stuck-loop appear resolved; reopen if they recur |

## 1.1.4 MT pre-release issue logs

Multi-issue logs from the 1.1.4 multi-tenant pre-release passes. Each issue carries its own
status in the doc (🟢 fixed · 🟡 workaround · 🔴 open).

| Doc | Scope | Open items remaining |
|-----|-------|----------------------|
| [SYSTEMD-MT-1.1.4-ISSUES.md](SYSTEMD-MT-1.1.4-ISSUES.md) | Arch / systemd rootless-podman Quadlet MT pass (F1–F12) | none (F7 telegram tool removed → moot; all others fixed/documented) |
| [OPENRC-MT-1.1.4-ISSUES.md](OPENRC-MT-1.1.4-ISSUES.md) | Gentoo / OpenRC rootless-podman MT fresh-machine pass (O1–O5) | none (all fixed / documented) |
