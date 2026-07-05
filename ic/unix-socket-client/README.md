# LunarWing Unix Socket Client

Standalone REPL client for a running LunarWing daemon, speaking the
newline-delimited JSON protocol of the daemon's Unix socket REPL.

Lives in-tree at `ic/unix-socket-client/`. Not a workspace member; build it
directly from this directory.

Default socket resolution mirrors the daemon: `$LUNARWING_SOCKET` (legacy
`$IRONCLAW_SOCKET`), then `$XDG_RUNTIME_DIR/lunarwing.sock`, then
`<base_dir>/lunarwing.sock`. Pass an explicit socket path as the first
argument to override.
