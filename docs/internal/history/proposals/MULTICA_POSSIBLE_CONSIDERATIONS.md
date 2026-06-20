# A few things that might need attention on the Multica/Lunartica side:

1. Runtime type "lunarwing" — the registration payload sends "type": "lunarwing". If Multica validates runtime types against a known set, it would need to accept this new one (or accept arbitrary strings).
2. Local skill endpoints — the channel handles pending_local_skills and pending_local_skill_import from heartbeat responses, hitting /api/daemon/runtimes/{id}/local-skills/{requestId}/result and .../import/{requestId}/result. If those are newer/optional features in Multica, they may need to be present and match the payload shape the channel sends.
3. Skill export via POST /api/skills — the tool creates skills with {name, description, content, files}. This is user-facing API, not daemon API. Multica would need a create/import endpoint that accepts this shape.
4. Single token for both daemon and user APIs — the code uses one multica_api_token for everything (daemon endpoints like /api/daemon/* and user endpoints like /api/issues/*, /api/skills). This works if Multica accepts PAT tokens on daemon routes, which the integration plan suggests it does — but worth verifying.

* The execution model mismatch (CLI-style runs vs LLM agent loop) is handled entirely on the LunarWing side by the channel/tool translation layer, so that shouldn't require Multica changes.
