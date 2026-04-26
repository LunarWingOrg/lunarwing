For your instance, the DB still shows the old values right now:

  llm_backend = ollama
  openai_compatible_base_url = null
  selected_model = llama3

  So first set them, then restart.

  Use these exact commands:

  BASE=/home/sun/lw_workspace/lunarwing-agent-20260425-235935
  BIN=/home/sun/lw_workspace/lunarwing/ic/target/debug/ironclaw

  IRONCLAW_BASE_DIR="$BASE" NEARAI_AUTH_URL=http://localhost NEARAI_BASE_URL=http://localhost \
    "$BIN" config set llm_backend openai_compatible

  IRONCLAW_BASE_DIR="$BASE" NEARAI_AUTH_URL=http://localhost NEARAI_BASE_URL=http://localhost \
    "$BIN" config set openai_compatible_base_url http://192.168.1.157:3002

  IRONCLAW_BASE_DIR="$BASE" NEARAI_AUTH_URL=http://localhost NEARAI_BASE_URL=http://localhost \
    "$BIN" config set selected_model 'tensorzero::function_name::ironclaw'

  Verify before restarting:

  IRONCLAW_BASE_DIR="$BASE" NEARAI_AUTH_URL=http://localhost NEARAI_BASE_URL=http://localhost \
    "$BIN" config list | rg 'llm_backend|openai_compatible_base_url|selected_model'

  Then restart with:

  IRONCLAW_BASE_DIR="$BASE" HTTP_HOST=127.0.0.1 LLM_API_KEY=unneeded \
    "$BIN" run
