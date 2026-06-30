# LunarVision VL Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the verified GPU-backed Qwen3-VL server into both tenants' OCR sidecars via `VL_URL`, and persist the VL server as a systemd user unit so it survives reboots.

**Architecture:** Each tenant's OCR sidecar container reads `VL_URL` from `vision.env`. We add `VL_URL=http://host.containers.internal:8080/v1/chat/completions` to the MT admin script's `write_tenant_vision_env()` (additive, env-overridable, no-op without a value). Separately, a native systemd user unit runs the already-verified llama.cpp launcher so the VL server restarts on crash and survives reboot via `loginctl enable-linger`. No sidecar rebuild, no Rust changes, no container image work.

**Tech Stack:** bash (MT admin script), systemd user units, rootless podman networking (`host.containers.internal`), llama.cpp.

**Spec:** `docs/superpowers/specs/2026-06-29-lunarvision-vl-wiring-design.md`

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `ic/scripts/lunarwing-mt-admin.sh` | Modify | Add `DEFAULT_VL_URL` constant near `:31`; extend `write_tenant_vision_env()` (`:3101-3119`) to write `VL_URL`/`VL_MODEL` when a value resolves |
| `ic/systemd/lunarwing-vl-server.service` | Create (in repo, as a template) | Systemd user unit template for the VL server; installed to `~/.config/systemd/user/` for user `sun` |
| `/home/sun/.config/systemd/user/lunarwing-vl-server.service` | Create (on host, runtime) | Installed copy of the unit for `sun` |

**No test files added** — this is a config/wiring change verified by end-to-end runtime tests (curl + WASM tool invocation), not unit-testable Rust logic. The shellcheck gate (`ic/scripts/check-mt-admin.sh`) serves as the syntax check for the MT script edit.

---

## Task 1: Add `DEFAULT_VL_URL` constant to the MT admin script

**Files:**
- Modify: `ic/scripts/lunarwing-mt-admin.sh` (insert after line 31)

- [ ] **Step 1: Locate the exact insertion point**

Run:
```bash
grep -n 'DEFAULT_TENSORZERO_URL=' ic/scripts/lunarwing-mt-admin.sh | head -1
```
Expected: `31:DEFAULT_TENSORZERO_URL="${LUNARWING_MT_TENSORZERO_URL:-http://192.168.1.157:3000/openai/v1}"`

This confirms line 31 is where the existing fleet-default URL constant lives. We insert our new constant directly after it, following the same pattern.

- [ ] **Step 2: Add the constant**

Use Edit to insert after line 31. The `old_string` to match (line 31):

```bash
DEFAULT_TENSORZERO_URL="${LUNARWING_MT_TENSORZERO_URL:-http://192.168.1.157:3000/openai/v1}"
```

Replace with:

```bash
DEFAULT_TENSORZERO_URL="${LUNARWING_MT_TENSORZERO_URL:-http://192.168.1.157:3000/openai/v1}"
# Fleet-wide default VL (vision-language) backend URL the OCR sidecar proxies to.
# Empty = sidecar comes up with VL disabled (vl_available=false), preserving the
# pre-VL behavior for deployments without a local vision server. Override with
# LUNARWING_MT_VL_URL. The host.containers.internal hostname is the rootless
# podman host bridge (169.254.1.2) — verified reachable from inside tenant
# containers on this box.
DEFAULT_VL_URL="${LUNARWING_MT_VL_URL:-http://host.containers.internal:8080/v1/chat/completions}"
```

- [ ] **Step 3: Verify the edit landed correctly**

Run:
```bash
sed -n '29,36p' ic/scripts/lunarwing-mt-admin.sh
```
Expected output: should show `DEFAULT_TENSORZERO_URL` followed by the comment block and `DEFAULT_VL_URL=...` line.

- [ ] **Step 4: Verify shellcheck still passes**

Run:
```bash
cd ic/scripts && shellcheck -S warning lunarwing-mt-admin.sh && echo "✓ clean"
```
Expected: `✓ clean` (no new warnings introduced). If shellcheck flags the unquoted vars in `${LUNARWING_MT_VL_URL:-...}`, note that the existing `DEFAULT_TENSORZERO_URL` uses the identical pattern and passes — so this should too. If it does flag, follow whatever pattern the existing line uses to satisfy it.

---

## Task 2: Extend `write_tenant_vision_env()` to emit `VL_URL` and `VL_MODEL`

