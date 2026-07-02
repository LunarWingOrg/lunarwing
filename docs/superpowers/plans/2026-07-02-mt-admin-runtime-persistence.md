# mt-admin Container-Runtime Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Set `LUNARWING_CONTAINER_RUNTIME` once — it persists to `/etc/lunarwing/container-runtime` and every later mt-admin command uses it without the env var.

**Architecture:** Two tiny helpers (`_load_saved_container_runtime`, `_save_container_runtime`) plus a file branch in `detect_container_runtime()` (env > saved file > auto-detect; persist only on explicit env use). Doctor reports the resolved runtime + source. Spec: `docs/superpowers/specs/2026-07-02-mt-admin-runtime-persistence-design.md`.

**Tech Stack:** bash (`set -euo pipefail`), coreutils. All in `ic/scripts/lunarwing-mt-admin.sh` + two docs.

## Global Constraints

- Warn-and-continue: no new `die` paths (the existing invalid-env `die` stays). Warnings: `say "WARNING: ..." >&2`.
- **All new human-facing messages inside `detect_container_runtime` and its helpers MUST go to stderr** — the function's stdout is captured by `CONTAINER_RT="$(detect_container_runtime)"`; a stdout message corrupts the runtime value.
- No `sed -i`; file writes via same-directory temp file + `mv`.
- Never print secrets. `bash -n ic/scripts/lunarwing-mt-admin.sh` must pass before each commit.
- Line numbers reference commit `820d1a5e`; re-locate with the given grep anchors if drifted.

---

### Task 1: Helpers + resolution/persistence logic in `detect_container_runtime`

**Files:**
- Modify: `ic/scripts/lunarwing-mt-admin.sh` — `detect_container_runtime()` (anchor: `grep -n '^detect_container_runtime()'`, ~:399) and new helpers directly above it.

