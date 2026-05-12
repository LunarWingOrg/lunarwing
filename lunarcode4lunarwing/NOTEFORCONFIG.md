  Here's what you need to verify/do on the noko side:

  1. Confirm the deployed binary is the new one:
  # as noko:
  strings /path/to/deployed/lunarwing | grep "External workers configured"

  2. Config.toml must have this exact format — the [[sandbox.external_workers]] is TOML array-of-tables syntax:

  [sandbox]

  [[sandbox.external_workers]]
  name = "nanocode"
  url = "ws://localhost:9090/ws/agent"
  timeout_ms = 300000

  Not [sandbox.external_workers] (single brackets = table, not array) and not nested under an existing [sandbox] header with external_workers = [...] inline array format.

  3. Check the nanocode container is actually running and listening:
  docker ps | grep nanocode
  curl -s http://localhost:8443/ready
● Yeah, the nanocode worker needs an LLM API key to actually do work. Let me check what the container expects.

  Searched for 1 pattern, read 1 file (ctrl+o to expand)

● Bash(docker ps | grep nanocode; echo "---"; docker inspect ironclaw-worker-nanocode-1 2>/dev/null | grep -A2 "TENSORZERO\|NANOGPT\|API_KEY" | head -10)
  ⎿  d3ea60d94fcc   ironclaw-worker-nanocode:latest                 "/usr/bin/tini -- /a…"   18 minutes ago   Up 18 minutes (healthy)         0.0.0.0:8443->8443/tcp, [::]:8443->8443/tcp, 0.0.0.0:9090->9090/
     tcp, [::]:9090->9090/tcp   nanocode4ironclaw-ironclaw-worker-1
     ---

● The nanocode container is running. It's configured to use TensorZero at http://192.168.1.157:3000/openai/v1/ as its LLM backend — same TensorZero proxy that noko uses. So the API key it needs is
  TENSORZERO_API_KEY, which can be dummy if your TZ proxy doesn't enforce auth.

  Check if it's already set in the container:

  docker exec nanocode4ironclaw-ironclaw-worker-1 env | grep -i "API_KEY\|TENSORZERO\|NANOGPT"

  If TENSORZERO_API_KEY is set (even to dummy), the nanocode worker should be able to hit TensorZero and get LLM responses. The key question is whether the TensorZero proxy has a nanocode function configured —
  check your TZ config for that.

✻ Cooked for 21s

