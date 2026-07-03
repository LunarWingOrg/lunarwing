//! OS service management for running LunarWing as a daemon.
//!
//! Generates and manages platform-native service definitions:
//! - **macOS**: launchd plist at `~/Library/LaunchAgents/com.lunarwing.daemon.plist`
//! - **Linux/systemd**: user unit at `~/.config/systemd/user/lunarwing.service`
//! - **Linux/OpenRC**: init script at `/etc/init.d/lunarwing`
//!
//! The installed service runs `lunarwing run` (the default agent mode) and is
//! configured to restart automatically on failure.

use std::path::{Path, PathBuf};
use std::process::Command;
#[cfg(unix)]
use std::{fs::Permissions, os::unix::fs::PermissionsExt};

use anyhow::{Context, Result, bail};

use crate::bootstrap::lunarwing_base_dir;

const SERVICE_LABEL: &str = "com.lunarwing.daemon";
const LEGACY_SERVICE_LABEL: &str = "com.ironclaw.daemon";
const SYSTEMD_UNIT: &str = "lunarwing.service";
const LEGACY_SYSTEMD_UNIT: &str = "ironclaw.service";
const SYSTEMD_XMPP_BRIDGE_UNIT: &str = "xmpp-bridge.service";
const OPENRC_UNIT: &str = "lunarwing";
const OPENRC_XMPP_BRIDGE_UNIT: &str = "xmpp-bridge";
const OPENRC_LUNARWING_INIT: &str = include_str!("../systemd/lunarwing.openrc");
const OPENRC_XMPP_BRIDGE_INIT: &str = include_str!("../systemd/xmpp-bridge.openrc");
const OPENRC_LUNARWING_ENV_TEMPLATE: &str = "# Optional environment overrides for LunarWing.\n\
# Add secrets or one-off overrides here when they must not live in config.toml.\n\
# Example to override the runtime banner / agent identity:\n\
# AGENT_NAME=lunarwing\n\
# Example defaults used by the launcher and service path for local/private infra:\n\
# ALLOW_PRIVATE_IPS=1\n\
# PGSSLMODE=disable\n\
# Example for OpenAI-compatible endpoints that insist on a placeholder key:\n\
# LLM_API_KEY=unneeded\n";
const OPENRC_XMPP_BRIDGE_ENV_TEMPLATE: &str =
    "# Optional environment overrides for the LunarWing XMPP bridge.\n";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServiceManager {
    Launchd,
    SystemdUser,
    OpenRc,
}

impl ServiceManager {
    pub fn display_name(self) -> &'static str {
        match self {
            ServiceManager::Launchd => "launchd",
            ServiceManager::SystemdUser => "systemd user",
            ServiceManager::OpenRc => "OpenRC",
        }
    }

    pub(crate) fn install_artifact(self) -> &'static str {
        match self {
            ServiceManager::Launchd => "launchd plist",
            ServiceManager::SystemdUser => "systemd user unit",
            ServiceManager::OpenRc => "OpenRC service",
        }
    }
}

#[derive(Debug, Clone)]
pub struct ServiceInstallation {
    pub manager: ServiceManager,
    pub path: PathBuf,
}

#[derive(Debug, Clone)]
pub struct SetupServiceOffer {
    pub manager: ServiceManager,
    pub can_install_now: bool,
    pub install_command: Option<String>,
}

// ── Public dispatch ─────────────────────────────────────────────

pub fn detected_service_manager() -> Result<ServiceManager> {
    if cfg!(target_os = "macos") {
        Ok(ServiceManager::Launchd)
    } else if cfg!(target_os = "linux") {
        detect_linux_service_manager()
    } else {
        bail!("Service management is only supported on macOS and Linux");
    }
}

pub fn service_installation() -> Result<ServiceInstallation> {
    let manager = detected_service_manager()?;
    let path = match manager {
        ServiceManager::Launchd => macos_plist_path()?,
        ServiceManager::SystemdUser => linux_unit_path()?,
        ServiceManager::OpenRc => linux_openrc_init_path(OPENRC_UNIT),
    };
    Ok(ServiceInstallation { manager, path })
}

pub fn setup_service_offer() -> Result<Option<SetupServiceOffer>> {
    if !cfg!(target_os = "macos") && !cfg!(target_os = "linux") {
        return Ok(None);
    }

    let manager = detected_service_manager()?;
    let can_install_now = match manager {
        ServiceManager::Launchd | ServiceManager::SystemdUser => true,
        ServiceManager::OpenRc => is_effective_root(),
    };
    let install_command = if can_install_now || manager != ServiceManager::OpenRc {
        None
    } else {
        Some(openrc_command_hint("install")?)
    };

    Ok(Some(SetupServiceOffer {
        manager,
        can_install_now,
        install_command,
    }))
}

/// Route a service subcommand to the appropriate handler.
pub fn handle_command(command: &ServiceAction) -> Result<()> {
    match command {
        ServiceAction::Install => install(),
        ServiceAction::Start => start(),
        ServiceAction::Stop => stop(),
        ServiceAction::Status => status(),
        ServiceAction::Uninstall => uninstall(),
    }
}