**Files:**
- Modify: `ic/scripts/lunarwing-mt-admin.sh:3101-3119` (the `write_tenant_vision_env()` body)

- [ ] **Step 1: Re-read the current function body**

Run:
```bash
sed -n '3101,3120p' ic/scripts/lunarwing-mt-admin.sh
```
Expected: the function as quoted in the design spec — token/ports heredoc, `chown`, `printf '%s' "$token"`.

- [ ] **Step 2: Replace the function body**

Use Edit. The `old_string` to match (the entire current function body):

```bash
write_tenant_vision_env() {
  local name="$1"
  local env_dir env_path
  env_dir="$(tenant_env_dir "$name")"
  env_path="$env_dir/vision.env"
  local token
  token="$(_env_existing "$env_path" LUNARWING_AUTH_TOKEN)"
  token="${token:-$(generate_token)}"
  mkdir -p "$env_dir"
  (
    umask 077
    cat >"$env_path" <<ENVEOF
LUNARWING_AUTH_TOKEN=$token
OCR_PORT=$VISION_SIDECAR_INTERNAL_PORT
OCR_HEALTH_PORT=$VISION_SIDECAR_HEALTH_PORT
ENVEOF
  )
  chown "$name:$name" "$env_path"
  printf '%s' "$token"
}
```

Replace with:

```bash
write_tenant_vision_env() {
  local name="$1"
  local env_dir env_path
  env_dir="$(tenant_env_dir "$name")"
  env_path="$env_dir/vision.env"
  local token
  token="$(_env_existing "$env_path" LUNARWING_AUTH_TOKEN)"
  token="${token:-$(generate_token)}"
  # Resolve VL backend URL: explicit override wins, else fleet default.
  # Empty (LUNARWING_MT_VL_URL= and DEFAULT_VL_URL unset) = no VL line written;
  # sidecar comes up with VL disabled. Idempotent — vision.env is fully rewritten.
  local vl_url
  vl_url="${LUNARWING_MT_VL_URL:-$DEFAULT_VL_URL}"
  mkdir -p "$env_dir"
  (
    umask 077
    if [[ -n "$vl_url" ]]; then
      cat >"$env_path" <<ENVEOF
LUNARWING_AUTH_TOKEN=$token
OCR_PORT=$VISION_SIDECAR_INTERNAL_PORT
OCR_HEALTH_PORT=$VISION_SIDECAR_HEALTH_PORT
VL_URL=$vl_url
VL_MODEL=qwen3-vl
ENVEOF
    else
      cat >"$env_path" <<ENVEOF
LUNARWING_AUTH_TOKEN=$token
OCR_PORT=$VISION_SIDECAR_INTERNAL_PORT
OCR_HEALTH_PORT=$VISION_SIDECAR_HEALTH_PORT
ENVEOF
    fi
  )
  chown "$name:$name" "$env_path"
  printf '%s' "$token"
}
```

Rationale for the two-branch heredoc (vs. building the heredoc conditionally): it keeps each heredoc static and shellcheck-clean, and the cost of the duplication is trivial (3 lines). Alternative (appending `VL_URL=` lines after the heredoc via `printf >>`) was rejected because it's more fragile against partial-write races and less readable.

- [ ] **Step 3: Verify the edit**

Run:
```bash
sed -n '3101,3135p' ic/scripts/lunarwing-mt-admin.sh
```
Expected: the new function body with the `vl_url` resolution and the two-branch heredoc.

- [ ] **Step 4: Run shellcheck**

Run:
```bash
cd ic/scripts && shellcheck -S warning lunarwing-mt-admin.sh && echo "✓ clean"
```
Expected: `✓ clean`. The `if [[ -n "$vl_url" ]]` is a standard bash construct; the heredocs use unquoted vars exactly as the original did.

- [ ] **Step 5: Commit Task 1 + Task 2 together**

```bash
cd /home/sun/lw_new_workspace/lunarwing
git add ic/scripts/lunarwing-mt-admin.sh
git commit -m "Wire VL_URL into per-tenant vision.env

write_tenant_vision_env now resolves an effective VL backend URL from
LUNARWING_MT_VL_URL (override) or DEFAULT_VL_URL (fleet default), and writes
VL_URL + VL_MODEL=qwen3-vl to vision.env when a value is present. Empty
resolution = no VL line written (sidecar comes up VL-disabled, preserving
prior behavior for deployments without a local vision server).

DEFAULT_VL_URL points at http://host.containers.internal:8080/v1/chat/completions
— the rootless podman host bridge, verified reachable from inside tenant
sidecar containers on the .187 box."
```

