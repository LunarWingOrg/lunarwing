#compdef lunarwing

autoload -U is-at-least

_lunarwing() {
    typeset -A opt_args
    typeset -a _arguments_options
    local ret=1

    if is-at-least 5.2; then
        _arguments_options=(-s -S -C)
    else
        _arguments_options=(-s -C)
    fi

    local context curcontext="$curcontext" state line
    _arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
'-V[Print version]' \
'--version[Print version]' \
":: :_lunarwing_commands" \
"*::: :->lunarwing" \
&& ret=0
    case $state in
    (lunarwing)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-command-$line[1]:"
        case $line[1] in
            (run)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(onboard)
_arguments "${_arguments_options[@]}" : \
'(--channels-only --provider-only --quick)*--step=[Run only specific setup steps (comma-separated\: provider, channels, model, database, security)]:STEP:_default' \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--skip-auth[Skip authentication (use existing session)]' \
'(--provider-only --quick --step)--channels-only[Deprecated\: use --step channels]' \
'(--channels-only --quick --step)--provider-only[Deprecated\: use --step provider]' \
'(--channels-only --provider-only --step)--quick[Quick setup\: auto-defaults everything except LLM provider and model]' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(config)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
":: :_lunarwing__subcmd__config_commands" \
"*::: :->config" \
&& ret=0

    case $state in
    (config)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-config-command-$line[1]:"
        case $line[1] in
            (init)
_arguments "${_arguments_options[@]}" : \
'-o+[Output path (default\: ~/.lunarwing/config.toml)]:OUTPUT:_files' \
'--output=[Output path (default\: ~/.lunarwing/config.toml)]:OUTPUT:_files' \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--force[Overwrite existing file]' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(list)
_arguments "${_arguments_options[@]}" : \
'-f+[Show only settings matching this prefix (e.g., "agent", "heartbeat")]:FILTER:_default' \
'--filter=[Show only settings matching this prefix (e.g., "agent", "heartbeat")]:FILTER:_default' \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(get)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':path -- Setting path (e.g., "agent.max_parallel_jobs"):_default' \
&& ret=0
;;
(set)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':path -- Setting path (e.g., "agent.max_parallel_jobs"):_default' \
':value -- Value to set:_default' \
&& ret=0
;;
(reset)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':path -- Setting path (e.g., "agent.max_parallel_jobs"):_default' \
&& ret=0
;;
(path)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
":: :_lunarwing__subcmd__config__subcmd__help_commands" \
"*::: :->help" \
&& ret=0

    case $state in
    (help)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-config-help-command-$line[1]:"
        case $line[1] in
            (init)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(list)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(get)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(set)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(reset)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(path)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
        esac
    ;;
esac
;;
(tool)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
":: :_lunarwing__subcmd__tool_commands" \
"*::: :->tool" \
&& ret=0

    case $state in
    (tool)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-tool-command-$line[1]:"
        case $line[1] in
            (install)
_arguments "${_arguments_options[@]}" : \
'-n+[Tool name (defaults to directory/file name)]:NAME:_default' \
'--name=[Tool name (defaults to directory/file name)]:NAME:_default' \
'--capabilities=[Path to capabilities JSON file (auto-detected if not specified)]:CAPABILITIES:_files' \
'-t+[Target directory for installation (default\: ~/.lunarwing/tools/)]:TARGET:_files' \
'--target=[Target directory for installation (default\: ~/.lunarwing/tools/)]:TARGET:_files' \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--release[Build in release mode (default\: true)]' \
'--skip-build[Skip compilation (use existing .wasm file)]' \
'-f[Force overwrite if tool already exists]' \
'--force[Force overwrite if tool already exists]' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':path -- Path to tool source directory (with Cargo.toml) or .wasm file:_files' \
&& ret=0
;;
(list)
_arguments "${_arguments_options[@]}" : \
'-d+[Directory to list tools from (default\: ~/.lunarwing/tools/)]:DIR:_files' \
'--dir=[Directory to list tools from (default\: ~/.lunarwing/tools/)]:DIR:_files' \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'-v[Show detailed information]' \
'--verbose[Show detailed information]' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(remove)
_arguments "${_arguments_options[@]}" : \
'-d+[Directory to remove tool from (default\: ~/.lunarwing/tools/)]:DIR:_files' \
'--dir=[Directory to remove tool from (default\: ~/.lunarwing/tools/)]:DIR:_files' \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':name -- Name of the tool to remove:_default' \
&& ret=0
;;
(info)
_arguments "${_arguments_options[@]}" : \
'-d+[Directory to look for tool (default\: ~/.lunarwing/tools/)]:DIR:_files' \
'--dir=[Directory to look for tool (default\: ~/.lunarwing/tools/)]:DIR:_files' \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':name_or_path -- Name of the tool or path to .wasm file:_default' \
&& ret=0
;;
(auth)
_arguments "${_arguments_options[@]}" : \
'-d+[Directory to look for tool (default\: ~/.lunarwing/tools/)]:DIR:_files' \
'--dir=[Directory to look for tool (default\: ~/.lunarwing/tools/)]:DIR:_files' \
'-u+[User ID for storing the secret (default\: "default")]:USER:_default' \
'--user=[User ID for storing the secret (default\: "default")]:USER:_default' \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':name -- Name of the tool:_default' \
&& ret=0
;;
(setup)
_arguments "${_arguments_options[@]}" : \
'-d+[Directory to look for tool (default\: ~/.lunarwing/tools/)]:DIR:_files' \
'--dir=[Directory to look for tool (default\: ~/.lunarwing/tools/)]:DIR:_files' \
'-u+[User ID for storing the secret (default\: "default")]:USER:_default' \
'--user=[User ID for storing the secret (default\: "default")]:USER:_default' \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':name -- Name of the tool:_default' \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
":: :_lunarwing__subcmd__tool__subcmd__help_commands" \
"*::: :->help" \
&& ret=0

    case $state in
    (help)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-tool-help-command-$line[1]:"
        case $line[1] in
            (install)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(list)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(remove)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(info)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(auth)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(setup)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
        esac
    ;;
esac
;;
(registry)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
":: :_lunarwing__subcmd__registry_commands" \
"*::: :->registry" \
&& ret=0

    case $state in
    (registry)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-registry-command-$line[1]:"
        case $line[1] in
            (list)
_arguments "${_arguments_options[@]}" : \
'-k+[Filter by kind\: "tool" or "channel"]:KIND:_default' \
'--kind=[Filter by kind\: "tool" or "channel"]:KIND:_default' \
'-t+[Filter by tag (e.g. "default", "messaging", "lunarwing")]:TAG:_default' \
'--tag=[Filter by tag (e.g. "default", "messaging", "lunarwing")]:TAG:_default' \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'-v[Show detailed information]' \
'--verbose[Show detailed information]' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(info)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':name -- Extension or bundle name (e.g. "gotify", "default", "tools/github"):_default' \
&& ret=0
;;
(install)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'-f[Force overwrite if already installed]' \
'--force[Force overwrite if already installed]' \
'--build[Build from source instead of downloading pre-built artifact]' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':name -- Extension or bundle name (e.g. "gotify", "lunarwing", "default"):_default' \
&& ret=0
;;
(install-defaults)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'-f[Force overwrite if already installed]' \
'--force[Force overwrite if already installed]' \
'--build[Build from source instead of downloading pre-built artifact]' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
":: :_lunarwing__subcmd__registry__subcmd__help_commands" \
"*::: :->help" \
&& ret=0

    case $state in
    (help)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-registry-help-command-$line[1]:"
        case $line[1] in
            (list)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(info)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(install)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(install-defaults)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
        esac
    ;;
esac
;;
(channels)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
":: :_lunarwing__subcmd__channels_commands" \
"*::: :->channels" \
&& ret=0

    case $state in
    (channels)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-channels-command-$line[1]:"
        case $line[1] in
            (list)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'-v[Show detailed information (host, port, config source)]' \
'--verbose[Show detailed information (host, port, config source)]' \
'--json[Output as JSON]' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
":: :_lunarwing__subcmd__channels__subcmd__help_commands" \
"*::: :->help" \
&& ret=0

    case $state in
    (help)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-channels-help-command-$line[1]:"
        case $line[1] in
            (list)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
        esac
    ;;
esac
;;
(reflex)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
":: :_lunarwing__subcmd__reflex_commands" \
"*::: :->reflex" \
&& ret=0

    case $state in
    (reflex)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-reflex-command-$line[1]:"
        case $line[1] in
            (list)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--disabled[Include disabled patterns]' \
'--json[Output as JSON (for scripting)]' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(show)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':id -- Pattern ID (UUID):_default' \
&& ret=0
;;
(delete)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'-y[Skip confirmation prompt]' \
'--yes[Skip confirmation prompt]' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':id -- Pattern ID (UUID):_default' \
&& ret=0
;;
(status)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(prune)
_arguments "${_arguments_options[@]}" : \
'--stale-days=[Patterns not matched in this many days are considered stale]:STALE_DAYS:_default' \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--dry-run[Show what would be evicted without modifying the database]' \
'--json[Output as JSON (for scripting)]' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
":: :_lunarwing__subcmd__reflex__subcmd__help_commands" \
"*::: :->help" \
&& ret=0

    case $state in
    (help)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-reflex-help-command-$line[1]:"
        case $line[1] in
            (list)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(show)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(delete)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(status)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(prune)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
        esac
    ;;
esac
;;
(routines)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
":: :_lunarwing__subcmd__routines_commands" \
"*::: :->routines" \
&& ret=0

    case $state in
    (routines)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-routines-command-$line[1]:"
        case $line[1] in
            (list)
_arguments "${_arguments_options[@]}" : \
'--trigger=[Filter by trigger type (e.g. "cron", "webhook", "event")]:TRIGGER:_default' \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--disabled[Include disabled routines]' \
'--json[Output as JSON (for scripting)]' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(create)
_arguments "${_arguments_options[@]}" : \
'--name=[Routine name (must be unique per user)]:NAME:_default' \
'--schedule=[Cron schedule (6-field\: "sec min hour day month weekday")]:SCHEDULE:_default' \
'--prompt=[Prompt for the LLM]:PROMPT:_default' \
'--description=[Optional description]:DESCRIPTION:_default' \
'--timezone=[IANA timezone (e.g. "America/New_York")]:TIMEZONE:_default' \
'--cooldown=[Cooldown between fires in seconds]:COOLDOWN:_default' \
'--notify-channel=[Notification channel]:NOTIFY_CHANNEL:_default' \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(edit)
_arguments "${_arguments_options[@]}" : \
'--name=[Routine name]:NAME:_default' \
'--schedule=[New schedule]:SCHEDULE:_default' \
'--prompt=[New prompt]:PROMPT:_default' \
'--description=[New description]:DESCRIPTION:_default' \
'--timezone=[New timezone]:TIMEZONE:_default' \
'--cooldown=[New cooldown in seconds]:COOLDOWN:_default' \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(enable)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':name -- Routine name:_default' \
&& ret=0
;;
(disable)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':name -- Routine name:_default' \
&& ret=0
;;
(delete)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'-y[Skip confirmation prompt]' \
'--yes[Skip confirmation prompt]' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':name -- Routine name:_default' \
&& ret=0
;;
(history)
_arguments "${_arguments_options[@]}" : \
'-l+[Maximum number of runs to show]:LIMIT:_default' \
'--limit=[Maximum number of runs to show]:LIMIT:_default' \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--json[Output as JSON (for scripting)]' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':name -- Routine name:_default' \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
":: :_lunarwing__subcmd__routines__subcmd__help_commands" \
"*::: :->help" \
&& ret=0

    case $state in
    (help)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-routines-help-command-$line[1]:"
        case $line[1] in
            (list)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(create)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(edit)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(enable)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(disable)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(delete)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(history)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
        esac
    ;;
esac
;;
(mcp)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
":: :_lunarwing__subcmd__mcp_commands" \
"*::: :->mcp" \
&& ret=0

    case $state in
    (mcp)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-mcp-command-$line[1]:"
        case $line[1] in
            (add)
_arguments "${_arguments_options[@]}" : \
'--transport=[Transport type\: http (default), stdio, unix]:TRANSPORT:_default' \
'--command=[Command to run (stdio transport)]:COMMAND:_default' \
'*--arg=[Command arguments (stdio transport, can be repeated)]:CMD_ARGS:_default' \
'*--env=[Environment variables (stdio transport, KEY=VALUE format, can be repeated)]:ENV:_default' \
'--socket=[Unix socket path (unix transport)]:SOCKET:_default' \
'*--header=[Custom HTTP headers (KEY\:VALUE format, can be repeated)]:HEADERS:_default' \
'--client-id=[OAuth client ID (if authentication is required)]:CLIENT_ID:_default' \
'--auth-url=[OAuth authorization URL (optional, can be discovered)]:AUTH_URL:_default' \
'--token-url=[OAuth token URL (optional, can be discovered)]:TOKEN_URL:_default' \
'--scopes=[Scopes to request (comma-separated)]:SCOPES:_default' \
'--description=[Server description]:DESCRIPTION:_default' \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':name -- Server name (e.g., "notion", "github"):_default' \
'::url -- Server URL (e.g., "https\://mcp.notion.com") -- required for http transport:_default' \
&& ret=0
;;
(remove)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':name -- Server name to remove:_default' \
&& ret=0
;;
(list)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'-v[Show detailed information]' \
'--verbose[Show detailed information]' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(auth)
_arguments "${_arguments_options[@]}" : \
'-u+[User ID for storing the token (default\: "default")]:USER:_default' \
'--user=[User ID for storing the token (default\: "default")]:USER:_default' \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':name -- Server name to authenticate:_default' \
&& ret=0
;;
(test)
_arguments "${_arguments_options[@]}" : \
'-u+[User ID for authentication (default\: "default")]:USER:_default' \
'--user=[User ID for authentication (default\: "default")]:USER:_default' \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':name -- Server name to test:_default' \
&& ret=0
;;
(toggle)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'(--disable)--enable[Enable the server]' \
'(--enable)--disable[Disable the server]' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':name -- Server name:_default' \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
":: :_lunarwing__subcmd__mcp__subcmd__help_commands" \
"*::: :->help" \
&& ret=0

    case $state in
    (help)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-mcp-help-command-$line[1]:"
        case $line[1] in
            (add)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(remove)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(list)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(auth)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(test)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(toggle)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
        esac
    ;;
esac
;;
(memory)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
":: :_lunarwing__subcmd__memory_commands" \
"*::: :->memory" \
&& ret=0

    case $state in
    (memory)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-memory-command-$line[1]:"
        case $line[1] in
            (search)
_arguments "${_arguments_options[@]}" : \
'-l+[Maximum number of results]:LIMIT:_default' \
'--limit=[Maximum number of results]:LIMIT:_default' \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':query -- Search query:_default' \
&& ret=0
;;
(read)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':path -- File path (e.g., "MEMORY.md", "daily/2024-01-15.md"):_default' \
&& ret=0
;;
(write)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'-a[Append instead of overwrite]' \
'--append[Append instead of overwrite]' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':path -- File path (e.g., "notes/idea.md"):_default' \
'::content -- Content to write (omit to read from stdin):_default' \
&& ret=0
;;
(tree)
_arguments "${_arguments_options[@]}" : \
'-d+[Maximum depth to traverse]:DEPTH:_default' \
'--depth=[Maximum depth to traverse]:DEPTH:_default' \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
'::path -- Root path to start from:_default' \
&& ret=0
;;
(status)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
":: :_lunarwing__subcmd__memory__subcmd__help_commands" \
"*::: :->help" \
&& ret=0

    case $state in
    (help)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-memory-help-command-$line[1]:"
        case $line[1] in
            (search)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(read)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(write)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(tree)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(status)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
        esac
    ;;
esac
;;
(pairing)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
":: :_lunarwing__subcmd__pairing_commands" \
"*::: :->pairing" \
&& ret=0

    case $state in
    (pairing)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-pairing-command-$line[1]:"
        case $line[1] in
            (list)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--json[Output as JSON]' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':channel -- Channel name (e.g., telegram, xmpp):_default' \
&& ret=0
;;
(approve)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':channel -- Channel name (e.g., telegram, xmpp):_default' \
':code -- Pairing code (e.g., ABC12345):_default' \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
":: :_lunarwing__subcmd__pairing__subcmd__help_commands" \
"*::: :->help" \
&& ret=0

    case $state in
    (help)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-pairing-help-command-$line[1]:"
        case $line[1] in
            (list)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(approve)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
        esac
    ;;
esac
;;
(service)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
":: :_lunarwing__subcmd__service_commands" \
"*::: :->service" \
&& ret=0

    case $state in
    (service)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-service-command-$line[1]:"
        case $line[1] in
            (install)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(start)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(stop)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(status)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(uninstall)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
":: :_lunarwing__subcmd__service__subcmd__help_commands" \
"*::: :->help" \
&& ret=0

    case $state in
    (help)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-service-help-command-$line[1]:"
        case $line[1] in
            (install)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(start)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(stop)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(status)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(uninstall)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
        esac
    ;;
esac
;;
(repl)
_arguments "${_arguments_options[@]}" : \
'--socket=[Path to the Unix socket]:SOCKET:_files' \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(skills)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
":: :_lunarwing__subcmd__skills_commands" \
"*::: :->skills" \
&& ret=0

    case $state in
    (skills)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-skills-command-$line[1]:"
        case $line[1] in
            (list)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'-v[Show detailed information (keywords, patterns, source path)]' \
'--verbose[Show detailed information (keywords, patterns, source path)]' \
'--json[Output as JSON]' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(search)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--json[Output as JSON]' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':query -- Search query:_default' \
&& ret=0
;;
(info)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--json[Output as JSON]' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':name -- Skill name:_default' \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
":: :_lunarwing__subcmd__skills__subcmd__help_commands" \
"*::: :->help" \
&& ret=0

    case $state in
    (help)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-skills-help-command-$line[1]:"
        case $line[1] in
            (list)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(search)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(info)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
        esac
    ;;
esac
;;
(hooks)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
":: :_lunarwing__subcmd__hooks_commands" \
"*::: :->hooks" \
&& ret=0

    case $state in
    (hooks)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-hooks-command-$line[1]:"
        case $line[1] in
            (list)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'-v[Show detailed information (hook points, priority, failure mode)]' \
'--verbose[Show detailed information (hook points, priority, failure mode)]' \
'--json[Output as JSON]' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
":: :_lunarwing__subcmd__hooks__subcmd__help_commands" \
"*::: :->help" \
&& ret=0

    case $state in
    (help)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-hooks-help-command-$line[1]:"
        case $line[1] in
            (list)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
        esac
    ;;
esac
;;
(models)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
":: :_lunarwing__subcmd__models_commands" \
"*::: :->models" \
&& ret=0

    case $state in
    (models)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-models-command-$line[1]:"
        case $line[1] in
            (list)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'-v[Show detailed information (env vars, base URL, protocol)]' \
'--verbose[Show detailed information (env vars, base URL, protocol)]' \
'--json[Output as JSON]' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
'::provider -- Show only a specific provider (by ID or alias):_default' \
&& ret=0
;;
(status)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--json[Output as JSON]' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(set)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':model -- Model name (e.g., "gpt-5-mini", "claude-sonnet-4-6-20250514"):_default' \
&& ret=0
;;
(set-provider)
_arguments "${_arguments_options[@]}" : \
'--model=[Also set the model (defaults to provider'\''s default model)]:MODEL:_default' \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':provider -- Provider ID or alias (e.g., "openai", "anthropic", "ollama"):_default' \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
":: :_lunarwing__subcmd__models__subcmd__help_commands" \
"*::: :->help" \
&& ret=0

    case $state in
    (help)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-models-help-command-$line[1]:"
        case $line[1] in
            (list)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(status)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(set)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(set-provider)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
        esac
    ;;