/// The five service lifecycle actions.
#[derive(Debug, Clone)]
pub enum ServiceAction {
    Install,
    Start,
    Stop,
    Status,
    Uninstall,
}

// ── Install ─────────────────────────────────────────────────────

fn install() -> Result<()> {
    match detected_service_manager()? {
        ServiceManager::Launchd => install_macos(),
        ServiceManager::SystemdUser => install_linux_systemd_user(),
        ServiceManager::OpenRc => install_linux_openrc(),
    }
}

fn install_macos() -> Result<()> {
    let file = macos_plist_path()?;
    if let Some(parent) = file.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let exe = std::env::current_exe().context("failed to resolve current executable")?;
    let logs_dir = lunarwing_logs_dir();
    std::fs::create_dir_all(&logs_dir)?;

    let stdout = logs_dir.join("daemon.stdout.log");
    let stderr = logs_dir.join("daemon.stderr.log");

    let plist = macos_plist_content(
        &exe.display().to_string(),
        &stdout.display().to_string(),
        &stderr.display().to_string(),
    );

    std::fs::write(&file, plist)?;
    disable_legacy_macos_service().ok();
    println!("Installed launchd service: {}", file.display());
    println!("  Start with: lunarwing service start");
    Ok(())
}

fn macos_plist_content(exe: &str, stdout: &str, stderr: &str) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{exe}</string>
    <string>run</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <!-- Disable interactive CLI/REPL in daemon mode to prevent blocking on stdin -->
  <key>EnvironmentVariables</key>
  <dict>
    <key>CLI_ENABLED</key>
    <string>false</string>
  </dict>
  <key>StandardOutPath</key>
  <string>{stdout}</string>
  <key>StandardErrorPath</key>
  <string>{stderr}</string>
</dict>
</plist>
"#,
        label = SERVICE_LABEL,
        exe = xml_escape(exe),
        stdout = xml_escape(stdout),
        stderr = xml_escape(stderr),
    )
}

fn install_linux_systemd_user() -> Result<()> {
    let file = linux_unit_path()?;
    if let Some(parent) = file.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let exe = std::env::current_exe().context("failed to resolve current executable")?;
    let bridge_exe = linux_bridge_executable_path(&exe);
    let unit = linux_unit_content(&exe, bridge_exe.is_some());

    std::fs::write(&file, unit)?;
    if let Some(bridge_exe) = bridge_exe {
        let bridge_file = linux_xmpp_bridge_unit_path()?;
        std::fs::write(&bridge_file, linux_xmpp_bridge_unit_content(&bridge_exe))?;
    }
    disable_legacy_linux_unit().ok();
    run_checked(Command::new("systemctl").args(["--user", "daemon-reload"])).ok();
    run_checked(Command::new("systemctl").args(["--user", "enable", SYSTEMD_UNIT])).ok();
    if linux_xmpp_bridge_unit_path()?.exists() {
        run_checked(Command::new("systemctl").args(["--user", "enable", SYSTEMD_XMPP_BRIDGE_UNIT]))
            .ok();
    }
    println!("Installed systemd user service: {}", file.display());
    if let Some(bridge_exe) = linux_bridge_executable_path(&exe) {
        println!(
            "Installed XMPP bridge user service: {} ({})",
            linux_xmpp_bridge_unit_path()?.display(),
            bridge_exe.display()
        );
    } else {
        println!(
            "Skipped XMPP bridge user service install: bridge binary not found next to this checkout"
        );
    }
    println!("  Start with: lunarwing service start");
    Ok(())
}

fn install_linux_openrc() -> Result<()> {
    ensure_openrc_root("install")?;

    let exe = std::env::current_exe().context("failed to resolve current executable")?;
    let base_dir = lunarwing_base_dir();
    let logs_dir = base_dir.join("logs");
    let bridge_exe = linux_bridge_executable_path(&exe);
    let (service_user, service_group) = current_service_identity();

    write_text_file_with_mode(
        &linux_openrc_init_path(OPENRC_UNIT),
        OPENRC_LUNARWING_INIT,
        0o755,
    )?;
    write_text_file_with_mode(
        &linux_openrc_confd_path(OPENRC_UNIT),
        &linux_openrc_confd_content(
            &exe,
            &base_dir,
            &logs_dir,
            &service_user,
            &service_group,
            bridge_exe.is_some(),
        ),
        0o644,
    )?;
    ensure_text_file_with_mode(
        &linux_openrc_env_path("lunarwing.env"),
        OPENRC_LUNARWING_ENV_TEMPLATE,
        0o600,
    )?;

    run_checked(Command::new("rc-update").args(["add", OPENRC_UNIT, "default"])).ok();

    println!(
        "Installed OpenRC service: {}",
        linux_openrc_init_path(OPENRC_UNIT).display()
    );
    println!(
        "Installed OpenRC config: {}",
        linux_openrc_confd_path(OPENRC_UNIT).display()
    );

    if let Some(bridge_exe) = bridge_exe {
        write_text_file_with_mode(
            &linux_openrc_init_path(OPENRC_XMPP_BRIDGE_UNIT),
            OPENRC_XMPP_BRIDGE_INIT,
            0o755,
        )?;
        write_text_file_with_mode(
            &linux_openrc_confd_path(OPENRC_XMPP_BRIDGE_UNIT),
            &linux_openrc_bridge_confd_content(
                &bridge_exe,
                &base_dir,
                &logs_dir,
                &service_user,
                &service_group,
            ),
            0o644,
        )?;
        ensure_text_file_with_mode(
            &linux_openrc_env_path("xmpp-bridge.env"),
            OPENRC_XMPP_BRIDGE_ENV_TEMPLATE,
            0o600,
        )?;
        run_checked(Command::new("rc-update").args(["add", OPENRC_XMPP_BRIDGE_UNIT, "default"]))
            .ok();
        println!(
            "Installed OpenRC XMPP bridge service: {} ({})",
            linux_openrc_init_path(OPENRC_XMPP_BRIDGE_UNIT).display(),
            bridge_exe.display()
        );
    } else {
        println!(
            "Skipped OpenRC XMPP bridge install: bridge binary not found next to this checkout"
        );
    }

    println!("  Start with: lunarwing service start");
    Ok(())
}

