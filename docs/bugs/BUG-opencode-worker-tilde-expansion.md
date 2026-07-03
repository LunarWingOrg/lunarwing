# BUG: opencode worker does not expand `~` in workspace paths

**Severity:** Low
**Found:** 2026-07-03 during v1.1.8 live validation on tenant `orca` (Gentoo/OpenRC, rootless Podman)
**Status:** Open
**Affects:** opencode worker (`opencode4lunarwing/`). Likely affects nanocode and pebble workers as well — all three share the same workspace-mount model (`/workspace` bind-mounted from the tenant's `*-workspace/` directory).

## Symptoms

1. Agent dispatches a task to the opencode worker that creates a file using a `~/`-relative path (e.g. `~/.lunarwing/projects/hello-test/hello.txt`)
2. The opencode worker creates a literal directory named `~` inside `/workspace` instead of expanding to `$HOME`
3. The file is written to `/workspace/~/.lunarwing/projects/hello-test/hello.txt` — not the intended location
4. On the host, the file appears at `/home/<tenant>/lunarwing/opencode-workspace/~/.lunarwing/projects/hello-test/hello.txt`

## Reproduction

1. Deploy a tenant with the opencode worker enabled
2. Send a prompt via the gateway: "Use the opencode worker to create a file called hello.txt at ~/.lunarwing/projects/hello-test/hello.txt containing 'test'"
3. Exec into the container and check `/workspace` — a literal `~` directory will be present

## Root Cause Analysis

The opencode worker container runs as a non-root user (`opencode`). The workspace root is `/workspace`, which is a bind-mount to the host-side `<tenant>-workspace/` directory. When the agent (or the LLM driving it) uses `~` in a path:

- The opencode container's shell does not expand `~` in the context of file-creation commands passed through the SDK
- `/workspace` is the working directory, not `$HOME`, so `~`-relative paths resolve to a literal subdirectory

This is not a bug in the opencode worker itself — it's an expectation mismatch between the agent's path model (which assumes `~` = workspace root or `$HOME`) and the container's actual filesystem layout.

## Impact

- Files written via `~/`-relative paths are misplaced but not lost (recoverable from the literal `~` dir)
- Agents that rely on `$HOME`-relative paths for persistence between tasks will not find their files on subsequent runs
- Affects any worker task where the LLM generates paths using `~`

## Potential Fixes

1. **Entry-point fix:** Set `HOME=/workspace` in the container environment so `~` expands to the workspace root. Simple but may have side effects for tools that expect a real home directory.
2. **Bridge-level fix:** Intercept `~/`-relative paths in the opencode bridge scripts and rewrite them to `/workspace/`-absolute paths before execution.
3. **Prompt-level mitigation:** Instruct the agent to use absolute `/workspace/` paths instead of `~`. Works but relies on LLM compliance.
4. **Fleet-wide fix:** Apply the same fix to nanocode and pebble worker Dockerfiles/bridges, since they share the workspace-mount model.

## Notes

- The same pattern likely affects nanocode and pebble workers — they use the same workspace-mount and non-root `USER` directive model
- The `chmod 777` workaround for workspace file ownership (tracked separately in the release notes under "opencode workspace file ownership under rootless userns") is unrelated to this path-expansion issue
