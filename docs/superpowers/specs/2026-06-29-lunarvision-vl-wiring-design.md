# LunarVision VL Wiring — Design Spec

**Date:** 2026-06-29
**Status:** Approved (pending spec review)
**Branch:** `1.1.7-lunardevarchvm5-b3`
**Scope:** Minimal — wire verified Qwen3-VL server into tenants' OCR sidecars + persist the VL server via systemd. Defer health wiring and sidecar bugfixes to follow-up passes.

---

## Goal

Wire the verified GPU-backed Qwen3-VL server (`192.168.1.187:8080`) into both
tenants' OCR sidecars so `vision-analyze` works end-to-end, and make the VL server
survive reboots.

Minimal, fast-to-prove, no sidecar rebuild.

## Context (verified facts)

- **Tenants** `venus` and `mercury` are live and healthy on `.187` (systemd + rootless
  podman + Quadlet). Each has a per-tenant OCR sidecar container
  (`lunarwing-vision-<tenant>`) bound to loopback port `extended_base+5`.
- **Qwen3-VL server** is verified working on `.187` doing real OCR via the mmproj.
  Launcher: `/home/sun/llama.cpp/start-qwen3-vl-30b-a3b-4090.sh` (env-var-driven, tuned
  for the 4090). Alias `qwen3-vl` matches the sidecar's default model name
  (`projects/ocr-sidecar/src/main.rs:1252`).
- **Networking:** rootless podman containers reach the host's bound ports via
  `host.containers.internal` (resolves to `169.254.1.2`, the rootless podman host
  bridge). **Verified by test** from inside a tenant's podman store —
  `host.containers.internal:8080` returns the models JSON; the LAN IP path is refused
  (firewall). No LAN exposure, no firewall changes needed.
- **Sidecar config knob:** the OCR sidecar reads `VL_URL` from its env
  (`projects/ocr-sidecar/src/main.rs:~1250`). Today `write_tenant_vision_env`
  (`lunarwing-mt-admin.sh:3101-3119`) writes `LUNARWING_AUTH_TOKEN`/`OCR_PORT`/
  `OCR_HEALTH_PORT` but **no `VL_URL`**, so every tenant's sidecar currently comes up
  with VL disabled (`vl_available=false`).
- **Health checker exists:** `ic-infrastructure-health-check/health-lunarvision.sh`
  already reads `vl_available` from the sidecar's `/health`, but the sidecar doesn't
  emit it today (forward-compat gap). Wiring that is explicitly **out of scope** here.

## Architecture

Data flow for a tenant OCR request:

```
[tenant daemon's vision-analyze WASM tool]
        │  HTTP POST {image, prompt} → http://127.0.0.1:<vision_port>/v1/vision/analyze
        ▼
[per-tenant OCR sidecar container]  (lunarwing-vision-<tenant>, reads vision.env)
        │  POST to VL_URL → http://host.containers.internal:8080/v1/chat/completions
        │  (169.254.1.2 = rootless podman host bridge → host's 8080)
        ▼
[Qwen3-VL server on host]  (lunarwing-vl-server.service, native, GPU)
        │  -m qwen3-vl-30b-a3b-abliterated-q4-k-m.gguf --mmproj ...-f16.gguf
        ▼
   OCR/VL response back up the chain
```

Both tenants share the single VL server (one 4090; MoE sips VRAM, ~20-21GB used).

## Components

### Component A — MT script: add `VL_URL` to per-tenant vision env

**File:** `ic/scripts/lunarwing-mt-admin.sh`

**Constant** (insert near `DEFAULT_TENSORZERO_URL` at `:31`):

```bash
DEFAULT_VL_URL="http://host.containers.internal:8080/v1/chat/completions"
```

**`write_tenant_vision_env()`** (`:3101-3119`) — expand the heredoc to also write
`VL_URL` and `VL_MODEL` when a value is available. Effective URL resolution:

```
effective_vl_url = LUNARWING_MT_VL_URL (override) or DEFAULT_VL_URL
```

Behavior rules (idempotent and safe-by-default):

- If `effective_vl_url` is non-empty → write `VL_URL=$effective_vl_url` and
  `VL_MODEL=qwen3-vl` to `vision.env`.