// ── Start ───────────────────────────────────────────────────────

fn start() -> Result<()> {
    match detected_service_manager()? {
        ServiceManager::Launchd => {
            let plist = macos_plist_path()?;
            if !plist.exists() {
                bail!("Service not installed. Run `lunarwing service install` first.");
            }
            run_checked(Command::new("launchctl").arg("load").arg("-w").arg(&plist))?;
            run_checked(Command::new("launchctl").arg("start").arg(SERVICE_LABEL))?;
            println!("Service started");
            Ok(())
        }
        ServiceManager::SystemdUser => {
            run_checked(Command::new("systemctl").args(["--user", "daemon-reload"]))?;
            if linux_xmpp_bridge_unit_path()?.exists() {
                run_checked(Command::new("systemctl").args([
                    "--user",
                    "start",
                    SYSTEMD_XMPP_BRIDGE_UNIT,
                ]))
                .ok();
            }
            run_checked(Command::new("systemctl").args(["--user", "start", SYSTEMD_UNIT]))?;
            println!("Service started");
            Ok(())
        }
        ServiceManager::OpenRc => start_linux_openrc(),
    }
}

// ── Stop ────────────────────────────────────────────────────────

fn stop() -> Result<()> {
    match detected_service_manager()? {
        ServiceManager::Launchd => {
            let plist = macos_plist_path()?;
            run_checked(Command::new("launchctl").arg("stop").arg(SERVICE_LABEL)).ok();
            run_checked(
                Command::new("launchctl")
                    .arg("unload")
                    .arg("-w")
                    .arg(&plist),
            )
            .ok();
            println!("Service stopped");
            Ok(())
        }
        ServiceManager::SystemdUser => {
            run_checked(Command::new("systemctl").args(["--user", "stop", SYSTEMD_UNIT])).ok();
            if linux_xmpp_bridge_unit_path()?.exists() {
                run_checked(Command::new("systemctl").args([
                    "--user",
                    "stop",
                    SYSTEMD_XMPP_BRIDGE_UNIT,
                ]))
                .ok();
            }
            println!("Service stopped");
            Ok(())
        }
        ServiceManager::OpenRc => stop_linux_openrc(),
    }
}

// ── Status ──────────────────────────────────────────────────────

fn status() -> Result<()> {
    match detected_service_manager()? {
        ServiceManager::Launchd => {
            let out = run_capture(Command::new("launchctl").arg("list"))?;
            let running = out.lines().any(|line| line.contains(SERVICE_LABEL));
            println!(
                "Service: {}",
                if running {
                    "running/loaded"
                } else {
                    "not loaded"
                }
            );
            println!("Unit: {}", macos_plist_path()?.display());
            Ok(())
        }
        ServiceManager::SystemdUser => {
            let state =
                run_capture(Command::new("systemctl").args(["--user", "is-active", SYSTEMD_UNIT]))
                    .unwrap_or_else(|_| "unknown".into());
            println!("Service state: {}", state.trim());
            println!("Unit: {}", linux_unit_path()?.display());
            let bridge_file = linux_xmpp_bridge_unit_path()?;
            if bridge_file.exists() {
                let bridge_state = run_capture(Command::new("systemctl").args([
                    "--user",
                    "is-active",
                    SYSTEMD_XMPP_BRIDGE_UNIT,
                ]))
                .unwrap_or_else(|_| "unknown".into());
                println!("XMPP bridge state: {}", bridge_state.trim());
                println!("XMPP bridge unit: {}", bridge_file.display());
            }
            Ok(())
        }
        ServiceManager::OpenRc => status_linux_openrc(),
    }
}

// ── Uninstall ───────────────────────────────────────────────────

fn uninstall() -> Result<()> {
    // Stop first (ignore errors, service might not be running)
    stop().ok();

    match detected_service_manager()? {
        ServiceManager::Launchd => {
            let file = macos_plist_path()?;
            if file.exists() {
                std::fs::remove_file(&file)
                    .with_context(|| format!("failed to remove {}", file.display()))?;
            }
            println!("Service uninstalled ({})", file.display());
            Ok(())
        }
        ServiceManager::SystemdUser => uninstall_linux_systemd_user(),
        ServiceManager::OpenRc => uninstall_linux_openrc(),
    }
}

