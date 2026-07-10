# Print an optspec for argparse to handle cmd's options that are independent of any subcommand.
function __fish_lunarwing_global_optspecs
	string join \n cli-only no-db m/message= c/config= no-onboard auto-approve supervised h/help V/version
end

function __fish_lunarwing_needs_command
	# Figure out if the current invocation already has a command.
	set -l cmd (commandline -opc)
	set -e cmd[1]
	argparse -s (__fish_lunarwing_global_optspecs) -- $cmd 2>/dev/null
	or return
	if set -q argv[1]
		# Also print the command, so this can be used to figure out what it is.
		echo $argv[1]
		return 1
	end
	return 0
end

function __fish_lunarwing_using_subcommand
	set -l cmd (__fish_lunarwing_needs_command)
	test -z "$cmd"
	and return 1
	contains -- $cmd[1] $argv
end

complete -c lunarwing -n "__fish_lunarwing_needs_command" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_needs_command" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_needs_command" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -s V -l version -d 'Print version'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -f -a "run" -d 'Run the AI agent'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -f -a "onboard" -d 'Run interactive setup wizard'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -f -a "config" -d 'Manage app configs'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -f -a "tool" -d 'Manage WASM tools'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -f -a "registry" -d 'Browse/install extensions'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -f -a "channels" -d 'Manage channels'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -f -a "reflex" -d 'Manage reflex patterns'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -f -a "routines" -d 'Manage routines'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -f -a "mcp" -d 'Manage MCP servers'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -f -a "memory" -d 'Manage workspace memory'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -f -a "pairing" -d 'Manage DM pairing'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -f -a "service" -d 'Manage OS service'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -f -a "repl" -d 'Connect to running daemon via REPL'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -f -a "skills" -d 'Manage skills'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -f -a "hooks" -d 'Manage lifecycle hooks'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -f -a "models" -d 'Manage LLM providers and models'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -f -a "doctor" -d 'Run diagnostics'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -f -a "logs" -d 'View and manage gateway logs'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -f -a "status" -d 'Show system status'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -f -a "completion" -d 'Generate completions'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -f -a "login" -d 'Reconfigure an LLM provider'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -f -a "worker" -d 'Run as a sandboxed worker inside a Docker container (internal use). This is invoked automatically by the orchestrator, not by users directly'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -f -a "acp" -d 'Manage ACP agents'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -f -a "acp-bridge" -d 'Run as an ACP bridge inside a Docker container (internal use)'
complete -c lunarwing -n "__fish_lunarwing_needs_command" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand run" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand run" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand run" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand run" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand run" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand run" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand run" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand run" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand onboard" -l step -d 'Run only specific setup steps (comma-separated: provider, channels, model, database, security)' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand onboard" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand onboard" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand onboard" -l skip-auth -d 'Skip authentication (use existing session)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand onboard" -l channels-only -d 'Deprecated: use --step channels'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand onboard" -l provider-only -d 'Deprecated: use --step provider'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand onboard" -l quick -d 'Quick setup: auto-defaults everything except LLM provider and model'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand onboard" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand onboard" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand onboard" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand onboard" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand onboard" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand onboard" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and not __fish_seen_subcommand_from init list get set reset path help" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and not __fish_seen_subcommand_from init list get set reset path help" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and not __fish_seen_subcommand_from init list get set reset path help" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and not __fish_seen_subcommand_from init list get set reset path help" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and not __fish_seen_subcommand_from init list get set reset path help" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and not __fish_seen_subcommand_from init list get set reset path help" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and not __fish_seen_subcommand_from init list get set reset path help" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and not __fish_seen_subcommand_from init list get set reset path help" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and not __fish_seen_subcommand_from init list get set reset path help" -f -a "init" -d 'Generate a default config.toml file'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and not __fish_seen_subcommand_from init list get set reset path help" -f -a "list" -d 'List all settings and their current values'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and not __fish_seen_subcommand_from init list get set reset path help" -f -a "get" -d 'Get a specific setting value'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and not __fish_seen_subcommand_from init list get set reset path help" -f -a "set" -d 'Set a setting value'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and not __fish_seen_subcommand_from init list get set reset path help" -f -a "reset" -d 'Reset a setting to its default value'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and not __fish_seen_subcommand_from init list get set reset path help" -f -a "path" -d 'Show the settings storage info'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and not __fish_seen_subcommand_from init list get set reset path help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from init" -s o -l output -d 'Output path (default: ~/.lunarwing/config.toml)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from init" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from init" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from init" -l force -d 'Overwrite existing file'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from init" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from init" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from init" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from init" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from init" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from init" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from list" -s f -l filter -d 'Show only settings matching this prefix (e.g., "agent", "heartbeat")' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from list" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from list" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from list" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from list" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from list" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from list" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from list" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from list" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from get" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from get" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from get" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from get" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from get" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from get" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from get" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from get" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from set" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from set" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from set" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from set" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from set" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from set" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from set" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from set" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from reset" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from reset" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from reset" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from reset" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from reset" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from reset" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from reset" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from reset" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from path" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from path" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from path" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from path" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from path" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from path" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from path" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from path" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from help" -f -a "init" -d 'Generate a default config.toml file'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from help" -f -a "list" -d 'List all settings and their current values'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from help" -f -a "get" -d 'Get a specific setting value'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from help" -f -a "set" -d 'Set a setting value'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from help" -f -a "reset" -d 'Reset a setting to its default value'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from help" -f -a "path" -d 'Show the settings storage info'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand config; and __fish_seen_subcommand_from help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and not __fish_seen_subcommand_from install list remove info auth setup help" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and not __fish_seen_subcommand_from install list remove info auth setup help" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and not __fish_seen_subcommand_from install list remove info auth setup help" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and not __fish_seen_subcommand_from install list remove info auth setup help" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and not __fish_seen_subcommand_from install list remove info auth setup help" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and not __fish_seen_subcommand_from install list remove info auth setup help" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and not __fish_seen_subcommand_from install list remove info auth setup help" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and not __fish_seen_subcommand_from install list remove info auth setup help" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and not __fish_seen_subcommand_from install list remove info auth setup help" -f -a "install" -d 'Install a WASM tool from source directory or .wasm file'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and not __fish_seen_subcommand_from install list remove info auth setup help" -f -a "list" -d 'List installed tools'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and not __fish_seen_subcommand_from install list remove info auth setup help" -f -a "remove" -d 'Remove an installed tool'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and not __fish_seen_subcommand_from install list remove info auth setup help" -f -a "info" -d 'Show information about a tool'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and not __fish_seen_subcommand_from install list remove info auth setup help" -f -a "auth" -d 'Configure authentication for a tool'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and not __fish_seen_subcommand_from install list remove info auth setup help" -f -a "setup" -d 'Configure required secrets for a tool (from setup.required_secrets)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and not __fish_seen_subcommand_from install list remove info auth setup help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from install" -s n -l name -d 'Tool name (defaults to directory/file name)' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from install" -l capabilities -d 'Path to capabilities JSON file (auto-detected if not specified)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from install" -s t -l target -d 'Target directory for installation (default: ~/.lunarwing/tools/)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from install" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from install" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from install" -l release -d 'Build in release mode (default: true)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from install" -l skip-build -d 'Skip compilation (use existing .wasm file)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from install" -s f -l force -d 'Force overwrite if tool already exists'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from install" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from install" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from install" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from install" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from install" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from install" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from list" -s d -l dir -d 'Directory to list tools from (default: ~/.lunarwing/tools/)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from list" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from list" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from list" -s v -l verbose -d 'Show detailed information'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from list" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from list" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from list" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from list" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from list" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from list" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from remove" -s d -l dir -d 'Directory to remove tool from (default: ~/.lunarwing/tools/)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from remove" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from remove" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from remove" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from remove" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from remove" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from remove" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from remove" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from remove" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from info" -s d -l dir -d 'Directory to look for tool (default: ~/.lunarwing/tools/)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from info" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from info" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from info" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from info" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from info" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from info" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from info" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from info" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from auth" -s d -l dir -d 'Directory to look for tool (default: ~/.lunarwing/tools/)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from auth" -s u -l user -d 'User ID for storing the secret (default: "default")' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from auth" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from auth" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from auth" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from auth" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from auth" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from auth" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from auth" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from auth" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from setup" -s d -l dir -d 'Directory to look for tool (default: ~/.lunarwing/tools/)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from setup" -s u -l user -d 'User ID for storing the secret (default: "default")' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from setup" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from setup" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from setup" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from setup" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from setup" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from setup" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from setup" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from setup" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from help" -f -a "install" -d 'Install a WASM tool from source directory or .wasm file'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from help" -f -a "list" -d 'List installed tools'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from help" -f -a "remove" -d 'Remove an installed tool'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from help" -f -a "info" -d 'Show information about a tool'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from help" -f -a "auth" -d 'Configure authentication for a tool'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from help" -f -a "setup" -d 'Configure required secrets for a tool (from setup.required_secrets)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand tool; and __fish_seen_subcommand_from help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and not __fish_seen_subcommand_from list info install install-defaults help" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and not __fish_seen_subcommand_from list info install install-defaults help" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and not __fish_seen_subcommand_from list info install install-defaults help" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and not __fish_seen_subcommand_from list info install install-defaults help" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and not __fish_seen_subcommand_from list info install install-defaults help" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and not __fish_seen_subcommand_from list info install install-defaults help" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and not __fish_seen_subcommand_from list info install install-defaults help" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and not __fish_seen_subcommand_from list info install install-defaults help" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and not __fish_seen_subcommand_from list info install install-defaults help" -f -a "list" -d 'List available extensions in the registry'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and not __fish_seen_subcommand_from list info install install-defaults help" -f -a "info" -d 'Show detailed information about an extension or bundle'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and not __fish_seen_subcommand_from list info install install-defaults help" -f -a "install" -d 'Install an extension or bundle from the registry'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and not __fish_seen_subcommand_from list info install install-defaults help" -f -a "install-defaults" -d 'Install the default bundle of recommended extensions'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and not __fish_seen_subcommand_from list info install install-defaults help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from list" -s k -l kind -d 'Filter by kind: "tool" or "channel"' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from list" -s t -l tag -d 'Filter by tag (e.g. "default", "messaging", "lunarwing")' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from list" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from list" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from list" -s v -l verbose -d 'Show detailed information'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from list" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from list" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from list" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from list" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from list" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from list" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from info" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from info" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from info" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from info" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from info" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from info" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from info" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from info" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from install" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from install" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from install" -s f -l force -d 'Force overwrite if already installed'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from install" -l build -d 'Build from source instead of downloading pre-built artifact'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from install" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from install" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from install" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from install" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from install" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from install" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from install-defaults" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from install-defaults" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from install-defaults" -s f -l force -d 'Force overwrite if already installed'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from install-defaults" -l build -d 'Build from source instead of downloading pre-built artifact'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from install-defaults" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from install-defaults" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from install-defaults" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from install-defaults" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from install-defaults" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from install-defaults" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from help" -f -a "list" -d 'List available extensions in the registry'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from help" -f -a "info" -d 'Show detailed information about an extension or bundle'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from help" -f -a "install" -d 'Install an extension or bundle from the registry'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from help" -f -a "install-defaults" -d 'Install the default bundle of recommended extensions'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand registry; and __fish_seen_subcommand_from help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand channels; and not __fish_seen_subcommand_from list help" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand channels; and not __fish_seen_subcommand_from list help" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand channels; and not __fish_seen_subcommand_from list help" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand channels; and not __fish_seen_subcommand_from list help" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand channels; and not __fish_seen_subcommand_from list help" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand channels; and not __fish_seen_subcommand_from list help" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand channels; and not __fish_seen_subcommand_from list help" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand channels; and not __fish_seen_subcommand_from list help" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand channels; and not __fish_seen_subcommand_from list help" -f -a "list" -d 'List all configured channels'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand channels; and not __fish_seen_subcommand_from list help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand channels; and __fish_seen_subcommand_from list" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand channels; and __fish_seen_subcommand_from list" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand channels; and __fish_seen_subcommand_from list" -s v -l verbose -d 'Show detailed information (host, port, config source)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand channels; and __fish_seen_subcommand_from list" -l json -d 'Output as JSON'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand channels; and __fish_seen_subcommand_from list" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand channels; and __fish_seen_subcommand_from list" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand channels; and __fish_seen_subcommand_from list" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand channels; and __fish_seen_subcommand_from list" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand channels; and __fish_seen_subcommand_from list" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand channels; and __fish_seen_subcommand_from list" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand channels; and __fish_seen_subcommand_from help" -f -a "list" -d 'List all configured channels'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand channels; and __fish_seen_subcommand_from help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and not __fish_seen_subcommand_from list show delete status prune help" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and not __fish_seen_subcommand_from list show delete status prune help" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and not __fish_seen_subcommand_from list show delete status prune help" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and not __fish_seen_subcommand_from list show delete status prune help" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and not __fish_seen_subcommand_from list show delete status prune help" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and not __fish_seen_subcommand_from list show delete status prune help" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and not __fish_seen_subcommand_from list show delete status prune help" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and not __fish_seen_subcommand_from list show delete status prune help" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and not __fish_seen_subcommand_from list show delete status prune help" -f -a "list" -d 'List reflex patterns'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and not __fish_seen_subcommand_from list show delete status prune help" -f -a "show" -d 'Show details for a specific reflex pattern'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and not __fish_seen_subcommand_from list show delete status prune help" -f -a "delete" -d 'Delete a reflex pattern'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and not __fish_seen_subcommand_from list show delete status prune help" -f -a "status" -d 'Show reflex compiler status'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and not __fish_seen_subcommand_from list show delete status prune help" -f -a "prune" -d 'Prune (auto-disable) reflex patterns that haven\'t matched recently'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and not __fish_seen_subcommand_from list show delete status prune help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from list" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from list" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from list" -l disabled -d 'Include disabled patterns'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from list" -l json -d 'Output as JSON (for scripting)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from list" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from list" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from list" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from list" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from list" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from list" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from show" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from show" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from show" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from show" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from show" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from show" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from show" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from show" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from delete" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from delete" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from delete" -s y -l yes -d 'Skip confirmation prompt'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from delete" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from delete" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from delete" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from delete" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from delete" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from delete" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from status" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from status" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from status" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from status" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from status" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from status" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from status" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from status" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from prune" -l stale-days -d 'Patterns not matched in this many days are considered stale' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from prune" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from prune" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from prune" -l dry-run -d 'Show what would be evicted without modifying the database'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from prune" -l json -d 'Output as JSON (for scripting)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from prune" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from prune" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from prune" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from prune" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from prune" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from prune" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from help" -f -a "list" -d 'List reflex patterns'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from help" -f -a "show" -d 'Show details for a specific reflex pattern'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from help" -f -a "delete" -d 'Delete a reflex pattern'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from help" -f -a "status" -d 'Show reflex compiler status'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from help" -f -a "prune" -d 'Prune (auto-disable) reflex patterns that haven\'t matched recently'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand reflex; and __fish_seen_subcommand_from help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and not __fish_seen_subcommand_from list create edit enable disable delete history help" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and not __fish_seen_subcommand_from list create edit enable disable delete history help" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and not __fish_seen_subcommand_from list create edit enable disable delete history help" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and not __fish_seen_subcommand_from list create edit enable disable delete history help" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and not __fish_seen_subcommand_from list create edit enable disable delete history help" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and not __fish_seen_subcommand_from list create edit enable disable delete history help" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and not __fish_seen_subcommand_from list create edit enable disable delete history help" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and not __fish_seen_subcommand_from list create edit enable disable delete history help" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and not __fish_seen_subcommand_from list create edit enable disable delete history help" -f -a "list" -d 'List routines'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and not __fish_seen_subcommand_from list create edit enable disable delete history help" -f -a "create" -d 'Create a new cron routine'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and not __fish_seen_subcommand_from list create edit enable disable delete history help" -f -a "edit" -d 'Edit an existing routine'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and not __fish_seen_subcommand_from list create edit enable disable delete history help" -f -a "enable" -d 'Enable a routine'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and not __fish_seen_subcommand_from list create edit enable disable delete history help" -f -a "disable" -d 'Disable a routine'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and not __fish_seen_subcommand_from list create edit enable disable delete history help" -f -a "delete" -d 'Delete a routine'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and not __fish_seen_subcommand_from list create edit enable disable delete history help" -f -a "history" -d 'Show run history for a routine'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and not __fish_seen_subcommand_from list create edit enable disable delete history help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from list" -l trigger -d 'Filter by trigger type (e.g. "cron", "webhook", "event")' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from list" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from list" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from list" -l disabled -d 'Include disabled routines'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from list" -l json -d 'Output as JSON (for scripting)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from list" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from list" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from list" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from list" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from list" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from list" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from create" -l name -d 'Routine name (must be unique per user)' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from create" -l schedule -d 'Cron schedule (6-field: "sec min hour day month weekday")' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from create" -l prompt -d 'Prompt for the LLM' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from create" -l description -d 'Optional description' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from create" -l timezone -d 'IANA timezone (e.g. "America/New_York")' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from create" -l cooldown -d 'Cooldown between fires in seconds' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from create" -l notify-channel -d 'Notification channel' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from create" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from create" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from create" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from create" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from create" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from create" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from create" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from create" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from edit" -l name -d 'Routine name' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from edit" -l schedule -d 'New schedule' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from edit" -l prompt -d 'New prompt' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from edit" -l description -d 'New description' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from edit" -l timezone -d 'New timezone' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from edit" -l cooldown -d 'New cooldown in seconds' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from edit" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from edit" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from edit" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from edit" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from edit" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from edit" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from edit" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from edit" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from enable" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from enable" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from enable" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from enable" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from enable" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from enable" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from enable" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from enable" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from disable" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from disable" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from disable" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from disable" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from disable" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from disable" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from disable" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from disable" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from delete" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from delete" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from delete" -s y -l yes -d 'Skip confirmation prompt'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from delete" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from delete" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from delete" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from delete" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from delete" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from delete" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from history" -s l -l limit -d 'Maximum number of runs to show' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from history" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from history" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from history" -l json -d 'Output as JSON (for scripting)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from history" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from history" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from history" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from history" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from history" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from history" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from help" -f -a "list" -d 'List routines'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from help" -f -a "create" -d 'Create a new cron routine'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from help" -f -a "edit" -d 'Edit an existing routine'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from help" -f -a "enable" -d 'Enable a routine'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from help" -f -a "disable" -d 'Disable a routine'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from help" -f -a "delete" -d 'Delete a routine'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from help" -f -a "history" -d 'Show run history for a routine'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand routines; and __fish_seen_subcommand_from help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and not __fish_seen_subcommand_from add remove list auth test toggle help" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and not __fish_seen_subcommand_from add remove list auth test toggle help" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and not __fish_seen_subcommand_from add remove list auth test toggle help" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and not __fish_seen_subcommand_from add remove list auth test toggle help" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and not __fish_seen_subcommand_from add remove list auth test toggle help" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and not __fish_seen_subcommand_from add remove list auth test toggle help" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and not __fish_seen_subcommand_from add remove list auth test toggle help" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and not __fish_seen_subcommand_from add remove list auth test toggle help" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and not __fish_seen_subcommand_from add remove list auth test toggle help" -f -a "add" -d 'Add an MCP server'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and not __fish_seen_subcommand_from add remove list auth test toggle help" -f -a "remove" -d 'Remove an MCP server'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and not __fish_seen_subcommand_from add remove list auth test toggle help" -f -a "list" -d 'List configured MCP servers'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and not __fish_seen_subcommand_from add remove list auth test toggle help" -f -a "auth" -d 'Authenticate with an MCP server (OAuth flow)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and not __fish_seen_subcommand_from add remove list auth test toggle help" -f -a "test" -d 'Test connection to an MCP server'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and not __fish_seen_subcommand_from add remove list auth test toggle help" -f -a "toggle" -d 'Enable or disable an MCP server'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and not __fish_seen_subcommand_from add remove list auth test toggle help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from add" -l transport -d 'Transport type: http (default), stdio, unix' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from add" -l command -d 'Command to run (stdio transport)' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from add" -l arg -d 'Command arguments (stdio transport, can be repeated)' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from add" -l env -d 'Environment variables (stdio transport, KEY=VALUE format, can be repeated)' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from add" -l socket -d 'Unix socket path (unix transport)' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from add" -l header -d 'Custom HTTP headers (KEY:VALUE format, can be repeated)' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from add" -l client-id -d 'OAuth client ID (if authentication is required)' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from add" -l auth-url -d 'OAuth authorization URL (optional, can be discovered)' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from add" -l token-url -d 'OAuth token URL (optional, can be discovered)' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from add" -l scopes -d 'Scopes to request (comma-separated)' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from add" -l description -d 'Server description' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from add" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from add" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from add" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from add" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from add" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from add" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from add" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from add" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from remove" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from remove" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from remove" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from remove" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from remove" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from remove" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from remove" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from remove" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from list" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from list" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from list" -s v -l verbose -d 'Show detailed information'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from list" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from list" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from list" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from list" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from list" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from list" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from auth" -s u -l user -d 'User ID for storing the token (default: "default")' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from auth" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from auth" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from auth" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from auth" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from auth" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from auth" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from auth" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from auth" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from test" -s u -l user -d 'User ID for authentication (default: "default")' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from test" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from test" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from test" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from test" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from test" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from test" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from test" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from test" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from toggle" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from toggle" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from toggle" -l enable -d 'Enable the server'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from toggle" -l disable -d 'Disable the server'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from toggle" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from toggle" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from toggle" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from toggle" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from toggle" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from toggle" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from help" -f -a "add" -d 'Add an MCP server'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from help" -f -a "remove" -d 'Remove an MCP server'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from help" -f -a "list" -d 'List configured MCP servers'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from help" -f -a "auth" -d 'Authenticate with an MCP server (OAuth flow)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from help" -f -a "test" -d 'Test connection to an MCP server'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from help" -f -a "toggle" -d 'Enable or disable an MCP server'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand mcp; and __fish_seen_subcommand_from help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and not __fish_seen_subcommand_from search read write tree status help" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and not __fish_seen_subcommand_from search read write tree status help" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and not __fish_seen_subcommand_from search read write tree status help" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and not __fish_seen_subcommand_from search read write tree status help" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and not __fish_seen_subcommand_from search read write tree status help" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and not __fish_seen_subcommand_from search read write tree status help" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and not __fish_seen_subcommand_from search read write tree status help" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and not __fish_seen_subcommand_from search read write tree status help" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and not __fish_seen_subcommand_from search read write tree status help" -f -a "search" -d 'Search workspace memory (hybrid full-text + semantic)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and not __fish_seen_subcommand_from search read write tree status help" -f -a "read" -d 'Read a file from the workspace'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and not __fish_seen_subcommand_from search read write tree status help" -f -a "write" -d 'Write content to a workspace file'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and not __fish_seen_subcommand_from search read write tree status help" -f -a "tree" -d 'Show workspace directory tree'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and not __fish_seen_subcommand_from search read write tree status help" -f -a "status" -d 'Show workspace status (document count, index health)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and not __fish_seen_subcommand_from search read write tree status help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from search" -s l -l limit -d 'Maximum number of results' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from search" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from search" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from search" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from search" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from search" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from search" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from search" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from search" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from read" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from read" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from read" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from read" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from read" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from read" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from read" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from read" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from write" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from write" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from write" -s a -l append -d 'Append instead of overwrite'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from write" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from write" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from write" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from write" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from write" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from write" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from tree" -s d -l depth -d 'Maximum depth to traverse' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from tree" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from tree" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from tree" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from tree" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from tree" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from tree" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from tree" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from tree" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from status" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from status" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from status" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from status" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from status" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from status" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from status" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from status" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from help" -f -a "search" -d 'Search workspace memory (hybrid full-text + semantic)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from help" -f -a "read" -d 'Read a file from the workspace'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from help" -f -a "write" -d 'Write content to a workspace file'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from help" -f -a "tree" -d 'Show workspace directory tree'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from help" -f -a "status" -d 'Show workspace status (document count, index health)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand memory; and __fish_seen_subcommand_from help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and not __fish_seen_subcommand_from list approve help" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and not __fish_seen_subcommand_from list approve help" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and not __fish_seen_subcommand_from list approve help" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and not __fish_seen_subcommand_from list approve help" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and not __fish_seen_subcommand_from list approve help" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and not __fish_seen_subcommand_from list approve help" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and not __fish_seen_subcommand_from list approve help" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and not __fish_seen_subcommand_from list approve help" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and not __fish_seen_subcommand_from list approve help" -f -a "list" -d 'List pending pairing requests'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and not __fish_seen_subcommand_from list approve help" -f -a "approve" -d 'Approve a pairing request by code'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and not __fish_seen_subcommand_from list approve help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and __fish_seen_subcommand_from list" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and __fish_seen_subcommand_from list" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and __fish_seen_subcommand_from list" -l json -d 'Output as JSON'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and __fish_seen_subcommand_from list" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and __fish_seen_subcommand_from list" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and __fish_seen_subcommand_from list" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and __fish_seen_subcommand_from list" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and __fish_seen_subcommand_from list" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and __fish_seen_subcommand_from list" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and __fish_seen_subcommand_from approve" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and __fish_seen_subcommand_from approve" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and __fish_seen_subcommand_from approve" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and __fish_seen_subcommand_from approve" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and __fish_seen_subcommand_from approve" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and __fish_seen_subcommand_from approve" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and __fish_seen_subcommand_from approve" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and __fish_seen_subcommand_from approve" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and __fish_seen_subcommand_from help" -f -a "list" -d 'List pending pairing requests'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and __fish_seen_subcommand_from help" -f -a "approve" -d 'Approve a pairing request by code'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand pairing; and __fish_seen_subcommand_from help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and not __fish_seen_subcommand_from install start stop status uninstall help" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and not __fish_seen_subcommand_from install start stop status uninstall help" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and not __fish_seen_subcommand_from install start stop status uninstall help" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and not __fish_seen_subcommand_from install start stop status uninstall help" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and not __fish_seen_subcommand_from install start stop status uninstall help" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and not __fish_seen_subcommand_from install start stop status uninstall help" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and not __fish_seen_subcommand_from install start stop status uninstall help" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and not __fish_seen_subcommand_from install start stop status uninstall help" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and not __fish_seen_subcommand_from install start stop status uninstall help" -f -a "install" -d 'Install the OS service (launchd on macOS, systemd/OpenRC on Linux)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and not __fish_seen_subcommand_from install start stop status uninstall help" -f -a "start" -d 'Start the installed service'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and not __fish_seen_subcommand_from install start stop status uninstall help" -f -a "stop" -d 'Stop the running service'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and not __fish_seen_subcommand_from install start stop status uninstall help" -f -a "status" -d 'Show service status'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and not __fish_seen_subcommand_from install start stop status uninstall help" -f -a "uninstall" -d 'Uninstall the OS service and remove the unit file'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and not __fish_seen_subcommand_from install start stop status uninstall help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from install" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from install" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from install" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from install" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from install" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from install" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from install" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from install" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from start" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from start" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from start" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from start" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from start" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from start" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from start" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from start" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from stop" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from stop" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from stop" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from stop" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from stop" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from stop" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from stop" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from stop" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from status" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from status" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from status" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from status" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from status" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from status" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from status" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from status" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from uninstall" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from uninstall" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from uninstall" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from uninstall" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from uninstall" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from uninstall" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from uninstall" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from uninstall" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from help" -f -a "install" -d 'Install the OS service (launchd on macOS, systemd/OpenRC on Linux)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from help" -f -a "start" -d 'Start the installed service'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from help" -f -a "stop" -d 'Stop the running service'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from help" -f -a "status" -d 'Show service status'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from help" -f -a "uninstall" -d 'Uninstall the OS service and remove the unit file'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand service; and __fish_seen_subcommand_from help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand repl" -l socket -d 'Path to the Unix socket' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand repl" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand repl" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand repl" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand repl" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand repl" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand repl" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand repl" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand repl" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and not __fish_seen_subcommand_from list search info help" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and not __fish_seen_subcommand_from list search info help" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and not __fish_seen_subcommand_from list search info help" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and not __fish_seen_subcommand_from list search info help" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and not __fish_seen_subcommand_from list search info help" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and not __fish_seen_subcommand_from list search info help" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and not __fish_seen_subcommand_from list search info help" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and not __fish_seen_subcommand_from list search info help" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and not __fish_seen_subcommand_from list search info help" -f -a "list" -d 'List all discovered skills'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and not __fish_seen_subcommand_from list search info help" -f -a "search" -d 'Search ClawHub registry for skills'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and not __fish_seen_subcommand_from list search info help" -f -a "info" -d 'Show detailed info about a specific skill'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and not __fish_seen_subcommand_from list search info help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from list" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from list" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from list" -s v -l verbose -d 'Show detailed information (keywords, patterns, source path)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from list" -l json -d 'Output as JSON'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from list" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from list" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from list" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from list" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from list" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from list" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from search" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from search" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from search" -l json -d 'Output as JSON'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from search" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from search" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from search" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from search" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from search" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from search" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from info" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from info" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from info" -l json -d 'Output as JSON'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from info" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from info" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from info" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from info" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from info" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from info" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from help" -f -a "list" -d 'List all discovered skills'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from help" -f -a "search" -d 'Search ClawHub registry for skills'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from help" -f -a "info" -d 'Show detailed info about a specific skill'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand skills; and __fish_seen_subcommand_from help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand hooks; and not __fish_seen_subcommand_from list help" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand hooks; and not __fish_seen_subcommand_from list help" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand hooks; and not __fish_seen_subcommand_from list help" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand hooks; and not __fish_seen_subcommand_from list help" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand hooks; and not __fish_seen_subcommand_from list help" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand hooks; and not __fish_seen_subcommand_from list help" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand hooks; and not __fish_seen_subcommand_from list help" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand hooks; and not __fish_seen_subcommand_from list help" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand hooks; and not __fish_seen_subcommand_from list help" -f -a "list" -d 'List discoverable hooks (bundled + plugin; not filtered by active extensions)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand hooks; and not __fish_seen_subcommand_from list help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand hooks; and __fish_seen_subcommand_from list" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand hooks; and __fish_seen_subcommand_from list" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand hooks; and __fish_seen_subcommand_from list" -s v -l verbose -d 'Show detailed information (hook points, priority, failure mode)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand hooks; and __fish_seen_subcommand_from list" -l json -d 'Output as JSON'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand hooks; and __fish_seen_subcommand_from list" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand hooks; and __fish_seen_subcommand_from list" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand hooks; and __fish_seen_subcommand_from list" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand hooks; and __fish_seen_subcommand_from list" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand hooks; and __fish_seen_subcommand_from list" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand hooks; and __fish_seen_subcommand_from list" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand hooks; and __fish_seen_subcommand_from help" -f -a "list" -d 'List discoverable hooks (bundled + plugin; not filtered by active extensions)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand hooks; and __fish_seen_subcommand_from help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and not __fish_seen_subcommand_from list status set set-provider help" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and not __fish_seen_subcommand_from list status set set-provider help" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and not __fish_seen_subcommand_from list status set set-provider help" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and not __fish_seen_subcommand_from list status set set-provider help" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and not __fish_seen_subcommand_from list status set set-provider help" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and not __fish_seen_subcommand_from list status set set-provider help" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and not __fish_seen_subcommand_from list status set set-provider help" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and not __fish_seen_subcommand_from list status set set-provider help" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and not __fish_seen_subcommand_from list status set set-provider help" -f -a "list" -d 'List providers (or available models for a specific provider)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and not __fish_seen_subcommand_from list status set set-provider help" -f -a "status" -d 'Show current model configuration'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and not __fish_seen_subcommand_from list status set set-provider help" -f -a "set" -d 'Set the default model'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and not __fish_seen_subcommand_from list status set set-provider help" -f -a "set-provider" -d 'Set the LLM provider'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and not __fish_seen_subcommand_from list status set set-provider help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from list" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from list" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from list" -s v -l verbose -d 'Show detailed information (env vars, base URL, protocol)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from list" -l json -d 'Output as JSON'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from list" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from list" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from list" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from list" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from list" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from list" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from status" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from status" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from status" -l json -d 'Output as JSON'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from status" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from status" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from status" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from status" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from status" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from status" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from set" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from set" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from set" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from set" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from set" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from set" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from set" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from set" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from set-provider" -l model -d 'Also set the model (defaults to provider\'s default model)' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from set-provider" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from set-provider" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from set-provider" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from set-provider" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from set-provider" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from set-provider" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from set-provider" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from set-provider" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from help" -f -a "list" -d 'List providers (or available models for a specific provider)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from help" -f -a "status" -d 'Show current model configuration'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from help" -f -a "set" -d 'Set the default model'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from help" -f -a "set-provider" -d 'Set the LLM provider'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand models; and __fish_seen_subcommand_from help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand doctor" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand doctor" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand doctor" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand doctor" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand doctor" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand doctor" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand doctor" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand doctor" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand logs" -s l -l limit -d 'Maximum number of lines to show (default: 200)' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand logs" -l url -d 'Gateway URL (default: http://{GATEWAY_HOST}:{GATEWAY_PORT})' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand logs" -l token -d 'Gateway auth token (reads GATEWAY_AUTH_TOKEN env if not set)' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand logs" -l timeout -d 'Connection timeout in milliseconds (default: 5000)' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand logs" -l level -d 'Get or set runtime log level. Without a value, shows current level. With a value (trace|debug|info|warn|error), sets the level' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand logs" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand logs" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand logs" -s f -l follow -d 'Stream live logs from the running gateway via SSE. Replays recent history then streams new entries in real time'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand logs" -l json -d 'Output log entries as JSON (one object per line)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand logs" -l local-time -d 'Display timestamps in local timezone'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand logs" -l plain -d 'Plain text output (no ANSI styling)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand logs" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand logs" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand logs" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand logs" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand logs" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand logs" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand status" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand status" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand status" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand status" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand status" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand status" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand status" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand status" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand completion" -l shell -d 'The shell to generate completions for' -r -f -a "bash\t''
elvish\t''
fish\t''
powershell\t''
zsh\t''"
complete -c lunarwing -n "__fish_lunarwing_using_subcommand completion" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand completion" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand completion" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand completion" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand completion" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand completion" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand completion" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand completion" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand login" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand login" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand login" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand login" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand login" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand login" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand login" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand login" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand worker" -l job-id -d 'Job ID to execute' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand worker" -l orchestrator-url -d 'URL of the orchestrator\'s internal API' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand worker" -l max-iterations -d 'Maximum iterations before stopping' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand worker" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand worker" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand worker" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand worker" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand worker" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand worker" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand worker" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand worker" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and not __fish_seen_subcommand_from add remove list toggle test help" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and not __fish_seen_subcommand_from add remove list toggle test help" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and not __fish_seen_subcommand_from add remove list toggle test help" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and not __fish_seen_subcommand_from add remove list toggle test help" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and not __fish_seen_subcommand_from add remove list toggle test help" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and not __fish_seen_subcommand_from add remove list toggle test help" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and not __fish_seen_subcommand_from add remove list toggle test help" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and not __fish_seen_subcommand_from add remove list toggle test help" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and not __fish_seen_subcommand_from add remove list toggle test help" -f -a "add" -d 'Add an ACP agent'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and not __fish_seen_subcommand_from add remove list toggle test help" -f -a "remove" -d 'Remove an ACP agent'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and not __fish_seen_subcommand_from add remove list toggle test help" -f -a "list" -d 'List configured ACP agents'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and not __fish_seen_subcommand_from add remove list toggle test help" -f -a "toggle" -d 'Enable or disable an ACP agent'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and not __fish_seen_subcommand_from add remove list toggle test help" -f -a "test" -d 'Test an ACP agent connection (spawn, handshake, report)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and not __fish_seen_subcommand_from add remove list toggle test help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from add" -l command -d 'Command to spawn the agent' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from add" -l arg -d 'Command arguments (can be repeated)' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from add" -l env -d 'Environment variables (KEY=VALUE format, can be repeated)' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from add" -l description -d 'Agent description' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from add" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from add" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from add" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from add" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from add" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from add" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from add" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from add" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from remove" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from remove" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from remove" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from remove" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from remove" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from remove" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from remove" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from remove" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from list" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from list" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from list" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from list" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from list" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from list" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from list" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from list" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from toggle" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from toggle" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from toggle" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from toggle" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from toggle" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from toggle" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from toggle" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from toggle" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from test" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from test" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from test" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from test" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from test" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from test" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from test" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from test" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from help" -f -a "add" -d 'Add an ACP agent'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from help" -f -a "remove" -d 'Remove an ACP agent'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from help" -f -a "list" -d 'List configured ACP agents'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from help" -f -a "toggle" -d 'Enable or disable an ACP agent'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from help" -f -a "test" -d 'Test an ACP agent connection (spawn, handshake, report)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp; and __fish_seen_subcommand_from help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp-bridge" -l job-id -d 'Job ID to execute' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp-bridge" -l orchestrator-url -d 'URL of the orchestrator\'s internal API' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp-bridge" -s m -l message -d 'Single message mode - send one message and exit' -r
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp-bridge" -s c -l config -d 'Configuration file path (optional, uses env vars by default)' -r -F
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp-bridge" -l cli-only -d 'Run in interactive CLI mode only (disable other channels)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp-bridge" -l no-db -d 'Skip database connection (for testing)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp-bridge" -l no-onboard -d 'Skip first-run onboarding check'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp-bridge" -l auto-approve -d 'Auto-approve tool execution (shell, file writes, HTTP, etc.)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp-bridge" -l supervised -d 'Enable supervised mode — every tool action requires human approval regardless of the tool\'s normal tier'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand acp-bridge" -s h -l help -d 'Print help (see more with \'--help\')'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and not __fish_seen_subcommand_from run onboard config tool registry channels reflex routines mcp memory pairing service repl skills hooks models doctor logs status completion login worker acp acp-bridge help" -f -a "run" -d 'Run the AI agent'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and not __fish_seen_subcommand_from run onboard config tool registry channels reflex routines mcp memory pairing service repl skills hooks models doctor logs status completion login worker acp acp-bridge help" -f -a "onboard" -d 'Run interactive setup wizard'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and not __fish_seen_subcommand_from run onboard config tool registry channels reflex routines mcp memory pairing service repl skills hooks models doctor logs status completion login worker acp acp-bridge help" -f -a "config" -d 'Manage app configs'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and not __fish_seen_subcommand_from run onboard config tool registry channels reflex routines mcp memory pairing service repl skills hooks models doctor logs status completion login worker acp acp-bridge help" -f -a "tool" -d 'Manage WASM tools'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and not __fish_seen_subcommand_from run onboard config tool registry channels reflex routines mcp memory pairing service repl skills hooks models doctor logs status completion login worker acp acp-bridge help" -f -a "registry" -d 'Browse/install extensions'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and not __fish_seen_subcommand_from run onboard config tool registry channels reflex routines mcp memory pairing service repl skills hooks models doctor logs status completion login worker acp acp-bridge help" -f -a "channels" -d 'Manage channels'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and not __fish_seen_subcommand_from run onboard config tool registry channels reflex routines mcp memory pairing service repl skills hooks models doctor logs status completion login worker acp acp-bridge help" -f -a "reflex" -d 'Manage reflex patterns'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and not __fish_seen_subcommand_from run onboard config tool registry channels reflex routines mcp memory pairing service repl skills hooks models doctor logs status completion login worker acp acp-bridge help" -f -a "routines" -d 'Manage routines'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and not __fish_seen_subcommand_from run onboard config tool registry channels reflex routines mcp memory pairing service repl skills hooks models doctor logs status completion login worker acp acp-bridge help" -f -a "mcp" -d 'Manage MCP servers'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and not __fish_seen_subcommand_from run onboard config tool registry channels reflex routines mcp memory pairing service repl skills hooks models doctor logs status completion login worker acp acp-bridge help" -f -a "memory" -d 'Manage workspace memory'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and not __fish_seen_subcommand_from run onboard config tool registry channels reflex routines mcp memory pairing service repl skills hooks models doctor logs status completion login worker acp acp-bridge help" -f -a "pairing" -d 'Manage DM pairing'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and not __fish_seen_subcommand_from run onboard config tool registry channels reflex routines mcp memory pairing service repl skills hooks models doctor logs status completion login worker acp acp-bridge help" -f -a "service" -d 'Manage OS service'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and not __fish_seen_subcommand_from run onboard config tool registry channels reflex routines mcp memory pairing service repl skills hooks models doctor logs status completion login worker acp acp-bridge help" -f -a "repl" -d 'Connect to running daemon via REPL'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and not __fish_seen_subcommand_from run onboard config tool registry channels reflex routines mcp memory pairing service repl skills hooks models doctor logs status completion login worker acp acp-bridge help" -f -a "skills" -d 'Manage skills'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and not __fish_seen_subcommand_from run onboard config tool registry channels reflex routines mcp memory pairing service repl skills hooks models doctor logs status completion login worker acp acp-bridge help" -f -a "hooks" -d 'Manage lifecycle hooks'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and not __fish_seen_subcommand_from run onboard config tool registry channels reflex routines mcp memory pairing service repl skills hooks models doctor logs status completion login worker acp acp-bridge help" -f -a "models" -d 'Manage LLM providers and models'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and not __fish_seen_subcommand_from run onboard config tool registry channels reflex routines mcp memory pairing service repl skills hooks models doctor logs status completion login worker acp acp-bridge help" -f -a "doctor" -d 'Run diagnostics'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and not __fish_seen_subcommand_from run onboard config tool registry channels reflex routines mcp memory pairing service repl skills hooks models doctor logs status completion login worker acp acp-bridge help" -f -a "logs" -d 'View and manage gateway logs'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and not __fish_seen_subcommand_from run onboard config tool registry channels reflex routines mcp memory pairing service repl skills hooks models doctor logs status completion login worker acp acp-bridge help" -f -a "status" -d 'Show system status'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and not __fish_seen_subcommand_from run onboard config tool registry channels reflex routines mcp memory pairing service repl skills hooks models doctor logs status completion login worker acp acp-bridge help" -f -a "completion" -d 'Generate completions'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and not __fish_seen_subcommand_from run onboard config tool registry channels reflex routines mcp memory pairing service repl skills hooks models doctor logs status completion login worker acp acp-bridge help" -f -a "login" -d 'Authenticate with a provider'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and not __fish_seen_subcommand_from run onboard config tool registry channels reflex routines mcp memory pairing service repl skills hooks models doctor logs status completion login worker acp acp-bridge help" -f -a "worker" -d 'Run as a sandboxed worker inside a Docker container (internal use). This is invoked automatically by the orchestrator, not by users directly'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and not __fish_seen_subcommand_from run onboard config tool registry channels reflex routines mcp memory pairing service repl skills hooks models doctor logs status completion login worker acp acp-bridge help" -f -a "acp" -d 'Manage ACP agents'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and not __fish_seen_subcommand_from run onboard config tool registry channels reflex routines mcp memory pairing service repl skills hooks models doctor logs status completion login worker acp acp-bridge help" -f -a "acp-bridge" -d 'Run as an ACP bridge inside a Docker container (internal use)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and not __fish_seen_subcommand_from run onboard config tool registry channels reflex routines mcp memory pairing service repl skills hooks models doctor logs status completion login worker acp acp-bridge help" -f -a "help" -d 'Print this message or the help of the given subcommand(s)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from config" -f -a "init" -d 'Generate a default config.toml file'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from config" -f -a "list" -d 'List all settings and their current values'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from config" -f -a "get" -d 'Get a specific setting value'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from config" -f -a "set" -d 'Set a setting value'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from config" -f -a "reset" -d 'Reset a setting to its default value'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from config" -f -a "path" -d 'Show the settings storage info'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from tool" -f -a "install" -d 'Install a WASM tool from source directory or .wasm file'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from tool" -f -a "list" -d 'List installed tools'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from tool" -f -a "remove" -d 'Remove an installed tool'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from tool" -f -a "info" -d 'Show information about a tool'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from tool" -f -a "auth" -d 'Configure authentication for a tool'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from tool" -f -a "setup" -d 'Configure required secrets for a tool (from setup.required_secrets)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from registry" -f -a "list" -d 'List available extensions in the registry'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from registry" -f -a "info" -d 'Show detailed information about an extension or bundle'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from registry" -f -a "install" -d 'Install an extension or bundle from the registry'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from registry" -f -a "install-defaults" -d 'Install the default bundle of recommended extensions'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from channels" -f -a "list" -d 'List all configured channels'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from reflex" -f -a "list" -d 'List reflex patterns'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from reflex" -f -a "show" -d 'Show details for a specific reflex pattern'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from reflex" -f -a "delete" -d 'Delete a reflex pattern'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from reflex" -f -a "status" -d 'Show reflex compiler status'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from reflex" -f -a "prune" -d 'Prune (auto-disable) reflex patterns that haven\'t matched recently'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from routines" -f -a "list" -d 'List routines'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from routines" -f -a "create" -d 'Create a new cron routine'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from routines" -f -a "edit" -d 'Edit an existing routine'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from routines" -f -a "enable" -d 'Enable a routine'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from routines" -f -a "disable" -d 'Disable a routine'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from routines" -f -a "delete" -d 'Delete a routine'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from routines" -f -a "history" -d 'Show run history for a routine'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from mcp" -f -a "add" -d 'Add an MCP server'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from mcp" -f -a "remove" -d 'Remove an MCP server'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from mcp" -f -a "list" -d 'List configured MCP servers'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from mcp" -f -a "auth" -d 'Authenticate with an MCP server (OAuth flow)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from mcp" -f -a "test" -d 'Test connection to an MCP server'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from mcp" -f -a "toggle" -d 'Enable or disable an MCP server'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from memory" -f -a "search" -d 'Search workspace memory (hybrid full-text + semantic)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from memory" -f -a "read" -d 'Read a file from the workspace'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from memory" -f -a "write" -d 'Write content to a workspace file'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from memory" -f -a "tree" -d 'Show workspace directory tree'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from memory" -f -a "status" -d 'Show workspace status (document count, index health)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from pairing" -f -a "list" -d 'List pending pairing requests'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from pairing" -f -a "approve" -d 'Approve a pairing request by code'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from service" -f -a "install" -d 'Install the OS service (launchd on macOS, systemd/OpenRC on Linux)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from service" -f -a "start" -d 'Start the installed service'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from service" -f -a "stop" -d 'Stop the running service'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from service" -f -a "status" -d 'Show service status'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from service" -f -a "uninstall" -d 'Uninstall the OS service and remove the unit file'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from skills" -f -a "list" -d 'List all discovered skills'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from skills" -f -a "search" -d 'Search ClawHub registry for skills'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from skills" -f -a "info" -d 'Show detailed info about a specific skill'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from hooks" -f -a "list" -d 'List discoverable hooks (bundled + plugin; not filtered by active extensions)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from models" -f -a "list" -d 'List providers (or available models for a specific provider)'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from models" -f -a "status" -d 'Show current model configuration'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from models" -f -a "set" -d 'Set the default model'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from models" -f -a "set-provider" -d 'Set the LLM provider'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from acp" -f -a "add" -d 'Add an ACP agent'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from acp" -f -a "remove" -d 'Remove an ACP agent'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from acp" -f -a "list" -d 'List configured ACP agents'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from acp" -f -a "toggle" -d 'Enable or disable an ACP agent'
complete -c lunarwing -n "__fish_lunarwing_using_subcommand help; and __fish_seen_subcommand_from acp" -f -a "test" -d 'Test an ACP agent connection (spawn, handshake, report)'