---

## Task 3: Create the VL server systemd unit template in the repo

**Files:**
- Create: `ic/systemd/lunarwing-vl-server.service`

- [ ] **Step 1: Create the unit file**

Write to `ic/systemd/lunarwing-vl-server.service`:

```ini
# LunarWing VL Server — Qwen3-VL 30B-A3B (abliterated, Q4_K_M) on a single RTX 4090.
#
# Native systemd USER unit (not root, not a container). Runs the env-var-driven
# launcher at /home/sun/llama.cpp/start-qwen3-vl-30b-a3b-4090.sh, which loads
# the LLM + FP16 mmproj with CUDA, exposes the OpenAI-compatible API on :8080
# with alias qwen3-vl (matches the OCR sidecar's default model name).
#
# Why native, not rootless podman: the VL server needs the GPU, and every other
# LunarWing container is CPU-only (no existing GPU-passthrough pattern). A
# native unit uses the 4090 directly via the already-tuned llama.cpp build,
# survives reboot via loginctl enable-linger, and integrates with journalctl.
#
# Install (as the user who owns the llama.cpp build, e.g. `sun`):
#   mkdir -p ~/.config/systemd/user/
#   cp ic/systemd/lunarwing-vl-server.service ~/.config/systemd/user/
#   loginctl enable-linger "$USER"   # survive logout/reboot
#   systemctl --user daemon-reload
#   systemctl --user enable --now lunarwing-vl-server.service
#
# Tail logs:    journalctl --user -u lunarwing-vl-server -f
# Health:       curl -s http://127.0.0.1:8080/v1/models | jq .

[Unit]
Description=LunarWing VL Server (Qwen3-VL 30B-A3B, RTX 4090)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/home/sun/llama.cpp
ExecStart=/home/sun/llama.cpp/start-qwen3-vl-30b-a3b-4090.sh
Restart=on-failure
RestartSec=10
UMask=0077
Nice=5
# GPU is accessed directly via CUDA — no container, no --gpus/CDI needed.
# Launcher flags (mmproj, -ngl 99, -fa on, q8 KV cache) are baked into the script.

[Install]
WantedBy=default.target
```

- [ ] **Step 2: Verify the file**

Run:
```bash
ls -la ic/systemd/lunarwing-vl-server.service
# systemd-analyze verify is the proper syntax check for unit files:
systemd-analyze verify ic/systemd/lunarwing-vl-server.service 2>&1 | head
```
Expected: file exists; `systemd-analyze verify` outputs nothing (clean) or only minor notes about user-unit context (which are expected when verifying a user unit as root and can be ignored).

---

## Task 4: Install the VL server unit on the host and start it

> ⚠️ **This task runs on the host as user `sun`, not in the repo.** It stops the tmux-launched VL server and replaces it with the supervised systemd unit. Do this AFTER the existing tmux server has been confirmed working (already done — verified OCR).