// ── Path helpers ────────────────────────────────────────────────

fn macos_plist_path() -> Result<PathBuf> {
    let home = dirs::home_dir().context("could not find home directory")?;
    Ok(home
        .join("Library")
        .join("LaunchAgents")
        .join(format!("{SERVICE_LABEL}.plist")))
}

fn linux_unit_path() -> Result<PathBuf> {
    Ok(linux_systemd_unit_dir()?.join(SYSTEMD_UNIT))
}

fn linux_xmpp_bridge_unit_path() -> Result<PathBuf> {
    Ok(linux_systemd_unit_dir()?.join(SYSTEMD_XMPP_BRIDGE_UNIT))
}

fn linux_legacy_unit_path() -> Result<PathBuf> {
    Ok(linux_systemd_unit_dir()?.join(LEGACY_SYSTEMD_UNIT))
}

fn linux_systemd_unit_dir() -> Result<PathBuf> {
    let home = dirs::home_dir().context("could not find home directory")?;
    Ok(home.join(".config").join("systemd").join("user"))
}

fn linux_openrc_init_path(name: &str) -> PathBuf {
    PathBuf::from("/etc/init.d").join(name)
}

fn linux_openrc_confd_path(name: &str) -> PathBuf {
    PathBuf::from("/etc/conf.d").join(name)
}

fn linux_openrc_env_path(name: &str) -> PathBuf {
    PathBuf::from("/etc/lunarwing").join(name)
}

fn linux_openrc_env_dir() -> PathBuf {
    PathBuf::from("/etc/lunarwing")
}

fn lunarwing_logs_dir() -> PathBuf {
    lunarwing_base_dir().join("logs")
}

fn disable_legacy_linux_unit() -> Result<()> {
    if LEGACY_SYSTEMD_UNIT == SYSTEMD_UNIT {
        return Ok(());
    }

    let legacy_file = linux_legacy_unit_path()?;
    if !legacy_file.exists() {
        return Ok(());
    }

    match run_checked(Command::new("systemctl").args([
        "--user",
        "disable",
        "--now",
        LEGACY_SYSTEMD_UNIT,
    ])) {
        Ok(()) => println!(
            "Disabled legacy systemd user service: {}",
            legacy_file.display()
        ),
        Err(e) => println!(
            "Legacy systemd user service still exists at {}. \
             Disable it manually to avoid running two daemons: {}",
            legacy_file.display(),
            e
        ),
    }

    Ok(())
}

fn disable_legacy_macos_service() -> Result<()> {
    if LEGACY_SERVICE_LABEL == SERVICE_LABEL {
        return Ok(());
    }

    let home = dirs::home_dir().context("could not find home directory")?;
    let legacy_file = home
        .join("Library")
        .join("LaunchAgents")
        .join(format!("{LEGACY_SERVICE_LABEL}.plist"));
    if !legacy_file.exists() {
        return Ok(());
    }

    run_checked(
        Command::new("launchctl")
            .arg("stop")
            .arg(LEGACY_SERVICE_LABEL),
    )
    .ok();
    match run_checked(
        Command::new("launchctl")
            .arg("unload")
            .arg("-w")
            .arg(&legacy_file),
    ) {
        Ok(()) => println!("Unloaded legacy launchd service: {}", legacy_file.display()),
        Err(e) => println!(
            "Legacy launchd service still exists at {}. \
             Unload it manually to avoid running two daemons: {}",
            legacy_file.display(),
            e
        ),
    }

    Ok(())
}

fn linux_unit_content(exe: &Path, include_xmpp_bridge: bool) -> String {
    let bridge_unit_lines = if include_xmpp_bridge {
        format!(
            "Wants={bridge}\n\
             After=network.target {bridge}\n",
            bridge = SYSTEMD_XMPP_BRIDGE_UNIT
        )
    } else {
        "After=network.target\n".to_string()
    };

    format!(
        "[Unit]\n\
         Description=LunarWing daemon\n\
         {bridge_unit_lines}\
         \n\
         [Service]\n\
         Type=simple\n\
         # Disable interactive CLI/REPL in daemon mode to prevent blocking on stdin\n\
         Environment=\"CLI_ENABLED=false\"\n\
         Environment=\"AGENT_NAME=lunarwing\"\n\
         Environment=\"ALLOW_PRIVATE_IPS=1\"\n\
         Environment=\"PGSSLMODE=disable\"\n\
         ExecStart=\"{exe}\" run\n\
         Restart=always\n\
         RestartSec=3\n\
         \n\
         [Install]\n\
         WantedBy=default.target\n",
        exe = exe.display(),
        bridge_unit_lines = bridge_unit_lines,
    )
}

