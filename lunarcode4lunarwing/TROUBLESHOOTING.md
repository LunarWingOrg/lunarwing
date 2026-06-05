ensure that filesystem on actual fs is owned by user recursively

## Worker can think but can't act (sessionID validation)

**Symptom**: The nanocode worker connects, receives tasks, and the LLM generates correct code — but no tool calls (bash, write, read) execute. Logs show `"Invalid string: must start with \"prt\""` warnings. The worker falls back to writing code without running it.

**Cause**: Nanocode v1.2.28 bug — `PartID` schema validation (`z.string().startsWith("prt")`) is applied to `SessionID` values (`ses_...`) in the permission check path. The strict `schema.parse()` in `src/util/fn.ts` throws on the prefix mismatch, blocking all tool execution.

**Fix**: `patches/fn.ts` is baked into the Docker image via the Dockerfile. It replaces `parse()` with `safeParse()` + fallback. If you rebuild, the fix is automatic.

**If the fix is missing** (e.g. after a rebuild that dropped the Dockerfile line, or on an older image):

```bash
# Hot-patch the running container
docker cp patches/fn.ts <container_id>:/app/nanocode/packages/opencode/src/util/fn.ts
docker restart <container_id>

# Verify
docker exec <container_id> grep -q "safeParse" /app/nanocode/packages/opencode/src/util/fn.ts && echo "patched" || echo "NOT patched"
```

**How to confirm the fix is working**: After restarting, send a `create_job` with a simple task (e.g. "create a file called test.txt with 'hello' and cat it"). If the worker executes the bash/write tools instead of just generating code, the fix is in place.
