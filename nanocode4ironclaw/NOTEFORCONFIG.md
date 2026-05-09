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