fn linux_xmpp_bridge_unit_content(exe: &Path) -> String {
    format!(
        "[Unit]\n\
         Description=LunarWing XMPP bridge\n\
         After=network.target\n\
         PartOf={main_unit}\n\
         \n\
         [Service]\n\
         Type=simple\n\
         ExecStart=\"{exe}\"\n\
         Restart=always\n\
         RestartSec=3\n\
         \n\
         [Install]\n\
         WantedBy=default.target\n",
        main_unit = SYSTEMD_UNIT,
        exe = exe.display(),
    )
}

fn linux_bridge_executable_path(lunarwing_exe: &Path) -> Option<PathBuf> {
    if let Ok(explicit) = std::env::var("XMPP_BRIDGE_EXECUTABLE") {
        let path = PathBuf::from(explicit.trim());
        if path.is_file() {
            return Some(path);
        }
    }

    let mut candidates = Vec::new();

    if let Some(exe_dir) = lunarwing_exe.parent() {
        candidates.push(exe_dir.join("xmpp-bridge"));

        if let (Some(target_dir), Some(profile_dir_name)) = (exe_dir.parent(), exe_dir.file_name())
            && let Some(repo_root) = target_dir.parent()
        {
            candidates.push(
                repo_root
                    .join("bridges")
                    .join("xmpp-bridge")
                    .join("target")
                    .join(profile_dir_name)
                    .join("xmpp-bridge"),
            );
        }
    }

    candidates.into_iter().find(|path| path.is_file())
}

fn linux_openrc_confd_content(
    exe: &Path,
    base_dir: &Path,
    logs_dir: &Path,
    user: &str,
    group: &str,
    include_xmpp_bridge: bool,
) -> String {
    let mut content = format!(
        "# /etc/conf.d/lunarwing\n\
         # Generated by `lunarwing service install`.\n\
         lunarwing_command={command}\n\
         lunarwing_args='--no-onboard run'\n\
         lunarwing_user={user}\n\
         lunarwing_group={group}\n\
         lunarwing_workdir={workdir}\n\
         lunarwing_state_dir={state_dir}\n\
         lunarwing_runtime_dir='/run/lunarwing'\n\
         lunarwing_log_dir={log_dir}\n\
         lunarwing_output_log={output_log}\n\
         lunarwing_error_log={error_log}\n\
         lunarwing_env_file='/etc/lunarwing/lunarwing.env'\n\
         lunarwing_cli_enabled='false'\n\
         lunarwing_agent_name='lunarwing'\n\
         lunarwing_allow_private_ips='1'\n\
         lunarwing_pgsslmode='disable'\n\
         lunarwing_base_dir={base_dir}\n\
         lunarwing_rust_log='lunarwing=info,lunarwing=info'\n",
        command = shell_quote(&exe.display().to_string()),
        user = shell_quote(user),
        group = shell_quote(group),
        workdir = shell_quote(&base_dir.display().to_string()),
        state_dir = shell_quote(&base_dir.display().to_string()),
        log_dir = shell_quote(&logs_dir.display().to_string()),
        output_log = shell_quote(&logs_dir.join("daemon.stdout.log").display().to_string()),
        error_log = shell_quote(&logs_dir.join("daemon.stderr.log").display().to_string()),
        base_dir = shell_quote(&base_dir.display().to_string()),
    );

    if include_xmpp_bridge {
        content.push_str("lunarwing_rc_need='xmpp-bridge'\n");
    }

    content
}

fn linux_openrc_bridge_confd_content(
    exe: &Path,
    base_dir: &Path,
    logs_dir: &Path,
    user: &str,
    group: &str,
) -> String {
    format!(
        "# /etc/conf.d/xmpp-bridge\n\
         # Generated by `lunarwing service install`.\n\
         xmpp_bridge_command={command}\n\
         xmpp_bridge_user={user}\n\
         xmpp_bridge_group={group}\n\
         xmpp_bridge_workdir={workdir}\n\
         xmpp_bridge_state_dir={state_dir}\n\
         xmpp_bridge_runtime_dir='/run/lunarwing'\n\
         xmpp_bridge_log_dir={log_dir}\n\
         xmpp_bridge_output_log={output_log}\n\
         xmpp_bridge_error_log={error_log}\n\
         xmpp_bridge_env_file='/etc/lunarwing/xmpp-bridge.env'\n\
         xmpp_bridge_base_dir={base_dir}\n\
         xmpp_bridge_bind='127.0.0.1:8787'\n\
         xmpp_bridge_max_messages='1024'\n\
         xmpp_bridge_rust_log='xmpp_bridge=info,info'\n\
         xmpp_bridge_rc_before='lunarwing'\n",
        command = shell_quote(&exe.display().to_string()),
        user = shell_quote(user),
        group = shell_quote(group),
        workdir = shell_quote(&base_dir.display().to_string()),
        state_dir = shell_quote(&base_dir.display().to_string()),
        log_dir = shell_quote(&logs_dir.display().to_string()),
        output_log = shell_quote(
            &logs_dir
                .join("xmpp-bridge.stdout.log")
                .display()
                .to_string()
        ),
        error_log = shell_quote(
            &logs_dir
                .join("xmpp-bridge.stderr.log")
                .display()
                .to_string()
        ),
        base_dir = shell_quote(&base_dir.display().to_string()),
    )
}