- [ ] **Step 1: Confirm the VL server is currently running (so we know what we're replacing)**

Run (as `sun`):
```bash
curl -s http://127.0.0.1:8080/v1/models | head -c 100
tmux ls 2>/dev/null | grep qwen3vl
```
Expected: models JSON; a tmux session named `qwen3vl`.

- [ ] **Step 2: Stop the tmux-launched server**

Run:
```bash
tmux kill-session -t qwen3vl
# Confirm port 8080 freed:
sleep 2
ss -tlnp 2>/dev/null | grep ':8080 ' || echo "port 8080 free"
```
Expected: `port 8080 free`.

- [ ] **Step 3: Install the unit for user `sun`**

Run:
```bash
mkdir -p ~/.config/systemd/user/
cp /home/sun/lw_new_workspace/lunarwing/ic/systemd/lunarwing-vl-server.service ~/.config/systemd/user/
loginctl enable-linger sun   # may already be set; harmless to re-run
systemctl --user daemon-reload
```

- [ ] **Step 4: Enable and start the unit**

Run:
```bash
systemctl --user enable --now lunarwing-vl-server.service
systemctl --user status lunarwing-vl-server.service --no-pager | head -15
```
Expected: `Active: active (running)`.

- [ ] **Step 5: Wait for the model to load and verify health**

The model takes a few minutes to load. Poll:
```bash
# Wait up to ~5 min for the server to come up
for i in $(seq 1 60); do
  if curl -sf http://127.0.0.1:8080/v1/models >/dev/null 2>&1; then
    echo "✓ VL server responding after ${i}0s"
    break
  fi
  sleep 10
done
curl -s http://127.0.0.1:8080/v1/models | python3 -m json.tool | head -20
```
Expected: JSON model list including `qwen3-vl`.

- [ ] **Step 6: Commit the unit template**

```bash
cd /home/sun/lw_new_workspace/lunarwing
git add ic/systemd/lunarwing-vl-server.service
git commit -m "Add lunarwing-vl-server systemd user unit template

Native (non-container) systemd USER unit for the Qwen3-VL server. Runs the
verified launcher with Restart=on-failure + linger for reboot survival.
Includes install instructions in the header comment."
```

---

## Task 5: Restart tenants to pick up the new `VL_URL`

> ⚠️ **This task requires root and the MT env sourced.** Run from a shell where `~/.lunarwing-mt.env` has been sourced.

- [ ] **Step 1: Confirm the MT env is sourced**

Run:
```bash
echo "LUNARWING_CONTAINER_RUNTIME=$LUNARWING_CONTAINER_RUNTIME"
echo "LUNARWING_MT_ROOTLESS=$LUNARWING_MT_ROOTLESS"
```
Expected: `LUNARWING_CONTAINER_RUNTIME=podman` and `LUNARWING_MT_ROOTLESS=true`. If either is empty/wrong, run `source ~/.lunarwing-mt.env` and re-check. **Do not proceed without both correct** — otherwise the command hits the docker store (the footgun from earlier).

- [ ] **Step 2: Re-run write_tenant_vision_env to refresh vision.env for both tenants**

The MT script has no direct "rewrite vision env" subcommand, but `add-tenants` is idempotent and will re-write vision.env. However, that also re-runs the full add flow. The cleanest path: invoke the function via the script's restart path, which re-renders everything. First, restart venus:

```bash
sudo -E ./ic/scripts/lunarwing-mt-admin.sh restart-tenant venus
```
Expected: clean restart, no errors. The restart path re-renders units and restarts containers; vision.env is rewritten via `write_tenant_vision_env` during the start sequence.

- [ ] **Step 3: Verify vision.env now contains VL_URL**

Run:
```bash
sudo cat /home/venus/.config/lunarwing/vision.env
```
Expected output includes:
```
VL_URL=http://host.containers.internal:8080/v1/chat/completions
VL_MODEL=qwen3-vl
```
(alongside `LUNARWING_AUTH_TOKEN`, `OCR_PORT`, `OCR_HEALTH_PORT`.)

If `VL_URL` is missing, the script wasn't re-run with the new code (check that the restart actually invoked the patched `write_tenant_vision_env`). If the value is wrong, check `LUNARWING_MT_VL_URL` in the env and `DEFAULT_VL_URL` in the script.

- [ ] **Step 4: Repeat for mercury**

```bash
sudo -E ./ic/scripts/lunarwing-mt-admin.sh restart-tenant mercury
sudo cat /home/mercury/.config/lunarwing/vision.env | grep -E 'VL_URL|VL_MODEL'
```
Expected: same `VL_URL`/`VL_MODEL` lines.

- [ ] **Step 5: Confirm both tenants' status is still healthy**

```bash
sudo -E ./ic/scripts/lunarwing-mt-admin.sh status venus
sudo -E ./ic/scripts/lunarwing-mt-admin.sh status mercury
```
Expected: all services active, PG/nanocode/pebble running.

---

## Task 6: End-to-end verification — sidecar reaches VL server

**Files:** none (verification only)

- [ ] **Step 1: Confirm the sidecar container can reach the VL server**

Run (as root, reaching into venus's sidecar container):
```bash
sudo -u venus XDG_RUNTIME_DIR=/run/user/$(id -u venus) \
  podman exec lunarwing-vision-venus \
  curl -s --max-time 5 http://host.containers.internal:8080/v1/models | head -c 200
```
Expected: JSON containing `"name":"qwen3-vl"`.

If this fails with connection refused/timeout, the sidecar's container networking doesn't have `host.containers.internal` resolution — re-check that the sidecar was actually restarted with the new env (Task 5 Step 3).

- [ ] **Step 2: Confirm the sidecar's `/health` endpoint is reachable**

Run:
```bash
# venus's vision_service port is 20015 (extended_base+5 for venus)
curl -s http://127.0.0.1:20015/health | python3 -m json.tool
```
Expected: JSON with `status`, `tesseract_version`, `uptime_secs`. (Note: `vl_available` will still be `unknown` or absent — that's the deferred health-wiring work. We're only confirming reachability here.)

- [ ] **Step 3: Send a real OCR request through the sidecar**

Use the venus sidecar's `/v1/vision/analyze` endpoint directly with a base64 image:
```bash
IMAGE_PATH="/home/sun/lawrenceimages.jpg"   # the verified OCR test image
B64=$(base64 -w0 "$IMAGE_PATH")
VISION_TOKEN=$(sudo grep '^LUNARWING_AUTH_TOKEN=' /home/venus/.config/lunarwing/vision.env | cut -d= -f2)
curl -s http://127.0.0.1:20015/v1/vision/analyze \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $VISION_TOKEN" \
  -d "{
    \"image\": \"${B64}\",
    \"mode\": \"text\",
    \"prompt\": \"What text is in this image?\"
  }" | python3 -m json.tool | head -30
```
Expected: JSON response containing the OCR'd text from the image (e.g. `"LAWRENCE OF ARABIA"` or similar).

If the response includes `"ocr"` text but `mode` routed away from VL, that's fine — `mode=text` is OCR-only by design. The proof that VL is wired is that the sidecar now *could* reach VL when routing decides to. To explicitly exercise VL, repeat with `"mode":"describe"`:
```bash
curl -s http://127.0.0.1:20015/v1/vision/analyze \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $VISION_TOKEN" \
  -d "{ \"image\": \"${B64}\", \"mode\": \"describe\", \"prompt\": \"Describe this image.\" }" \
  | python3 -m json.tool | head -30
```
Expected: a description generated by Qwen3-VL (proves the full sidecar→VL chain).

- [ ] **Step 4: Document the result**

If all three steps pass, the wiring is verified end-to-end. Note in the commit message for the next step (or a follow-up doc) that:
- VL server: systemd unit `lunarwing-vl-server.service` (user `sun`)
- Both tenants' sidecars reach it via `host.containers.internal:8080`
- OCR + describe modes both work

---

## Task 7: Final commit and cleanup

- [ ] **Step 1: Confirm working tree is clean (all changes committed)**

```bash
cd /home/sun/lw_new_workspace/lunarwing
git status
```
Expected: `nothing to commit, working tree clean`.

- [ ] **Step 2: Update FEATURE_PARITY.md if LunarVision status changed**

Check if LunarVision / VL is tracked in `FEATURE_PARITY.md`:
```bash
grep -niE "vision|lunarvision|qwen3-vl|ocr.sidecar|VL_URL" FEATURE_PARITY.md | head
```
If there's an entry that should flip from `🚧` to `✅` (or notes added about VL being wired), update it in a follow-up commit. If no entry exists, skip — FEATURE_PARITY tracks product features, not ops wiring.

- [ ] **Step 3: Note deferred work for follow-up passes**

No code action — just record that these are intentionally deferred per the spec:
- Sidecar `/health` reporting `vl_available` (needs sidecar Rust change + image rebuild)
- `health-lunarvision.sh` probing the VL backend directly
- Sidecar bugfixes (disk cache, synthetic confidence, bbox, rate limiter)
- Rootless-podman GPU containerization of the VL server

---

## Self-Review (run after writing the plan, before handoff)

**1. Spec coverage:** ✅ All spec components mapped to tasks:
- Component A (MT script edit) → Tasks 1 + 2
- Component B (systemd unit) → Tasks 3 + 4
- Component C (verification) → Tasks 5 + 6
- Risks/rollback covered in the spec; no task needed (rollback is "unset LUNARWING_MT_VL_URL + re-run add-tenants + disable unit").

**2. Placeholder scan:** ✅ No TBDs/TODOs. Every step has concrete commands, expected output, and code blocks where relevant. The one conditional ("If `VL_URL` is missing...") has a concrete diagnostic path.

**3. Type consistency:** ✅ `VL_URL`, `VL_MODEL=qwen3-vl`, `LUNARWING_MT_VL_URL`, `DEFAULT_VL_URL` all used consistently across tasks. Port `8080` and the `host.containers.internal` hostname are consistent. The `20015` port for venus's vision_service matches the verified port registry (`extended_base+5` for venus where extended_base=20010).

**4. Scope check:** ✅ Single subsystem (VL wiring), single plan. The deferred items are clearly out-of-scope and each would be its own future plan.