**Interfaces:**
- Produces: `RUNTIME_STATE_FILE=/etc/lunarwing/container-runtime` (global, near the other globals is fine but defining it just above the helpers keeps the unit together); `_load_saved_container_runtime()` — prints `podman`/`docker` from the file or nothing (invalid content: warning to stderr, prints nothing); `_save_container_runtime <rt>` — writes the file (0644, dir auto-created), warn-and-continue, silent on failure aside from the warning; `CONTAINER_RT_SOURCE` — global set by `detect_container_runtime` to `env`/`saved`/`auto-detected` (consumed by Task 2's doctor line).

- [ ] **Step 1: Add the file constant + two helpers** directly ABOVE `detect_container_runtime()` (anchor: `grep -n '# ── Container runtime detection'`):

```bash
# Machine-wide persisted runtime choice (see _save_container_runtime). One
# line: "podman" or "docker". World-readable so unprivileged doctor runs can
# still resolve the saved choice.
RUNTIME_STATE_FILE="/etc/lunarwing/container-runtime"

# Print the persisted runtime choice, or nothing. Invalid/unreadable content
# warns (stderr) and prints nothing so callers fall through to auto-detect.
_load_saved_container_runtime() {
  [[ -f "$RUNTIME_STATE_FILE" ]] || return 0
  local saved=""
  saved="$(tr -d '[:space:]' <"$RUNTIME_STATE_FILE" 2>/dev/null)" || return 0
  saved="${saved,,}"
  case "$saved" in
    docker|podman) printf '%s' "$saved" ;;
    *) say "WARNING: ignoring invalid $RUNTIME_STATE_FILE: '$saved' (expected docker or podman)" >&2 ;;
  esac
  return 0
}

# Persist an explicitly-chosen runtime machine-wide. Warn-and-continue: a
# read-only /etc or non-root caller must never break the invoking command.
_save_container_runtime() {
  local rt="$1" tmp
  mkdir -p /etc/lunarwing 2>/dev/null || { say "WARNING: cannot create /etc/lunarwing; runtime choice not persisted" >&2; return 0; }
  tmp="$(mktemp "${RUNTIME_STATE_FILE}.tmp.XXXXXX" 2>/dev/null)" \
    || { say "WARNING: cannot write $RUNTIME_STATE_FILE; runtime choice not persisted" >&2; return 0; }
  if printf '%s\n' "$rt" >"$tmp" && chmod 0644 "$tmp" && mv "$tmp" "$RUNTIME_STATE_FILE"; then
    say "container runtime '$rt' saved to $RUNTIME_STATE_FILE (env var no longer needed)" >&2
  else
    rm -f "$tmp"
    say "WARNING: cannot write $RUNTIME_STATE_FILE; runtime choice not persisted" >&2
  fi
  return 0
}
```

- [ ] **Step 2: Rework `detect_container_runtime()`.** Replace the whole function body (anchor: `grep -n '^detect_container_runtime()'`; current body spans the env-override block + the three auto-detect branches + the final `die`) with:

```bash
CONTAINER_RT_SOURCE=""
detect_container_runtime() {
  local override="${LUNARWING_CONTAINER_RUNTIME:-}" saved=""
  if [[ -n "$override" ]]; then
    case "${override,,}" in
      docker|podman)
        override="${override,,}"
        # Persist the explicit choice (idempotent: skip when unchanged).
        saved="$(_load_saved_container_runtime)"
        [[ "$saved" == "$override" ]] || _save_container_runtime "$override"
        CONTAINER_RT_SOURCE="env"
        printf '%s' "$override"; return 0 ;;
      *) die "unsupported container runtime '$override'; use docker or podman" ;;
    esac
  fi

  saved="$(_load_saved_container_runtime)"
  if [[ -n "$saved" ]]; then
    CONTAINER_RT_SOURCE="saved"
    printf '%s' "$saved"; return 0
  fi

  if command -v podman >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
    CONTAINER_RT_SOURCE="auto-detected"; printf 'podman'; return 0
  fi
  if command -v docker >/dev/null 2>&1; then CONTAINER_RT_SOURCE="auto-detected"; printf 'docker'; return 0; fi
  if command -v podman >/dev/null 2>&1; then CONTAINER_RT_SOURCE="auto-detected"; printf 'podman'; return 0; fi

  die "neither docker nor podman found; install one or set LUNARWING_CONTAINER_RUNTIME"
}
```

Note: `CONTAINER_RT_SOURCE` is set inside a `$( )` subshell at most call sites (`CONTAINER_RT="$(detect_container_runtime)"`), so it does NOT propagate to the parent — that is fine for every existing caller (they only need the value). Task 2's doctor line calls `detect_container_runtime` directly (not in a substitution) to read the source. Do not "fix" this.

- [ ] **Step 3: Syntax check.**

Run: `bash -n ic/scripts/lunarwing-mt-admin.sh && echo SYNTAX-OK`
Expected: `SYNTAX-OK`

- [ ] **Step 4: Extracted-function harness.** Run exactly (work dir `/tmp/claude-962/-var-lib-paseo--paseo-worktrees-claudecode-lunarwing/c0a8d603-84e4-49f1-9514-e7b82fcc2079/scratchpad/rtpersist`):

```bash
mkdir -p /tmp/claude-962/-var-lib-paseo--paseo-worktrees-claudecode-lunarwing/c0a8d603-84e4-49f1-9514-e7b82fcc2079/scratchpad/rtpersist
cd /tmp/claude-962/-var-lib-paseo--paseo-worktrees-claudecode-lunarwing/c0a8d603-84e4-49f1-9514-e7b82fcc2079/scratchpad/rtpersist
REPO=/var/lib/paseo/.paseo/worktrees/claudecode/lunarwing
sed -n '/^RUNTIME_STATE_FILE=/,/^}/p' "$REPO/ic/scripts/lunarwing-mt-admin.sh" | head -40 > funcs.sh   # constant + both helpers
sed -n '/^CONTAINER_RT_SOURCE=""/,/^}/p' "$REPO/ic/scripts/lunarwing-mt-admin.sh" >> funcs.sh          # detect fn
cat > h.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
say() { printf '%s\n' "$*"; }
die() { printf 'DIE: %s\n' "$*" >&2; exit 1; }
source ./funcs.sh
RUNTIME_STATE_FILE="$PWD/state/container-runtime"   # test override
mkdir -p "$PWD/state"; _etc_override() { :; }
# monkey-patch _save_container_runtime's hardcoded /etc path for the test:
_save_container_runtime() {
  local rt="$1" tmp
  tmp="$(mktemp "${RUNTIME_STATE_FILE}.tmp.XXXXXX")" || { say "WARNING: cannot write" >&2; return 0; }
  printf '%s\n' "$rt" >"$tmp" && chmod 0644 "$tmp" && mv "$tmp" "$RUNTIME_STATE_FILE" \
    && say "container runtime '$rt' saved to $RUNTIME_STATE_FILE (env var no longer needed)" >&2 || rm -f "$tmp"
  return 0
}
echo "--- 1: env + no file → persists, stdout exactly 'podman'"
rm -f "$RUNTIME_STATE_FILE"
out="$(LUNARWING_CONTAINER_RUNTIME=podman detect_container_runtime)"
[[ "$out" == "podman" ]] && [[ "$(cat "$RUNTIME_STATE_FILE")" == "podman" ]] && echo OK1
echo "--- 2: file only → used, not rewritten"
before=$(stat -c %Y "$RUNTIME_STATE_FILE"); sleep 1.1
out="$(detect_container_runtime)"; after=$(stat -c %Y "$RUNTIME_STATE_FILE")
[[ "$out" == "podman" && "$before" == "$after" ]] && echo OK2
echo "--- 3: env conflicts with file → env wins, file updated"
out="$(LUNARWING_CONTAINER_RUNTIME=docker detect_container_runtime)"
[[ "$out" == "docker" && "$(cat "$RUNTIME_STATE_FILE")" == "docker" ]] && echo OK3
echo "--- 4: garbage file → warns, falls through to auto-detect (no crash)"
echo "banana" > "$RUNTIME_STATE_FILE"
out="$(detect_container_runtime)"
[[ "$out" == "podman" || "$out" == "docker" ]] && echo OK4   # whatever this box auto-detects
echo "--- 5: same-value env → no rewrite (idempotent)"
printf 'podman\n' > "$RUNTIME_STATE_FILE"; before=$(stat -c %Y "$RUNTIME_STATE_FILE"); sleep 1.1
out="$(LUNARWING_CONTAINER_RUNTIME=podman detect_container_runtime)"; after=$(stat -c %Y "$RUNTIME_STATE_FILE")
[[ "$out" == "podman" && "$before" == "$after" ]] && echo OK5
echo "ALL DONE"
EOF
bash h.sh
```

Expected: `OK1 OK2 OK3 OK4 OK5 ALL DONE` in order, with the "saved to" line appearing on stderr for cases 1 and 3 only, and a `WARNING: ignoring invalid` line for case 4. (The harness monkey-patches `_save_container_runtime` because the real one hardcodes `mkdir -p /etc/lunarwing`; the real persist path is exercised in the live check below.)

- [ ] **Step 5: Commit.**

```bash
git add ic/scripts/lunarwing-mt-admin.sh
git commit -m "feat(mt-admin): persist explicit container-runtime choice

LUNARWING_CONTAINER_RUNTIME now persists to /etc/lunarwing/container-runtime
on explicit use; later commands resolve env > saved file > auto-detect, so
the env var is needed only once. Auto-detected values are never persisted;
invalid/unwritable state files warn and continue. [skip-regression-check]"
```

---

### Task 2: Doctor source line + usage text + docs

**Files:**
- Modify: `ic/scripts/lunarwing-mt-admin.sh` — usage text `:322` (anchor: `grep -n 'Override: docker or podman'`); doctor (anchor: `grep -n '_check "podman available"'`, insert after that block).
- Modify: `docs/ops/MULTITENANCY-PRODUCTION.md` — env-var table row (anchor: `grep -n 'Force .docker. or .podman.'`) and the numbered list item (anchor: `grep -n 'env var override'`).

**Interfaces:**
- Consumes: `detect_container_runtime` + `CONTAINER_RT_SOURCE` + `RUNTIME_STATE_FILE` from Task 1.

- [ ] **Step 1: Usage text.** Change the line
`  LUNARWING_CONTAINER_RUNTIME      Override: docker or podman`
to:
`  LUNARWING_CONTAINER_RUNTIME      Override: docker or podman (persisted to /etc/lunarwing/container-runtime on first explicit use; later runs need no env var)`

- [ ] **Step 2: Doctor line.** Immediately after the `_check "podman available" podman info` block (and before `ensure_container_runtime`), add:

```bash
  # Informational: which runtime commands will use, and why.
  local _rt_resolved
  _rt_resolved="$(detect_container_runtime)" || _rt_resolved="unresolved"
  detect_container_runtime >/dev/null 2>&1 || true   # set CONTAINER_RT_SOURCE in this shell
  printf '[info] container runtime: %s (%s%s)\n' "$_rt_resolved" "${CONTAINER_RT_SOURCE:-unknown}" \
    "$([[ "${CONTAINER_RT_SOURCE:-}" == "saved" ]] && printf ' — %s' "$RUNTIME_STATE_FILE")"
```

Note the double call: the first (in `$( )`) captures the value but its `CONTAINER_RT_SOURCE` dies with the subshell; the second, bare call sets `CONTAINER_RT_SOURCE` in doctor's own shell (its stdout/stderr discarded). Both calls are cheap and idempotent (same-value persist writes nothing).

- [ ] **Step 3: Docs.** In `docs/ops/MULTITENANCY-PRODUCTION.md`: change the table row default cell from `auto-detect` to `saved choice, else auto-detect` and the description cell from `Force docker or podman` to `Force docker or podman — persisted to /etc/lunarwing/container-runtime on first explicit use (set once)`. In the numbered resolution list, change item 1 from "`LUNARWING_CONTAINER_RUNTIME` env var override (`docker` or `podman`)" to "`LUNARWING_CONTAINER_RUNTIME` env var override (`docker` or `podman`) — persisted machine-wide on use" and insert a new item 2 "Saved choice in `/etc/lunarwing/container-runtime`" (renumber the rest).

- [ ] **Step 4: Verify.**

Run: `bash -n ic/scripts/lunarwing-mt-admin.sh && echo SYNTAX-OK`
Expected: `SYNTAX-OK`
Run: `grep -c 'container-runtime' ic/scripts/lunarwing-mt-admin.sh docs/ops/MULTITENANCY-PRODUCTION.md`
Expected: ≥1 in each file.

- [ ] **Step 5: Commit.**

```bash
git add ic/scripts/lunarwing-mt-admin.sh docs/ops/MULTITENANCY-PRODUCTION.md
git commit -m "docs(mt-admin): doctor runtime-source line + set-once runtime docs [skip-regression-check]"
```

---

### Task 3: Live verification (operator or coordinator with root)

- [ ] Run one command WITH the prefix and observe the save line, then one WITHOUT it:

```bash
sudo env LUNARWING_CONTAINER_RUNTIME=podman ic/scripts/lunarwing-mt-admin.sh list-tenants
#   expect on stderr: container runtime 'podman' saved to /etc/lunarwing/container-runtime (env var no longer needed)
sudo ic/scripts/lunarwing-mt-admin.sh status sshtest        # NO env var — must hit the podman-backed tenant cleanly
cat /etc/lunarwing/container-runtime                        # → podman
sudo ic/scripts/lunarwing-mt-admin.sh doctor | grep 'container runtime'
#   expect: [info] container runtime: podman (saved — /etc/lunarwing/container-runtime)
```

## Self-Review (completed)

- Spec coverage: resolution order + persist rule → Task 1; doctor + docs → Task 2; live check → Task 3. Out-of-scope items untouched.
- Placeholders: none; all code inline.
- Name consistency: `RUNTIME_STATE_FILE`, `_load_saved_container_runtime`, `_save_container_runtime`, `CONTAINER_RT_SOURCE` used identically across tasks; Task 2 consumes exactly what Task 1 produces.