fn detect_linux_service_manager() -> Result<ServiceManager> {
    let override_value = crate::config::helpers::env_or_override("LUNARWING_SERVICE_MANAGER")
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());

    let probe = LinuxServiceProbe {
        override_value: override_value.as_deref(),
        has_openrc_runtime: Path::new("/run/openrc/softlevel").exists(),
        has_systemd_runtime: Path::new("/run/systemd/system").exists(),
        has_rc_service: binary_exists("rc-service"),
        has_rc_update: binary_exists("rc-update"),
        has_systemctl: binary_exists("systemctl"),
    };

    detect_linux_service_manager_from_probe(&probe)
}

fn start_linux_openrc() -> Result<()> {
    let file = linux_openrc_init_path(OPENRC_UNIT);
    if !file.exists() {
        bail!("Service not installed. Run `lunarwing service install` first.");
    }

    if linux_openrc_init_path(OPENRC_XMPP_BRIDGE_UNIT).exists() {
        run_checked(Command::new("rc-service").args([OPENRC_XMPP_BRIDGE_UNIT, "start"])).ok();
    }
    run_checked(Command::new("rc-service").args([OPENRC_UNIT, "start"]))?;
    println!("Service started");
    Ok(())
}

fn stop_linux_openrc() -> Result<()> {
    run_checked(Command::new("rc-service").args([OPENRC_UNIT, "stop"])).ok();
    if linux_openrc_init_path(OPENRC_XMPP_BRIDGE_UNIT).exists() {
        run_checked(Command::new("rc-service").args([OPENRC_XMPP_BRIDGE_UNIT, "stop"])).ok();
    }
    println!("Service stopped");
    Ok(())
}

fn status_linux_openrc() -> Result<()> {
    let file = linux_openrc_init_path(OPENRC_UNIT);
    if !file.exists() {
        println!("Service state: not installed");
        println!("Unit: {}", file.display());
        return Ok(());
    }

    let state = run_capture(Command::new("rc-service").args([OPENRC_UNIT, "status"]))
        .unwrap_or_else(|_| "unknown".into());
    println!("Service state: {}", state.trim());
    println!("Unit: {}", file.display());

    let bridge_file = linux_openrc_init_path(OPENRC_XMPP_BRIDGE_UNIT);
    if bridge_file.exists() {
        let bridge_state =
            run_capture(Command::new("rc-service").args([OPENRC_XMPP_BRIDGE_UNIT, "status"]))
                .unwrap_or_else(|_| "unknown".into());
        println!("XMPP bridge state: {}", bridge_state.trim());
        println!("XMPP bridge unit: {}", bridge_file.display());
    }

    Ok(())
}

fn uninstall_linux_systemd_user() -> Result<()> {
    let file = linux_unit_path()?;
    let bridge_file = linux_xmpp_bridge_unit_path()?;
    let bridge_installed = bridge_file.exists();
    run_checked(Command::new("systemctl").args(["--user", "disable", SYSTEMD_UNIT])).ok();
    if file.exists() {
        std::fs::remove_file(&file)
            .with_context(|| format!("failed to remove {}", file.display()))?;
    }
    run_checked(Command::new("systemctl").args(["--user", "disable", SYSTEMD_XMPP_BRIDGE_UNIT]))
        .ok();
    if bridge_file.exists() {
        std::fs::remove_file(&bridge_file)
            .with_context(|| format!("failed to remove {}", bridge_file.display()))?;
    }
    run_checked(Command::new("systemctl").args(["--user", "daemon-reload"])).ok();
    println!("Service uninstalled ({})", file.display());
    if bridge_installed {
        println!(
            "XMPP bridge service uninstalled ({})",
            bridge_file.display()
        );
    }
    Ok(())
}

fn uninstall_linux_openrc() -> Result<()> {
    ensure_openrc_root("uninstall")?;

    let file = linux_openrc_init_path(OPENRC_UNIT);
    let conf = linux_openrc_confd_path(OPENRC_UNIT);
    let bridge_file = linux_openrc_init_path(OPENRC_XMPP_BRIDGE_UNIT);
    let bridge_conf = linux_openrc_confd_path(OPENRC_XMPP_BRIDGE_UNIT);

    run_checked(Command::new("rc-update").args(["del", OPENRC_UNIT, "default"])).ok();
    run_checked(Command::new("rc-update").args(["del", OPENRC_XMPP_BRIDGE_UNIT, "default"])).ok();

    if file.exists() {
        std::fs::remove_file(&file)
            .with_context(|| format!("failed to remove {}", file.display()))?;
    }
    if conf.exists() {
        std::fs::remove_file(&conf)
            .with_context(|| format!("failed to remove {}", conf.display()))?;
    }
    if bridge_file.exists() {
        std::fs::remove_file(&bridge_file)
            .with_context(|| format!("failed to remove {}", bridge_file.display()))?;
    }
    if bridge_conf.exists() {
        std::fs::remove_file(&bridge_conf)
            .with_context(|| format!("failed to remove {}", bridge_conf.display()))?;
    }

    println!("Service uninstalled ({})", file.display());
    println!(
        "Preserved environment files under {}",
        linux_openrc_env_dir().display()
    );
    Ok(())
}