esac
;;
(doctor)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(logs)
_arguments "${_arguments_options[@]}" : \
'-l+[Maximum number of lines to show (default\: 200)]:LIMIT:_default' \
'--limit=[Maximum number of lines to show (default\: 200)]:LIMIT:_default' \
'--url=[Gateway URL (default\: http\://{GATEWAY_HOST}\:{GATEWAY_PORT})]:URL:_default' \
'--token=[Gateway auth token (reads GATEWAY_AUTH_TOKEN env if not set)]:TOKEN:_default' \
'--timeout=[Connection timeout in milliseconds (default\: 5000)]:TIMEOUT:_default' \
'--level=[Get or set runtime log level. Without a value, shows current level. With a value (trace|debug|info|warn|error), sets the level]::LEVEL:_default' \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'-f[Stream live logs from the running gateway via SSE. Replays recent history then streams new entries in real time]' \
'--follow[Stream live logs from the running gateway via SSE. Replays recent history then streams new entries in real time]' \
'--json[Output log entries as JSON (one object per line)]' \
'--local-time[Display timestamps in local timezone]' \
'--plain[Plain text output (no ANSI styling)]' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(status)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(completion)
_arguments "${_arguments_options[@]}" : \
'--shell=[The shell to generate completions for]:SHELL:(bash elvish fish powershell zsh)' \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(login)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--openai-codex[Authenticate with OpenAI Codex (ChatGPT subscription)]' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(worker)
_arguments "${_arguments_options[@]}" : \
'--job-id=[Job ID to execute]:JOB_ID:_default' \
'--orchestrator-url=[URL of the orchestrator'\''s internal API]:ORCHESTRATOR_URL:_default' \
'--max-iterations=[Maximum iterations before stopping]:MAX_ITERATIONS:_default' \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(acp)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
":: :_lunarwing__subcmd__acp_commands" \
"*::: :->acp" \
&& ret=0

    case $state in
    (acp)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-acp-command-$line[1]:"
        case $line[1] in
            (add)
