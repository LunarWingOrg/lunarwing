# Multica Server Compatibility — Verification Results

**Verified by:** SweetieBot (Chief of Engineering, Dark Forest Wizard)  
**Date:** 2026-06-01  
**Multica Commit:** `main` (current)  
**LunarWing Branch:** `1.1.0-new-lunartica`

---

## TL;DR

**No server changes required.** LunarWing's Multica integration works with the current Multica server as-is. All four concerns raised during design were verified against the actual server code.

---

## Concern #1: Runtime Type "lunarwing"

**Concern:** Does Multica validate runtime types against a known set, or does it accept arbitrary strings?

**Verification:**
- **File:** `server/internal/handler/daemon.go` lines 166–181
- **Result:** `Runtimes` struct has `Type string` with **no enum, no whitelist, no validation**
- **Behavior:** Handler at lines 273–283 uses `strings.TrimSpace(runtime.Type)` directly as the provider field. Falls back to `"unknown"` only if the string is empty.
- **Conclusion:** ✅ **Works as-is.** LunarWing can register with `"type": "lunarwing"` without any server changes.

---

## Concern #2: Local Skill Endpoints

**Concern:** Does Multica expose the `/api/daemon/runtimes/{id}/local-skills/{requestId}/result` and `/import/{requestId}/result` endpoints with the exact payload shape the channel sends?

**Verification:**
- **Files:**
  - `server/internal/handler/daemon.go` lines 746–753 — heartbeat response construction
  - `server/internal/handler/runtime_local_skills.go` — full endpoint implementation
- **Result:** Both endpoints exist. Heartbeat returns `pending_local_skills` and `pending_local_skill_import` when requests are queued. The server handles POST responses from the runtime with the correct shape (`{skills: [...], supported: bool}` and `{skill: {...}}`).
- **Additional:** Server implements batch import support (up to 10 per heartbeat cycle), timeouts (3 min pending, 60s running), and a `LocalSkillListStore` interface for Redis-backed state.
- **Conclusion:** ✅ **Fully implemented.** The channel's local skill flows are supported.

---

## Concern #3: Skill Export via POST /api/skills

**Concern:** Does Multica have a create/import endpoint accepting `{name, description, content, files}`?

**Verification:**
- **File:** `server/internal/handler/skill.go` lines 189–197, handler at line 319
- **Result:** `CreateSkillRequest` struct matches exactly:
  ```go
  type CreateSkillRequest struct {
      Name        string                   `json:"name"`
      Description string                   `json:"description"`
      Content     string                   `json:"content"`
      Config      any                      `json:"config"`
      Files       []CreateSkillFileRequest `json:"files,omitempty"`
  }
  ```
- **Validation:** Path traversal protection exists (`validateFilePath`), unique name enforced (409 on conflict).
- **Conclusion:** ✅ **Works as-is.** The tool's `export_skill` action maps directly to this endpoint.

---

## Concern #4: Single Token for Daemon and User APIs

**Concern:** Does a PAT (`mul_*`) work on both daemon routes (`/api/daemon/*`) and user routes (`/api/issues/*`, `/api/skills/*`)?

**Verification:**
- **File:** `server/internal/middleware/daemon_auth.go` lines 33–253
- **Result:** `DaemonAuth` middleware explicitly checks multiple token types in order:
  1. `mdt_*` — daemon token (workspace-scoped)
  2. `mul_*` — PAT (user-scoped, falls back to workspace membership check)
  3. `mcn_*` — cloud PAT (external identity)
  4. JWT — bearer token
- **Behavior:** PAT is accepted on daemon routes. The handler code at `daemon.go` lines 277–287 uses `requireWorkspaceMember` for PATs, which validates membership. This means a single `multica_api_token` works for all operations as long as the token's user is a workspace member.
- **Conclusion:** ✅ **Supported.** Single token is sufficient. No separate daemon token needed.

---

## Summary Table

| Concern | Server Change Needed? | Notes |
|---------|---------------------|-------|
| Runtime type "lunarwing" | No | Free-form string, no validation |
| Local skill endpoints | No | Fully implemented, includes batch support |
| Skill export API | No | Exact `{name, description, content, files}` shape |
| Single PAT on all APIs | No | `mul_*` accepted on daemon routes via middleware |

---

## Recommendation

The Multica server is **ready for LunarWing integration** without any modifications. The integration can proceed with:

1. Deploying Multica server (any recent version)
2. Creating a workspace and generating a PAT (`mul_*` token)
3. Configuring LunarWing's `multica-bridge` tool with the server URL, workspace ID, and token
4. Registering LunarWing as a runtime via the `register` action

No Multica server forks, patches, or feature flags required.

---

*Dark Forest Wizard Chief of Engineering — Verified & Approved* ⚡🐴