// ── Shell helpers ───────────────────────────────────────────────

fn run_checked(command: &mut Command) -> Result<()> {
    let output = command.output().context("failed to spawn command")?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!("command failed: {}", stderr.trim());
    }
    Ok(())
}

fn run_capture(command: &mut Command) -> Result<String> {
    let output = command.output().context("failed to spawn command")?;
    let mut text = String::from_utf8_lossy(&output.stdout).to_string();
    if text.trim().is_empty() {
        text = String::from_utf8_lossy(&output.stderr).to_string();
    }
    Ok(text)
}

fn xml_escape(raw: &str) -> String {
    raw.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

fn openrc_command_hint(action: &str) -> Result<String> {
    let exe = std::env::current_exe().context("failed to resolve current executable")?;
    let base_dir = lunarwing_base_dir();
    Ok(format!(
        "sudo env LUNARWING_BASE_DIR={} {} service {}",
        shell_quote(&base_dir.display().to_string()),
        shell_quote(&exe.display().to_string()),
        action,
    ))
}

fn ensure_openrc_root(action: &str) -> Result<()> {
    if is_effective_root() {
        Ok(())
    } else {
        bail!(
            "OpenRC service {} requires root. Re-run with:\n  {}",
            action,
            openrc_command_hint(action)?
        )
    }
}

fn is_effective_root() -> bool {
    match run_capture(Command::new("id").arg("-u")) {
        Ok(output) => output.trim() == "0",
        Err(_) => false,
    }
}

fn current_service_identity() -> (String, String) {
    let user = std::env::var("SUDO_USER")
        .ok()
        .or_else(|| std::env::var("USER").ok())
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "root".to_string());
    let group = current_primary_group(&user).unwrap_or_else(|| user.clone());
    (user, group)
}

fn current_primary_group(user: &str) -> Option<String> {
    run_capture(Command::new("id").args(["-gn", user]))
        .ok()
        .map(|output| output.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn shell_quote(raw: &str) -> String {
    if raw.is_empty() {
        return "''".to_string();
    }
    format!("'{}'", raw.replace('\'', "'\"'\"'"))
}

fn binary_exists(name: &str) -> bool {
    std::env::var_os("PATH")
        .into_iter()
        .flat_map(|paths| std::env::split_paths(&paths).collect::<Vec<_>>())
        .any(|dir| dir.join(name).is_file())
}

fn write_text_file(path: &Path, content: &str) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }
    std::fs::write(path, content).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

fn write_text_file_with_mode(path: &Path, content: &str, mode: u32) -> Result<()> {
    write_text_file(path, content)?;
    set_mode(path, mode)
}

fn ensure_text_file_with_mode(path: &Path, content: &str, mode: u32) -> Result<()> {
    if !path.exists() {
        write_text_file(path, content)?;
    }
    set_mode(path, mode)
}

fn set_mode(path: &Path, mode: u32) -> Result<()> {
    #[cfg(unix)]
    {
        std::fs::set_permissions(path, Permissions::from_mode(mode))
            .with_context(|| format!("failed to chmod {}", path.display()))?;
    }
    #[cfg(not(unix))]
    {
        let _ = (path, mode);
    }
    Ok(())
}

#[derive(Debug, Clone, Copy, Default)]
struct LinuxServiceProbe<'a> {
    override_value: Option<&'a str>,
    has_openrc_runtime: bool,
    has_systemd_runtime: bool,
    has_rc_service: bool,
    has_rc_update: bool,
    has_systemctl: bool,
}

fn detect_linux_service_manager_from_probe(
    probe: &LinuxServiceProbe<'_>,
) -> Result<ServiceManager> {
    if let Some(override_value) = probe.override_value {
        let normalized = override_value.trim().to_ascii_lowercase();
        return match normalized.as_str() {
            "systemd" | "systemd-user" => Ok(ServiceManager::SystemdUser),
            "openrc" => Ok(ServiceManager::OpenRc),
            other => bail!(
                "Unsupported service manager override '{}'. Use 'systemd' or 'openrc'.",
                other
            ),
        };
    }

    if probe.has_openrc_runtime {
        return Ok(ServiceManager::OpenRc);
    }
    if probe.has_systemd_runtime {
        return Ok(ServiceManager::SystemdUser);
    }
    if probe.has_rc_service && probe.has_rc_update && !probe.has_systemctl {
        return Ok(ServiceManager::OpenRc);
    }
    if probe.has_systemctl {
        return Ok(ServiceManager::SystemdUser);
    }
    if probe.has_rc_service && probe.has_rc_update {
        return Ok(ServiceManager::OpenRc);
    }

    bail!(
        "Could not detect a supported Linux service manager. \
         Set LUNARWING_SERVICE_MANAGER=systemd or LUNARWING_SERVICE_MANAGER=openrc \
         (legacy IRONCLAW_SERVICE_MANAGER is also supported)."
    )
}