- If `effective_vl_url` is empty → do **not** write `VL_URL`/`VL_MODEL`. Zero behavior
  change for deployments without a local VL server (sidecar comes up with VL disabled,
  same as today).
- Existing token/ports preserved via `_env_existing` (as today).

New heredoc shape:

```
LUNARWING_AUTH_TOKEN=$token
OCR_PORT=$VISION_SIDECAR_INTERNAL_PORT
OCR_HEALTH_PORT=$VISION_SIDECAR_HEALTH_PORT
VL_URL=$effective_vl_url
VL_MODEL=qwen3-vl
```

(With a guard so the `VL_URL=`/`VL_MODEL=` lines are only emitted when there's a value.)

### Component B — Systemd user unit: persist the VL server

**File:** new `~/.config/systemd/user/lunarwing-vl-server.service` (user `sun`)

```ini
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

[Install]
WantedBy=default.target
```

**Pre-req:** `loginctl enable-linger sun` (so the user-level manager survives
reboot/logout — same requirement the tenants have).

**Install:**

```bash
mkdir -p ~/.config/systemd/user/
cp lunarwing-vl-server.service ~/.config/systemd/user/
loginctl enable-linger sun  # if not already
systemctl --user daemon-reload
systemctl --user enable --now lunarwing-vl-server.service
```

**Design choice — why native systemd, not rootless podman:**
The VL server needs the GPU. Unlike every other LunarWing container (all CPU-only:
Tesseract, OCR sidecar, nanocode/pebble workers), containerizing the VL server would
require building a CUDA llama.cpp image + setting up NVIDIA CDI for rootless podman GPU
passthrough — a multi-hour sub-project with no existing in-repo pattern to copy. A
native systemd user unit uses the 4090 directly via the already-tuned llama.cpp build,
survives reboot via linger, and integrates with `journalctl --user`. Standard production
pattern for llama.cpp servers. Rootless-podman GPU containerization is deferred to a
possible future hardening pass.

### Component C — End-to-end verification

1. `systemctl --user status lunarwing-vl-server` — server running
2. `curl http://127.0.0.1:8080/v1/models` — server responds
3. `sudo -E ./ic/scripts/lunarwing-mt-admin.sh restart-tenant venus` (and mercury) —
   picks up the new `VL_URL` in `vision.env`
4. From inside venus's sidecar container, `curl host.containers.internal:8080/v1/models`
   → expect JSON (we already proved this works from a fresh alpine container; confirm
   it from the actual sidecar)
5. **End-to-end OCR test:** invoke the tenant's `vision-analyze` WASM tool with an
   image → expect OCR text back. This is the real proof point.

## Risks & rollback

- **Low risk overall** — additive MT script change, native systemd unit, no rebuilds.
- **Rollback:** unset `LUNARWING_MT_VL_URL` (and clear `DEFAULT_VL_URL` if desired),
  re-run `add-tenants` (idempotent → overwrites `vision.env` without `VL_URL`), disable
  the systemd unit. Tenants degrade gracefully to OCR-only (the existing behavior).
- **Caveat:** if the VL server isn't running when a tenant makes a VL request, the
  sidecar returns a VL-timeout error (30s default) and the OCR-only path still works.
  No tenant downtime from VL outages.

## Explicitly out of scope (deferred)

- Sidecar `/health` reporting `vl_available` (health wiring — needs sidecar Rust change
  + rebuild + redeploy).
- `health-lunarvision.sh` probing the VL backend directly.
- Sidecar bugfixes (disk-cache `safe_name` collision, synthetic confidence, `bbox`
  placeholder, global rate-limiter vs per-IP docs).
- Rootless-podman GPU containerization of the VL server (considered, rejected for this
  pass).
- Wiring `HEALTH_LUNARVISION_URL` / `HEALTH_LUNARVISION_REQUIRE_VL` per-tenant (the
  health checker currently defaults to `127.0.0.1:8088`, which is wrong for
  multi-tenant; deferred with the rest of the health work).

## Open questions

None at spec time. All design decisions resolved during brainstorming.