_arguments "${_arguments_options[@]}" : \
'--command=[Command to spawn the agent]:COMMAND:_default' \
'*--arg=[Command arguments (can be repeated)]:ARGS:_default' \
'*--env=[Environment variables (KEY=VALUE format, can be repeated)]:ENV:_default' \
'--description=[Agent description]:DESCRIPTION:_default' \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':name -- Agent name (e.g., "goose", "codex", "gemini"):_default' \
&& ret=0
;;
(remove)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':name -- Agent name to remove:_default' \
&& ret=0
;;
(list)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(toggle)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':name -- Agent name to toggle:_default' \
&& ret=0
;;
(test)
_arguments "${_arguments_options[@]}" : \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
':name -- Agent name to test:_default' \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
":: :_lunarwing__subcmd__acp__subcmd__help_commands" \
"*::: :->help" \
&& ret=0

    case $state in
    (help)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-acp-help-command-$line[1]:"
        case $line[1] in
            (add)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(remove)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(list)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(toggle)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(test)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
        esac
    ;;
esac
;;
(acp-bridge)
_arguments "${_arguments_options[@]}" : \
'--job-id=[Job ID to execute]:JOB_ID:_default' \
'--orchestrator-url=[URL of the orchestrator'\''s internal API]:ORCHESTRATOR_URL:_default' \
'-m+[Single message mode - send one message and exit]:MESSAGE:_default' \
'--message=[Single message mode - send one message and exit]:MESSAGE:_default' \
'-c+[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--config=[Configuration file path (optional, uses env vars by default)]:CONFIG:_files' \
'--cli-only[Run in interactive CLI mode only (disable other channels)]' \
'--no-db[Skip database connection (for testing)]' \
'--no-onboard[Skip first-run onboarding check]' \
'--auto-approve[Auto-approve tool execution (shell, file writes, HTTP, etc.)]' \
'--supervised[Enable supervised mode — every tool action requires human approval regardless of the tool'\''s normal tier]' \
'-h[Print help (see more with '\''--help'\'')]' \
'--help[Print help (see more with '\''--help'\'')]' \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
":: :_lunarwing__subcmd__help_commands" \
"*::: :->help" \
&& ret=0

    case $state in
    (help)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-help-command-$line[1]:"
        case $line[1] in
            (run)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(onboard)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(config)
_arguments "${_arguments_options[@]}" : \
":: :_lunarwing__subcmd__help__subcmd__config_commands" \
"*::: :->config" \
&& ret=0

    case $state in
    (config)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-help-config-command-$line[1]:"
        case $line[1] in
            (init)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(list)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(get)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(set)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(reset)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(path)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
(tool)
_arguments "${_arguments_options[@]}" : \
":: :_lunarwing__subcmd__help__subcmd__tool_commands" \
"*::: :->tool" \
&& ret=0

    case $state in
    (tool)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-help-tool-command-$line[1]:"
        case $line[1] in
            (install)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(list)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(remove)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(info)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(auth)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(setup)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
(registry)
_arguments "${_arguments_options[@]}" : \
":: :_lunarwing__subcmd__help__subcmd__registry_commands" \
"*::: :->registry" \
&& ret=0

    case $state in
    (registry)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-help-registry-command-$line[1]:"
        case $line[1] in
            (list)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(info)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(install)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(install-defaults)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
(channels)
_arguments "${_arguments_options[@]}" : \
":: :_lunarwing__subcmd__help__subcmd__channels_commands" \
"*::: :->channels" \
&& ret=0

    case $state in
    (channels)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-help-channels-command-$line[1]:"
        case $line[1] in
            (list)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
(reflex)
_arguments "${_arguments_options[@]}" : \
":: :_lunarwing__subcmd__help__subcmd__reflex_commands" \
"*::: :->reflex" \
&& ret=0

    case $state in
    (reflex)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-help-reflex-command-$line[1]:"
        case $line[1] in
            (list)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(show)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(delete)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(status)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(prune)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
(routines)
_arguments "${_arguments_options[@]}" : \
":: :_lunarwing__subcmd__help__subcmd__routines_commands" \
"*::: :->routines" \
&& ret=0

    case $state in
    (routines)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-help-routines-command-$line[1]:"
        case $line[1] in
            (list)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(create)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(edit)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(enable)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(disable)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(delete)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(history)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
(mcp)
_arguments "${_arguments_options[@]}" : \
":: :_lunarwing__subcmd__help__subcmd__mcp_commands" \
"*::: :->mcp" \
&& ret=0

    case $state in
    (mcp)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-help-mcp-command-$line[1]:"
        case $line[1] in
            (add)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(remove)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(list)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(auth)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(test)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(toggle)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
(memory)
_arguments "${_arguments_options[@]}" : \
":: :_lunarwing__subcmd__help__subcmd__memory_commands" \
"*::: :->memory" \
&& ret=0

    case $state in
    (memory)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-help-memory-command-$line[1]:"
        case $line[1] in
            (search)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(read)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(write)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(tree)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(status)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
(pairing)
_arguments "${_arguments_options[@]}" : \
":: :_lunarwing__subcmd__help__subcmd__pairing_commands" \
"*::: :->pairing" \
&& ret=0

    case $state in
    (pairing)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-help-pairing-command-$line[1]:"
        case $line[1] in
            (list)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(approve)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
(service)
_arguments "${_arguments_options[@]}" : \
":: :_lunarwing__subcmd__help__subcmd__service_commands" \
"*::: :->service" \
&& ret=0

    case $state in
    (service)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-help-service-command-$line[1]:"
        case $line[1] in
            (install)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(start)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(stop)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(status)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(uninstall)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
(repl)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(skills)
_arguments "${_arguments_options[@]}" : \
":: :_lunarwing__subcmd__help__subcmd__skills_commands" \
"*::: :->skills" \
&& ret=0

    case $state in
    (skills)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-help-skills-command-$line[1]:"
        case $line[1] in
            (list)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(search)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(info)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
(hooks)
_arguments "${_arguments_options[@]}" : \
":: :_lunarwing__subcmd__help__subcmd__hooks_commands" \
"*::: :->hooks" \
&& ret=0

    case $state in
    (hooks)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-help-hooks-command-$line[1]:"
        case $line[1] in
            (list)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
(models)
_arguments "${_arguments_options[@]}" : \
":: :_lunarwing__subcmd__help__subcmd__models_commands" \
"*::: :->models" \
&& ret=0

    case $state in
    (models)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-help-models-command-$line[1]:"
        case $line[1] in
            (list)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(status)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(set)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(set-provider)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
(doctor)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(logs)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(status)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(completion)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(login)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(worker)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(acp)
_arguments "${_arguments_options[@]}" : \
":: :_lunarwing__subcmd__help__subcmd__acp_commands" \
"*::: :->acp" \
&& ret=0

    case $state in
    (acp)
        words=($line[1] "${words[@]}")
        (( CURRENT += 1 ))
        curcontext="${curcontext%:*:*}:lunarwing-help-acp-command-$line[1]:"
        case $line[1] in
            (add)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(remove)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(list)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(toggle)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(test)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
(acp-bridge)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
(help)
_arguments "${_arguments_options[@]}" : \
&& ret=0
;;
        esac
    ;;
esac
;;
        esac
    ;;
esac
}