// ── Tests ───────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use crate::service::*;

    #[test]
    fn xml_escape_handles_reserved_chars() {
        let escaped = xml_escape("<&>\"' and text");
        assert_eq!(escaped, "&lt;&amp;&gt;&quot;&apos; and text");
    }

    #[test]
    fn xml_escape_passes_through_plain_text() {
        assert_eq!(xml_escape("hello world"), "hello world");
    }

    #[test]
    fn run_capture_reads_stdout() {
        let out = run_capture(Command::new("sh").args(["-c", "echo hello"]))
            .expect("stdout capture should succeed");
        assert_eq!(out.trim(), "hello");
    }

    #[test]
    fn run_capture_falls_back_to_stderr() {
        let out = run_capture(Command::new("sh").args(["-c", "echo warn 1>&2"]))
            .expect("stderr capture should succeed");
        assert_eq!(out.trim(), "warn");
    }

    #[test]
    fn run_checked_errors_on_non_zero_exit() {
        let err = run_checked(Command::new("sh").args(["-c", "exit 17"]))
            .expect_err("non-zero exit should error");
        assert!(err.to_string().contains("command failed"));
    }

    #[test]
    fn run_checked_succeeds_on_zero_exit() {
        assert!(run_checked(Command::new("sh").args(["-c", "exit 0"])).is_ok());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_plist_path_has_expected_suffix() {
        let path = macos_plist_path().unwrap();
        let s = path.to_string_lossy();
        assert!(
            s.ends_with("Library/LaunchAgents/com.lunarwing.daemon.plist"),
            "unexpected path: {s}"
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_unit_path_has_expected_suffix() {
        let path = linux_unit_path().unwrap();
        let s = path.to_string_lossy();
        assert!(
            s.ends_with(".config/systemd/user/lunarwing.service"),
            "unexpected path: {s}"
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_xmpp_bridge_unit_path_has_expected_suffix() {
        let path = linux_xmpp_bridge_unit_path().unwrap();
        let s = path.to_string_lossy();
        assert!(
            s.ends_with(".config/systemd/user/xmpp-bridge.service"),
            "unexpected path: {s}"
        );
    }

    #[test]
    fn logs_dir_under_lunarwing() {
        let path = lunarwing_logs_dir();
        let s = path.to_string_lossy();
        assert!(s.ends_with(".ironclaw/logs"), "unexpected path: {s}");
    }

    #[test]
    fn macos_plist_sets_cli_enabled_false() {
        let plist = macos_plist_content("/tmp/lunarwing", "/tmp/stdout.log", "/tmp/stderr.log");
        assert!(plist.contains("<key>EnvironmentVariables</key>"));
        assert!(plist.contains("    <key>CLI_ENABLED</key>\n    <string>false</string>"));
    }

    #[test]
    fn linux_unit_content_adds_bridge_dependency_when_enabled() {
        let unit = linux_unit_content(Path::new("/tmp/lunarwing"), true);
        assert!(unit.contains("Wants=xmpp-bridge.service"));
        assert!(unit.contains("After=network.target xmpp-bridge.service"));
        assert!(unit.contains("ExecStart=\"/tmp/lunarwing\" run"));
    }

    #[test]
    fn linux_xmpp_bridge_unit_content_points_at_binary() {
        let unit = linux_xmpp_bridge_unit_content(Path::new("/tmp/xmpp-bridge"));
        assert!(unit.contains("Description=LunarWing XMPP bridge"));
        assert!(unit.contains("PartOf=lunarwing.service"));
        assert!(unit.contains("ExecStart=\"/tmp/xmpp-bridge\""));
    }

    #[test]
    fn linux_service_detection_prefers_openrc_runtime() {
        let manager = detect_linux_service_manager_from_probe(&LinuxServiceProbe {
            has_openrc_runtime: true,
            has_systemd_runtime: true,
            has_rc_service: true,
            has_rc_update: true,
            has_systemctl: true,
            ..Default::default()
        })
        .expect("OpenRC runtime marker should win");
        assert_eq!(manager, ServiceManager::OpenRc);
    }

    #[test]
    fn linux_service_detection_honors_override() {
        let manager = detect_linux_service_manager_from_probe(&LinuxServiceProbe {
            override_value: Some("systemd"),
            has_openrc_runtime: true,
            ..Default::default()
        })
        .expect("override should be honored");
        assert_eq!(manager, ServiceManager::SystemdUser);
    }

    #[test]
    fn linux_service_detection_errors_on_invalid_override() {
        let err = detect_linux_service_manager_from_probe(&LinuxServiceProbe {
            override_value: Some("launchctl"),
            ..Default::default()
        })
        .expect_err("invalid override should fail");
        assert!(
            err.to_string()
                .contains("Unsupported service manager override")
        );
    }

    #[test]
    fn openrc_confd_content_uses_base_dir_and_bridge_dependency() {
        let content = linux_openrc_confd_content(
            Path::new("/tmp/lunarwing"),
            Path::new("/srv/lunarwing"),
            Path::new("/srv/lunarwing/logs"),
            "sun",
            "sun",
            true,
        );
        assert!(content.contains("lunarwing_command='/tmp/lunarwing'"));
        assert!(content.contains("lunarwing_base_dir='/srv/lunarwing'"));
        assert!(content.contains("lunarwing_rc_need='xmpp-bridge'"));
    }
}