(( $+functions[_lunarwing_commands] )) ||
_lunarwing_commands() {
    local commands; commands=(
'run:Run the AI agent' \
'onboard:Run interactive setup wizard' \
'config:Manage app configs' \
'tool:Manage WASM tools' \
'registry:Browse/install extensions' \
'channels:Manage channels' \
'reflex:Manage reflex patterns' \
'routines:Manage routines' \
'mcp:Manage MCP servers' \
'memory:Manage workspace memory' \
'pairing:Manage DM pairing' \
'service:Manage OS service' \
'repl:Connect to running daemon via REPL' \
'skills:Manage skills' \
'hooks:Manage lifecycle hooks' \
'models:Manage LLM providers and models' \
'doctor:Run diagnostics' \
'logs:View and manage gateway logs' \
'status:Show system status' \
'completion:Generate completions' \
'login:Authenticate with a provider' \
'worker:Run as a sandboxed worker inside a Docker container (internal use). This is invoked automatically by the orchestrator, not by users directly' \
'acp:Manage ACP agents' \
'acp-bridge:Run as an ACP bridge inside a Docker container (internal use)' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__acp_commands] )) ||
_lunarwing__subcmd__acp_commands() {
    local commands; commands=(
'add:Add an ACP agent' \
'remove:Remove an ACP agent' \
'list:List configured ACP agents' \
'toggle:Enable or disable an ACP agent' \
'test:Test an ACP agent connection (spawn, handshake, report)' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing acp commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__acp__subcmd__add_commands] )) ||
_lunarwing__subcmd__acp__subcmd__add_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing acp add commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__acp__subcmd__help_commands] )) ||
_lunarwing__subcmd__acp__subcmd__help_commands() {
    local commands; commands=(
'add:Add an ACP agent' \
'remove:Remove an ACP agent' \
'list:List configured ACP agents' \
'toggle:Enable or disable an ACP agent' \
'test:Test an ACP agent connection (spawn, handshake, report)' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing acp help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__acp__subcmd__help__subcmd__add_commands] )) ||
_lunarwing__subcmd__acp__subcmd__help__subcmd__add_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing acp help add commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__acp__subcmd__help__subcmd__help_commands] )) ||
_lunarwing__subcmd__acp__subcmd__help__subcmd__help_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing acp help help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__acp__subcmd__help__subcmd__list_commands] )) ||
_lunarwing__subcmd__acp__subcmd__help__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing acp help list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__acp__subcmd__help__subcmd__remove_commands] )) ||
_lunarwing__subcmd__acp__subcmd__help__subcmd__remove_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing acp help remove commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__acp__subcmd__help__subcmd__test_commands] )) ||
_lunarwing__subcmd__acp__subcmd__help__subcmd__test_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing acp help test commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__acp__subcmd__help__subcmd__toggle_commands] )) ||
_lunarwing__subcmd__acp__subcmd__help__subcmd__toggle_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing acp help toggle commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__acp__subcmd__list_commands] )) ||
_lunarwing__subcmd__acp__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing acp list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__acp__subcmd__remove_commands] )) ||
_lunarwing__subcmd__acp__subcmd__remove_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing acp remove commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__acp__subcmd__test_commands] )) ||
_lunarwing__subcmd__acp__subcmd__test_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing acp test commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__acp__subcmd__toggle_commands] )) ||
_lunarwing__subcmd__acp__subcmd__toggle_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing acp toggle commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__acp-bridge_commands] )) ||
_lunarwing__subcmd__acp-bridge_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing acp-bridge commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__channels_commands] )) ||
_lunarwing__subcmd__channels_commands() {
    local commands; commands=(
'list:List all configured channels' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing channels commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__channels__subcmd__help_commands] )) ||
_lunarwing__subcmd__channels__subcmd__help_commands() {
    local commands; commands=(
'list:List all configured channels' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing channels help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__channels__subcmd__help__subcmd__help_commands] )) ||
_lunarwing__subcmd__channels__subcmd__help__subcmd__help_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing channels help help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__channels__subcmd__help__subcmd__list_commands] )) ||
_lunarwing__subcmd__channels__subcmd__help__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing channels help list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__channels__subcmd__list_commands] )) ||
_lunarwing__subcmd__channels__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing channels list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__completion_commands] )) ||
_lunarwing__subcmd__completion_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing completion commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__config_commands] )) ||
_lunarwing__subcmd__config_commands() {
    local commands; commands=(
'init:Generate a default config.toml file' \
'list:List all settings and their current values' \
'get:Get a specific setting value' \
'set:Set a setting value' \
'reset:Reset a setting to its default value' \
'path:Show the settings storage info' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing config commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__config__subcmd__get_commands] )) ||
_lunarwing__subcmd__config__subcmd__get_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing config get commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__config__subcmd__help_commands] )) ||
_lunarwing__subcmd__config__subcmd__help_commands() {
    local commands; commands=(
'init:Generate a default config.toml file' \
'list:List all settings and their current values' \
'get:Get a specific setting value' \
'set:Set a setting value' \
'reset:Reset a setting to its default value' \
'path:Show the settings storage info' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing config help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__config__subcmd__help__subcmd__get_commands] )) ||
_lunarwing__subcmd__config__subcmd__help__subcmd__get_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing config help get commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__config__subcmd__help__subcmd__help_commands] )) ||
_lunarwing__subcmd__config__subcmd__help__subcmd__help_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing config help help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__config__subcmd__help__subcmd__init_commands] )) ||
_lunarwing__subcmd__config__subcmd__help__subcmd__init_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing config help init commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__config__subcmd__help__subcmd__list_commands] )) ||
_lunarwing__subcmd__config__subcmd__help__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing config help list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__config__subcmd__help__subcmd__path_commands] )) ||
_lunarwing__subcmd__config__subcmd__help__subcmd__path_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing config help path commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__config__subcmd__help__subcmd__reset_commands] )) ||
_lunarwing__subcmd__config__subcmd__help__subcmd__reset_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing config help reset commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__config__subcmd__help__subcmd__set_commands] )) ||
_lunarwing__subcmd__config__subcmd__help__subcmd__set_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing config help set commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__config__subcmd__init_commands] )) ||
_lunarwing__subcmd__config__subcmd__init_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing config init commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__config__subcmd__list_commands] )) ||
_lunarwing__subcmd__config__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing config list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__config__subcmd__path_commands] )) ||
_lunarwing__subcmd__config__subcmd__path_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing config path commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__config__subcmd__reset_commands] )) ||
_lunarwing__subcmd__config__subcmd__reset_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing config reset commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__config__subcmd__set_commands] )) ||
_lunarwing__subcmd__config__subcmd__set_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing config set commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__doctor_commands] )) ||
_lunarwing__subcmd__doctor_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing doctor commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help_commands] )) ||
_lunarwing__subcmd__help_commands() {
    local commands; commands=(
'run:Run the AI agent' \
'onboard:Run interactive setup wizard' \
'config:Manage app configs' \
'tool:Manage WASM tools' \
'registry:Browse/install extensions' \
'channels:Manage channels' \
'reflex:Manage reflex patterns' \
'routines:Manage routines' \
'mcp:Manage MCP servers' \
'memory:Manage workspace memory' \
'pairing:Manage DM pairing' \
'service:Manage OS service' \
'repl:Connect to running daemon via REPL' \
'skills:Manage skills' \
'hooks:Manage lifecycle hooks' \
'models:Manage LLM providers and models' \
'doctor:Run diagnostics' \
'logs:View and manage gateway logs' \
'status:Show system status' \
'completion:Generate completions' \
'login:Authenticate with a provider' \
'worker:Run as a sandboxed worker inside a Docker container (internal use). This is invoked automatically by the orchestrator, not by users directly' \
'acp:Manage ACP agents' \
'acp-bridge:Run as an ACP bridge inside a Docker container (internal use)' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__acp_commands] )) ||
_lunarwing__subcmd__help__subcmd__acp_commands() {
    local commands; commands=(
'add:Add an ACP agent' \
'remove:Remove an ACP agent' \
'list:List configured ACP agents' \
'toggle:Enable or disable an ACP agent' \
'test:Test an ACP agent connection (spawn, handshake, report)' \
    )
    _describe -t commands 'lunarwing help acp commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__acp__subcmd__add_commands] )) ||
_lunarwing__subcmd__help__subcmd__acp__subcmd__add_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help acp add commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__acp__subcmd__list_commands] )) ||
_lunarwing__subcmd__help__subcmd__acp__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help acp list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__acp__subcmd__remove_commands] )) ||
_lunarwing__subcmd__help__subcmd__acp__subcmd__remove_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help acp remove commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__acp__subcmd__test_commands] )) ||
_lunarwing__subcmd__help__subcmd__acp__subcmd__test_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help acp test commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__acp__subcmd__toggle_commands] )) ||
_lunarwing__subcmd__help__subcmd__acp__subcmd__toggle_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help acp toggle commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__acp-bridge_commands] )) ||
_lunarwing__subcmd__help__subcmd__acp-bridge_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help acp-bridge commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__channels_commands] )) ||
_lunarwing__subcmd__help__subcmd__channels_commands() {
    local commands; commands=(
'list:List all configured channels' \
    )
    _describe -t commands 'lunarwing help channels commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__channels__subcmd__list_commands] )) ||
_lunarwing__subcmd__help__subcmd__channels__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help channels list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__completion_commands] )) ||
_lunarwing__subcmd__help__subcmd__completion_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help completion commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__config_commands] )) ||
_lunarwing__subcmd__help__subcmd__config_commands() {
    local commands; commands=(
'init:Generate a default config.toml file' \
'list:List all settings and their current values' \
'get:Get a specific setting value' \
'set:Set a setting value' \
'reset:Reset a setting to its default value' \
'path:Show the settings storage info' \
    )
    _describe -t commands 'lunarwing help config commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__config__subcmd__get_commands] )) ||
_lunarwing__subcmd__help__subcmd__config__subcmd__get_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help config get commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__config__subcmd__init_commands] )) ||
_lunarwing__subcmd__help__subcmd__config__subcmd__init_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help config init commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__config__subcmd__list_commands] )) ||
_lunarwing__subcmd__help__subcmd__config__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help config list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__config__subcmd__path_commands] )) ||
_lunarwing__subcmd__help__subcmd__config__subcmd__path_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help config path commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__config__subcmd__reset_commands] )) ||
_lunarwing__subcmd__help__subcmd__config__subcmd__reset_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help config reset commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__config__subcmd__set_commands] )) ||
_lunarwing__subcmd__help__subcmd__config__subcmd__set_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help config set commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__doctor_commands] )) ||
_lunarwing__subcmd__help__subcmd__doctor_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help doctor commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__help_commands] )) ||
_lunarwing__subcmd__help__subcmd__help_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__hooks_commands] )) ||
_lunarwing__subcmd__help__subcmd__hooks_commands() {
    local commands; commands=(
'list:List discoverable hooks (bundled + plugin; not filtered by active extensions)' \
    )
    _describe -t commands 'lunarwing help hooks commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__hooks__subcmd__list_commands] )) ||
_lunarwing__subcmd__help__subcmd__hooks__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help hooks list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__login_commands] )) ||
_lunarwing__subcmd__help__subcmd__login_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help login commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__logs_commands] )) ||
_lunarwing__subcmd__help__subcmd__logs_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help logs commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__mcp_commands] )) ||
_lunarwing__subcmd__help__subcmd__mcp_commands() {
    local commands; commands=(
'add:Add an MCP server' \
'remove:Remove an MCP server' \
'list:List configured MCP servers' \
'auth:Authenticate with an MCP server (OAuth flow)' \
'test:Test connection to an MCP server' \
'toggle:Enable or disable an MCP server' \
    )
    _describe -t commands 'lunarwing help mcp commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__mcp__subcmd__add_commands] )) ||
_lunarwing__subcmd__help__subcmd__mcp__subcmd__add_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help mcp add commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__mcp__subcmd__auth_commands] )) ||
_lunarwing__subcmd__help__subcmd__mcp__subcmd__auth_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help mcp auth commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__mcp__subcmd__list_commands] )) ||
_lunarwing__subcmd__help__subcmd__mcp__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help mcp list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__mcp__subcmd__remove_commands] )) ||
_lunarwing__subcmd__help__subcmd__mcp__subcmd__remove_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help mcp remove commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__mcp__subcmd__test_commands] )) ||
_lunarwing__subcmd__help__subcmd__mcp__subcmd__test_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help mcp test commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__mcp__subcmd__toggle_commands] )) ||
_lunarwing__subcmd__help__subcmd__mcp__subcmd__toggle_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help mcp toggle commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__memory_commands] )) ||
_lunarwing__subcmd__help__subcmd__memory_commands() {
    local commands; commands=(
'search:Search workspace memory (hybrid full-text + semantic)' \
'read:Read a file from the workspace' \
'write:Write content to a workspace file' \
'tree:Show workspace directory tree' \
'status:Show workspace status (document count, index health)' \
    )
    _describe -t commands 'lunarwing help memory commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__memory__subcmd__read_commands] )) ||
_lunarwing__subcmd__help__subcmd__memory__subcmd__read_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help memory read commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__memory__subcmd__search_commands] )) ||
_lunarwing__subcmd__help__subcmd__memory__subcmd__search_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help memory search commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__memory__subcmd__status_commands] )) ||
_lunarwing__subcmd__help__subcmd__memory__subcmd__status_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help memory status commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__memory__subcmd__tree_commands] )) ||
_lunarwing__subcmd__help__subcmd__memory__subcmd__tree_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help memory tree commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__memory__subcmd__write_commands] )) ||
_lunarwing__subcmd__help__subcmd__memory__subcmd__write_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help memory write commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__models_commands] )) ||
_lunarwing__subcmd__help__subcmd__models_commands() {
    local commands; commands=(
'list:List providers (or available models for a specific provider)' \
'status:Show current model configuration' \
'set:Set the default model' \
'set-provider:Set the LLM provider' \
    )
    _describe -t commands 'lunarwing help models commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__models__subcmd__list_commands] )) ||
_lunarwing__subcmd__help__subcmd__models__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help models list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__models__subcmd__set_commands] )) ||
_lunarwing__subcmd__help__subcmd__models__subcmd__set_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help models set commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__models__subcmd__set-provider_commands] )) ||
_lunarwing__subcmd__help__subcmd__models__subcmd__set-provider_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help models set-provider commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__models__subcmd__status_commands] )) ||
_lunarwing__subcmd__help__subcmd__models__subcmd__status_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help models status commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__onboard_commands] )) ||
_lunarwing__subcmd__help__subcmd__onboard_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help onboard commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__pairing_commands] )) ||
_lunarwing__subcmd__help__subcmd__pairing_commands() {
    local commands; commands=(
'list:List pending pairing requests' \
'approve:Approve a pairing request by code' \
    )
    _describe -t commands 'lunarwing help pairing commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__pairing__subcmd__approve_commands] )) ||
_lunarwing__subcmd__help__subcmd__pairing__subcmd__approve_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help pairing approve commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__pairing__subcmd__list_commands] )) ||
_lunarwing__subcmd__help__subcmd__pairing__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help pairing list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__reflex_commands] )) ||
_lunarwing__subcmd__help__subcmd__reflex_commands() {
    local commands; commands=(
'list:List reflex patterns' \
'show:Show details for a specific reflex pattern' \
'delete:Delete a reflex pattern' \
'status:Show reflex compiler status' \
'prune:Prune (auto-disable) reflex patterns that haven'\''t matched recently' \
    )
    _describe -t commands 'lunarwing help reflex commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__reflex__subcmd__delete_commands] )) ||
_lunarwing__subcmd__help__subcmd__reflex__subcmd__delete_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help reflex delete commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__reflex__subcmd__list_commands] )) ||
_lunarwing__subcmd__help__subcmd__reflex__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help reflex list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__reflex__subcmd__prune_commands] )) ||
_lunarwing__subcmd__help__subcmd__reflex__subcmd__prune_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help reflex prune commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__reflex__subcmd__show_commands] )) ||
_lunarwing__subcmd__help__subcmd__reflex__subcmd__show_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help reflex show commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__reflex__subcmd__status_commands] )) ||
_lunarwing__subcmd__help__subcmd__reflex__subcmd__status_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help reflex status commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__registry_commands] )) ||
_lunarwing__subcmd__help__subcmd__registry_commands() {
    local commands; commands=(
'list:List available extensions in the registry' \
'info:Show detailed information about an extension or bundle' \
'install:Install an extension or bundle from the registry' \
'install-defaults:Install the default bundle of recommended extensions' \
    )
    _describe -t commands 'lunarwing help registry commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__registry__subcmd__info_commands] )) ||
_lunarwing__subcmd__help__subcmd__registry__subcmd__info_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help registry info commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__registry__subcmd__install_commands] )) ||
_lunarwing__subcmd__help__subcmd__registry__subcmd__install_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help registry install commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__registry__subcmd__install-defaults_commands] )) ||
_lunarwing__subcmd__help__subcmd__registry__subcmd__install-defaults_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help registry install-defaults commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__registry__subcmd__list_commands] )) ||
_lunarwing__subcmd__help__subcmd__registry__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help registry list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__repl_commands] )) ||
_lunarwing__subcmd__help__subcmd__repl_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help repl commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__routines_commands] )) ||
_lunarwing__subcmd__help__subcmd__routines_commands() {
    local commands; commands=(
'list:List routines' \
'create:Create a new cron routine' \
'edit:Edit an existing routine' \
'enable:Enable a routine' \
'disable:Disable a routine' \
'delete:Delete a routine' \
'history:Show run history for a routine' \
    )
    _describe -t commands 'lunarwing help routines commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__routines__subcmd__create_commands] )) ||
_lunarwing__subcmd__help__subcmd__routines__subcmd__create_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help routines create commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__routines__subcmd__delete_commands] )) ||
_lunarwing__subcmd__help__subcmd__routines__subcmd__delete_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help routines delete commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__routines__subcmd__disable_commands] )) ||
_lunarwing__subcmd__help__subcmd__routines__subcmd__disable_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help routines disable commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__routines__subcmd__edit_commands] )) ||
_lunarwing__subcmd__help__subcmd__routines__subcmd__edit_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help routines edit commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__routines__subcmd__enable_commands] )) ||
_lunarwing__subcmd__help__subcmd__routines__subcmd__enable_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help routines enable commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__routines__subcmd__history_commands] )) ||
_lunarwing__subcmd__help__subcmd__routines__subcmd__history_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help routines history commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__routines__subcmd__list_commands] )) ||
_lunarwing__subcmd__help__subcmd__routines__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help routines list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__run_commands] )) ||
_lunarwing__subcmd__help__subcmd__run_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help run commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__service_commands] )) ||
_lunarwing__subcmd__help__subcmd__service_commands() {
    local commands; commands=(
'install:Install the OS service (launchd on macOS, systemd/OpenRC on Linux)' \
'start:Start the installed service' \
'stop:Stop the running service' \
'status:Show service status' \
'uninstall:Uninstall the OS service and remove the unit file' \
    )
    _describe -t commands 'lunarwing help service commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__service__subcmd__install_commands] )) ||
_lunarwing__subcmd__help__subcmd__service__subcmd__install_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help service install commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__service__subcmd__start_commands] )) ||
_lunarwing__subcmd__help__subcmd__service__subcmd__start_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help service start commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__service__subcmd__status_commands] )) ||
_lunarwing__subcmd__help__subcmd__service__subcmd__status_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help service status commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__service__subcmd__stop_commands] )) ||
_lunarwing__subcmd__help__subcmd__service__subcmd__stop_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help service stop commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__service__subcmd__uninstall_commands] )) ||
_lunarwing__subcmd__help__subcmd__service__subcmd__uninstall_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help service uninstall commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__skills_commands] )) ||
_lunarwing__subcmd__help__subcmd__skills_commands() {
    local commands; commands=(
'list:List all discovered skills' \
'search:Search ClawHub registry for skills' \
'info:Show detailed info about a specific skill' \
    )
    _describe -t commands 'lunarwing help skills commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__skills__subcmd__info_commands] )) ||
_lunarwing__subcmd__help__subcmd__skills__subcmd__info_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help skills info commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__skills__subcmd__list_commands] )) ||
_lunarwing__subcmd__help__subcmd__skills__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help skills list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__skills__subcmd__search_commands] )) ||
_lunarwing__subcmd__help__subcmd__skills__subcmd__search_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help skills search commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__status_commands] )) ||
_lunarwing__subcmd__help__subcmd__status_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help status commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__tool_commands] )) ||
_lunarwing__subcmd__help__subcmd__tool_commands() {
    local commands; commands=(
'install:Install a WASM tool from source directory or .wasm file' \
'list:List installed tools' \
'remove:Remove an installed tool' \
'info:Show information about a tool' \
'auth:Configure authentication for a tool' \
'setup:Configure required secrets for a tool (from setup.required_secrets)' \
    )
    _describe -t commands 'lunarwing help tool commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__tool__subcmd__auth_commands] )) ||
_lunarwing__subcmd__help__subcmd__tool__subcmd__auth_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help tool auth commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__tool__subcmd__info_commands] )) ||
_lunarwing__subcmd__help__subcmd__tool__subcmd__info_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help tool info commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__tool__subcmd__install_commands] )) ||
_lunarwing__subcmd__help__subcmd__tool__subcmd__install_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help tool install commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__tool__subcmd__list_commands] )) ||
_lunarwing__subcmd__help__subcmd__tool__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help tool list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__tool__subcmd__remove_commands] )) ||
_lunarwing__subcmd__help__subcmd__tool__subcmd__remove_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help tool remove commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__tool__subcmd__setup_commands] )) ||
_lunarwing__subcmd__help__subcmd__tool__subcmd__setup_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help tool setup commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__help__subcmd__worker_commands] )) ||
_lunarwing__subcmd__help__subcmd__worker_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing help worker commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__hooks_commands] )) ||
_lunarwing__subcmd__hooks_commands() {
    local commands; commands=(
'list:List discoverable hooks (bundled + plugin; not filtered by active extensions)' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing hooks commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__hooks__subcmd__help_commands] )) ||
_lunarwing__subcmd__hooks__subcmd__help_commands() {
    local commands; commands=(
'list:List discoverable hooks (bundled + plugin; not filtered by active extensions)' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing hooks help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__hooks__subcmd__help__subcmd__help_commands] )) ||
_lunarwing__subcmd__hooks__subcmd__help__subcmd__help_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing hooks help help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__hooks__subcmd__help__subcmd__list_commands] )) ||
_lunarwing__subcmd__hooks__subcmd__help__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing hooks help list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__hooks__subcmd__list_commands] )) ||
_lunarwing__subcmd__hooks__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing hooks list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__login_commands] )) ||
_lunarwing__subcmd__login_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing login commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__logs_commands] )) ||
_lunarwing__subcmd__logs_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing logs commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__mcp_commands] )) ||
_lunarwing__subcmd__mcp_commands() {
    local commands; commands=(
'add:Add an MCP server' \
'remove:Remove an MCP server' \
'list:List configured MCP servers' \
'auth:Authenticate with an MCP server (OAuth flow)' \
'test:Test connection to an MCP server' \
'toggle:Enable or disable an MCP server' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing mcp commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__mcp__subcmd__add_commands] )) ||
_lunarwing__subcmd__mcp__subcmd__add_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing mcp add commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__mcp__subcmd__auth_commands] )) ||
_lunarwing__subcmd__mcp__subcmd__auth_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing mcp auth commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__mcp__subcmd__help_commands] )) ||
_lunarwing__subcmd__mcp__subcmd__help_commands() {
    local commands; commands=(
'add:Add an MCP server' \
'remove:Remove an MCP server' \
'list:List configured MCP servers' \
'auth:Authenticate with an MCP server (OAuth flow)' \
'test:Test connection to an MCP server' \
'toggle:Enable or disable an MCP server' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing mcp help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__mcp__subcmd__help__subcmd__add_commands] )) ||
_lunarwing__subcmd__mcp__subcmd__help__subcmd__add_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing mcp help add commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__mcp__subcmd__help__subcmd__auth_commands] )) ||
_lunarwing__subcmd__mcp__subcmd__help__subcmd__auth_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing mcp help auth commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__mcp__subcmd__help__subcmd__help_commands] )) ||
_lunarwing__subcmd__mcp__subcmd__help__subcmd__help_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing mcp help help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__mcp__subcmd__help__subcmd__list_commands] )) ||
_lunarwing__subcmd__mcp__subcmd__help__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing mcp help list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__mcp__subcmd__help__subcmd__remove_commands] )) ||
_lunarwing__subcmd__mcp__subcmd__help__subcmd__remove_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing mcp help remove commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__mcp__subcmd__help__subcmd__test_commands] )) ||
_lunarwing__subcmd__mcp__subcmd__help__subcmd__test_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing mcp help test commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__mcp__subcmd__help__subcmd__toggle_commands] )) ||
_lunarwing__subcmd__mcp__subcmd__help__subcmd__toggle_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing mcp help toggle commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__mcp__subcmd__list_commands] )) ||
_lunarwing__subcmd__mcp__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing mcp list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__mcp__subcmd__remove_commands] )) ||
_lunarwing__subcmd__mcp__subcmd__remove_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing mcp remove commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__mcp__subcmd__test_commands] )) ||
_lunarwing__subcmd__mcp__subcmd__test_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing mcp test commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__mcp__subcmd__toggle_commands] )) ||
_lunarwing__subcmd__mcp__subcmd__toggle_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing mcp toggle commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__memory_commands] )) ||
_lunarwing__subcmd__memory_commands() {
    local commands; commands=(
'search:Search workspace memory (hybrid full-text + semantic)' \
'read:Read a file from the workspace' \
'write:Write content to a workspace file' \
'tree:Show workspace directory tree' \
'status:Show workspace status (document count, index health)' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing memory commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__memory__subcmd__help_commands] )) ||
_lunarwing__subcmd__memory__subcmd__help_commands() {
    local commands; commands=(
'search:Search workspace memory (hybrid full-text + semantic)' \
'read:Read a file from the workspace' \
'write:Write content to a workspace file' \
'tree:Show workspace directory tree' \
'status:Show workspace status (document count, index health)' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing memory help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__memory__subcmd__help__subcmd__help_commands] )) ||
_lunarwing__subcmd__memory__subcmd__help__subcmd__help_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing memory help help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__memory__subcmd__help__subcmd__read_commands] )) ||
_lunarwing__subcmd__memory__subcmd__help__subcmd__read_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing memory help read commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__memory__subcmd__help__subcmd__search_commands] )) ||
_lunarwing__subcmd__memory__subcmd__help__subcmd__search_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing memory help search commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__memory__subcmd__help__subcmd__status_commands] )) ||
_lunarwing__subcmd__memory__subcmd__help__subcmd__status_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing memory help status commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__memory__subcmd__help__subcmd__tree_commands] )) ||
_lunarwing__subcmd__memory__subcmd__help__subcmd__tree_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing memory help tree commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__memory__subcmd__help__subcmd__write_commands] )) ||
_lunarwing__subcmd__memory__subcmd__help__subcmd__write_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing memory help write commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__memory__subcmd__read_commands] )) ||
_lunarwing__subcmd__memory__subcmd__read_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing memory read commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__memory__subcmd__search_commands] )) ||
_lunarwing__subcmd__memory__subcmd__search_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing memory search commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__memory__subcmd__status_commands] )) ||
_lunarwing__subcmd__memory__subcmd__status_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing memory status commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__memory__subcmd__tree_commands] )) ||
_lunarwing__subcmd__memory__subcmd__tree_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing memory tree commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__memory__subcmd__write_commands] )) ||
_lunarwing__subcmd__memory__subcmd__write_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing memory write commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__models_commands] )) ||
_lunarwing__subcmd__models_commands() {
    local commands; commands=(
'list:List providers (or available models for a specific provider)' \
'status:Show current model configuration' \
'set:Set the default model' \
'set-provider:Set the LLM provider' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing models commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__models__subcmd__help_commands] )) ||
_lunarwing__subcmd__models__subcmd__help_commands() {
    local commands; commands=(
'list:List providers (or available models for a specific provider)' \
'status:Show current model configuration' \
'set:Set the default model' \
'set-provider:Set the LLM provider' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing models help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__models__subcmd__help__subcmd__help_commands] )) ||
_lunarwing__subcmd__models__subcmd__help__subcmd__help_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing models help help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__models__subcmd__help__subcmd__list_commands] )) ||
_lunarwing__subcmd__models__subcmd__help__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing models help list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__models__subcmd__help__subcmd__set_commands] )) ||
_lunarwing__subcmd__models__subcmd__help__subcmd__set_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing models help set commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__models__subcmd__help__subcmd__set-provider_commands] )) ||
_lunarwing__subcmd__models__subcmd__help__subcmd__set-provider_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing models help set-provider commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__models__subcmd__help__subcmd__status_commands] )) ||
_lunarwing__subcmd__models__subcmd__help__subcmd__status_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing models help status commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__models__subcmd__list_commands] )) ||
_lunarwing__subcmd__models__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing models list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__models__subcmd__set_commands] )) ||
_lunarwing__subcmd__models__subcmd__set_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing models set commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__models__subcmd__set-provider_commands] )) ||
_lunarwing__subcmd__models__subcmd__set-provider_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing models set-provider commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__models__subcmd__status_commands] )) ||
_lunarwing__subcmd__models__subcmd__status_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing models status commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__onboard_commands] )) ||
_lunarwing__subcmd__onboard_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing onboard commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__pairing_commands] )) ||
_lunarwing__subcmd__pairing_commands() {
    local commands; commands=(
'list:List pending pairing requests' \
'approve:Approve a pairing request by code' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing pairing commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__pairing__subcmd__approve_commands] )) ||
_lunarwing__subcmd__pairing__subcmd__approve_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing pairing approve commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__pairing__subcmd__help_commands] )) ||
_lunarwing__subcmd__pairing__subcmd__help_commands() {
    local commands; commands=(
'list:List pending pairing requests' \
'approve:Approve a pairing request by code' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing pairing help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__pairing__subcmd__help__subcmd__approve_commands] )) ||
_lunarwing__subcmd__pairing__subcmd__help__subcmd__approve_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing pairing help approve commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__pairing__subcmd__help__subcmd__help_commands] )) ||
_lunarwing__subcmd__pairing__subcmd__help__subcmd__help_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing pairing help help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__pairing__subcmd__help__subcmd__list_commands] )) ||
_lunarwing__subcmd__pairing__subcmd__help__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing pairing help list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__pairing__subcmd__list_commands] )) ||
_lunarwing__subcmd__pairing__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing pairing list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__reflex_commands] )) ||
_lunarwing__subcmd__reflex_commands() {
    local commands; commands=(
'list:List reflex patterns' \
'show:Show details for a specific reflex pattern' \
'delete:Delete a reflex pattern' \
'status:Show reflex compiler status' \
'prune:Prune (auto-disable) reflex patterns that haven'\''t matched recently' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing reflex commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__reflex__subcmd__delete_commands] )) ||
_lunarwing__subcmd__reflex__subcmd__delete_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing reflex delete commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__reflex__subcmd__help_commands] )) ||
_lunarwing__subcmd__reflex__subcmd__help_commands() {
    local commands; commands=(
'list:List reflex patterns' \
'show:Show details for a specific reflex pattern' \
'delete:Delete a reflex pattern' \
'status:Show reflex compiler status' \
'prune:Prune (auto-disable) reflex patterns that haven'\''t matched recently' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing reflex help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__reflex__subcmd__help__subcmd__delete_commands] )) ||
_lunarwing__subcmd__reflex__subcmd__help__subcmd__delete_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing reflex help delete commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__reflex__subcmd__help__subcmd__help_commands] )) ||
_lunarwing__subcmd__reflex__subcmd__help__subcmd__help_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing reflex help help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__reflex__subcmd__help__subcmd__list_commands] )) ||
_lunarwing__subcmd__reflex__subcmd__help__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing reflex help list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__reflex__subcmd__help__subcmd__prune_commands] )) ||
_lunarwing__subcmd__reflex__subcmd__help__subcmd__prune_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing reflex help prune commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__reflex__subcmd__help__subcmd__show_commands] )) ||
_lunarwing__subcmd__reflex__subcmd__help__subcmd__show_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing reflex help show commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__reflex__subcmd__help__subcmd__status_commands] )) ||
_lunarwing__subcmd__reflex__subcmd__help__subcmd__status_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing reflex help status commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__reflex__subcmd__list_commands] )) ||
_lunarwing__subcmd__reflex__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing reflex list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__reflex__subcmd__prune_commands] )) ||
_lunarwing__subcmd__reflex__subcmd__prune_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing reflex prune commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__reflex__subcmd__show_commands] )) ||
_lunarwing__subcmd__reflex__subcmd__show_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing reflex show commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__reflex__subcmd__status_commands] )) ||
_lunarwing__subcmd__reflex__subcmd__status_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing reflex status commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__registry_commands] )) ||
_lunarwing__subcmd__registry_commands() {
    local commands; commands=(
'list:List available extensions in the registry' \
'info:Show detailed information about an extension or bundle' \
'install:Install an extension or bundle from the registry' \
'install-defaults:Install the default bundle of recommended extensions' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing registry commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__registry__subcmd__help_commands] )) ||
_lunarwing__subcmd__registry__subcmd__help_commands() {
    local commands; commands=(
'list:List available extensions in the registry' \
'info:Show detailed information about an extension or bundle' \
'install:Install an extension or bundle from the registry' \
'install-defaults:Install the default bundle of recommended extensions' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing registry help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__registry__subcmd__help__subcmd__help_commands] )) ||
_lunarwing__subcmd__registry__subcmd__help__subcmd__help_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing registry help help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__registry__subcmd__help__subcmd__info_commands] )) ||
_lunarwing__subcmd__registry__subcmd__help__subcmd__info_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing registry help info commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__registry__subcmd__help__subcmd__install_commands] )) ||
_lunarwing__subcmd__registry__subcmd__help__subcmd__install_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing registry help install commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__registry__subcmd__help__subcmd__install-defaults_commands] )) ||
_lunarwing__subcmd__registry__subcmd__help__subcmd__install-defaults_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing registry help install-defaults commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__registry__subcmd__help__subcmd__list_commands] )) ||
_lunarwing__subcmd__registry__subcmd__help__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing registry help list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__registry__subcmd__info_commands] )) ||
_lunarwing__subcmd__registry__subcmd__info_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing registry info commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__registry__subcmd__install_commands] )) ||
_lunarwing__subcmd__registry__subcmd__install_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing registry install commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__registry__subcmd__install-defaults_commands] )) ||
_lunarwing__subcmd__registry__subcmd__install-defaults_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing registry install-defaults commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__registry__subcmd__list_commands] )) ||
_lunarwing__subcmd__registry__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing registry list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__repl_commands] )) ||
_lunarwing__subcmd__repl_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing repl commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__routines_commands] )) ||
_lunarwing__subcmd__routines_commands() {
    local commands; commands=(
'list:List routines' \
'create:Create a new cron routine' \
'edit:Edit an existing routine' \
'enable:Enable a routine' \
'disable:Disable a routine' \
'delete:Delete a routine' \
'history:Show run history for a routine' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing routines commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__routines__subcmd__create_commands] )) ||
_lunarwing__subcmd__routines__subcmd__create_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing routines create commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__routines__subcmd__delete_commands] )) ||
_lunarwing__subcmd__routines__subcmd__delete_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing routines delete commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__routines__subcmd__disable_commands] )) ||
_lunarwing__subcmd__routines__subcmd__disable_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing routines disable commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__routines__subcmd__edit_commands] )) ||
_lunarwing__subcmd__routines__subcmd__edit_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing routines edit commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__routines__subcmd__enable_commands] )) ||
_lunarwing__subcmd__routines__subcmd__enable_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing routines enable commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__routines__subcmd__help_commands] )) ||
_lunarwing__subcmd__routines__subcmd__help_commands() {
    local commands; commands=(
'list:List routines' \
'create:Create a new cron routine' \
'edit:Edit an existing routine' \
'enable:Enable a routine' \
'disable:Disable a routine' \
'delete:Delete a routine' \
'history:Show run history for a routine' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing routines help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__routines__subcmd__help__subcmd__create_commands] )) ||
_lunarwing__subcmd__routines__subcmd__help__subcmd__create_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing routines help create commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__routines__subcmd__help__subcmd__delete_commands] )) ||
_lunarwing__subcmd__routines__subcmd__help__subcmd__delete_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing routines help delete commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__routines__subcmd__help__subcmd__disable_commands] )) ||
_lunarwing__subcmd__routines__subcmd__help__subcmd__disable_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing routines help disable commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__routines__subcmd__help__subcmd__edit_commands] )) ||
_lunarwing__subcmd__routines__subcmd__help__subcmd__edit_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing routines help edit commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__routines__subcmd__help__subcmd__enable_commands] )) ||
_lunarwing__subcmd__routines__subcmd__help__subcmd__enable_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing routines help enable commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__routines__subcmd__help__subcmd__help_commands] )) ||
_lunarwing__subcmd__routines__subcmd__help__subcmd__help_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing routines help help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__routines__subcmd__help__subcmd__history_commands] )) ||
_lunarwing__subcmd__routines__subcmd__help__subcmd__history_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing routines help history commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__routines__subcmd__help__subcmd__list_commands] )) ||
_lunarwing__subcmd__routines__subcmd__help__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing routines help list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__routines__subcmd__history_commands] )) ||
_lunarwing__subcmd__routines__subcmd__history_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing routines history commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__routines__subcmd__list_commands] )) ||
_lunarwing__subcmd__routines__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing routines list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__run_commands] )) ||
_lunarwing__subcmd__run_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing run commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__service_commands] )) ||
_lunarwing__subcmd__service_commands() {
    local commands; commands=(
'install:Install the OS service (launchd on macOS, systemd/OpenRC on Linux)' \
'start:Start the installed service' \
'stop:Stop the running service' \
'status:Show service status' \
'uninstall:Uninstall the OS service and remove the unit file' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing service commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__service__subcmd__help_commands] )) ||
_lunarwing__subcmd__service__subcmd__help_commands() {
    local commands; commands=(
'install:Install the OS service (launchd on macOS, systemd/OpenRC on Linux)' \
'start:Start the installed service' \
'stop:Stop the running service' \
'status:Show service status' \
'uninstall:Uninstall the OS service and remove the unit file' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing service help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__service__subcmd__help__subcmd__help_commands] )) ||
_lunarwing__subcmd__service__subcmd__help__subcmd__help_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing service help help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__service__subcmd__help__subcmd__install_commands] )) ||
_lunarwing__subcmd__service__subcmd__help__subcmd__install_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing service help install commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__service__subcmd__help__subcmd__start_commands] )) ||
_lunarwing__subcmd__service__subcmd__help__subcmd__start_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing service help start commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__service__subcmd__help__subcmd__status_commands] )) ||
_lunarwing__subcmd__service__subcmd__help__subcmd__status_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing service help status commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__service__subcmd__help__subcmd__stop_commands] )) ||
_lunarwing__subcmd__service__subcmd__help__subcmd__stop_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing service help stop commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__service__subcmd__help__subcmd__uninstall_commands] )) ||
_lunarwing__subcmd__service__subcmd__help__subcmd__uninstall_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing service help uninstall commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__service__subcmd__install_commands] )) ||
_lunarwing__subcmd__service__subcmd__install_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing service install commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__service__subcmd__start_commands] )) ||
_lunarwing__subcmd__service__subcmd__start_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing service start commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__service__subcmd__status_commands] )) ||
_lunarwing__subcmd__service__subcmd__status_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing service status commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__service__subcmd__stop_commands] )) ||
_lunarwing__subcmd__service__subcmd__stop_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing service stop commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__service__subcmd__uninstall_commands] )) ||
_lunarwing__subcmd__service__subcmd__uninstall_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing service uninstall commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__skills_commands] )) ||
_lunarwing__subcmd__skills_commands() {
    local commands; commands=(
'list:List all discovered skills' \
'search:Search ClawHub registry for skills' \
'info:Show detailed info about a specific skill' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing skills commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__skills__subcmd__help_commands] )) ||
_lunarwing__subcmd__skills__subcmd__help_commands() {
    local commands; commands=(
'list:List all discovered skills' \
'search:Search ClawHub registry for skills' \
'info:Show detailed info about a specific skill' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing skills help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__skills__subcmd__help__subcmd__help_commands] )) ||
_lunarwing__subcmd__skills__subcmd__help__subcmd__help_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing skills help help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__skills__subcmd__help__subcmd__info_commands] )) ||
_lunarwing__subcmd__skills__subcmd__help__subcmd__info_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing skills help info commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__skills__subcmd__help__subcmd__list_commands] )) ||
_lunarwing__subcmd__skills__subcmd__help__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing skills help list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__skills__subcmd__help__subcmd__search_commands] )) ||
_lunarwing__subcmd__skills__subcmd__help__subcmd__search_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing skills help search commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__skills__subcmd__info_commands] )) ||
_lunarwing__subcmd__skills__subcmd__info_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing skills info commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__skills__subcmd__list_commands] )) ||
_lunarwing__subcmd__skills__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing skills list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__skills__subcmd__search_commands] )) ||
_lunarwing__subcmd__skills__subcmd__search_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing skills search commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__status_commands] )) ||
_lunarwing__subcmd__status_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing status commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__tool_commands] )) ||
_lunarwing__subcmd__tool_commands() {
    local commands; commands=(
'install:Install a WASM tool from source directory or .wasm file' \
'list:List installed tools' \
'remove:Remove an installed tool' \
'info:Show information about a tool' \
'auth:Configure authentication for a tool' \
'setup:Configure required secrets for a tool (from setup.required_secrets)' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing tool commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__tool__subcmd__auth_commands] )) ||
_lunarwing__subcmd__tool__subcmd__auth_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing tool auth commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__tool__subcmd__help_commands] )) ||
_lunarwing__subcmd__tool__subcmd__help_commands() {
    local commands; commands=(
'install:Install a WASM tool from source directory or .wasm file' \
'list:List installed tools' \
'remove:Remove an installed tool' \
'info:Show information about a tool' \
'auth:Configure authentication for a tool' \
'setup:Configure required secrets for a tool (from setup.required_secrets)' \
'help:Print this message or the help of the given subcommand(s)' \
    )
    _describe -t commands 'lunarwing tool help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__tool__subcmd__help__subcmd__auth_commands] )) ||
_lunarwing__subcmd__tool__subcmd__help__subcmd__auth_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing tool help auth commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__tool__subcmd__help__subcmd__help_commands] )) ||
_lunarwing__subcmd__tool__subcmd__help__subcmd__help_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing tool help help commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__tool__subcmd__help__subcmd__info_commands] )) ||
_lunarwing__subcmd__tool__subcmd__help__subcmd__info_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing tool help info commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__tool__subcmd__help__subcmd__install_commands] )) ||
_lunarwing__subcmd__tool__subcmd__help__subcmd__install_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing tool help install commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__tool__subcmd__help__subcmd__list_commands] )) ||
_lunarwing__subcmd__tool__subcmd__help__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing tool help list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__tool__subcmd__help__subcmd__remove_commands] )) ||
_lunarwing__subcmd__tool__subcmd__help__subcmd__remove_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing tool help remove commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__tool__subcmd__help__subcmd__setup_commands] )) ||
_lunarwing__subcmd__tool__subcmd__help__subcmd__setup_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing tool help setup commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__tool__subcmd__info_commands] )) ||
_lunarwing__subcmd__tool__subcmd__info_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing tool info commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__tool__subcmd__install_commands] )) ||
_lunarwing__subcmd__tool__subcmd__install_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing tool install commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__tool__subcmd__list_commands] )) ||
_lunarwing__subcmd__tool__subcmd__list_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing tool list commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__tool__subcmd__remove_commands] )) ||
_lunarwing__subcmd__tool__subcmd__remove_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing tool remove commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__tool__subcmd__setup_commands] )) ||
_lunarwing__subcmd__tool__subcmd__setup_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing tool setup commands' commands "$@"
}
(( $+functions[_lunarwing__subcmd__worker_commands] )) ||
_lunarwing__subcmd__worker_commands() {
    local commands; commands=()
    _describe -t commands 'lunarwing worker commands' commands "$@"
}

if [ "$funcstack[1]" = "_lunarwing" ]; then
    _lunarwing "$@"
else
    (( $+functions[compdef] )) && compdef _lunarwing lunarwing
fi
