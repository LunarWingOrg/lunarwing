//! Registry CLI commands for discovering and installing extensions.

use clap::Subcommand;

use crate::extensions::ExtensionSource;
use crate::registry::catalog::RegistryCatalog;
use crate::registry::installer::RegistryInstaller;
use crate::registry::manifest::{ExtensionManifest, ManifestKind, McpManifestTransport};
use crate::tools::mcp::McpServerConfig;

#[derive(Subcommand, Debug, Clone)]
pub enum RegistryCommand {
    /// List available extensions in the registry
    List {
        /// Filter by kind: "tool", "channel", or "mcp"
        #[arg(short, long)]
        kind: Option<String>,

        /// Filter by tag (e.g. "default", "messaging", "lunarwing")
        #[arg(short, long)]
        tag: Option<String>,

        /// Show detailed information
        #[arg(short, long)]
        verbose: bool,
    },

    /// Show detailed information about an extension or bundle
    Info {
        /// Extension or bundle name (e.g. "gotify", "lunarwing", "tools/github")
        name: String,
    },

    /// Install an extension or bundle from the registry
    Install {
        /// Extension or bundle name (e.g. "gotify", "lunarwing", "xmpp")
        name: String,

        /// Force overwrite if already installed
        #[arg(short, long)]
        force: bool,

        /// Build from source instead of downloading pre-built artifact
        #[arg(long)]
        build: bool,
    },

    /// Install the LunarWing bundle of recommended extensions
    InstallDefaults {
        /// Force overwrite if already installed
        #[arg(short, long)]
        force: bool,

        /// Build from source instead of downloading pre-built artifact
        #[arg(long)]
        build: bool,
    },
}

/// Run a registry command.
pub async fn run_registry_command(cmd: RegistryCommand) -> anyhow::Result<()> {
    // For install commands that need to build from source, a disk registry is required.
    // For list/info, embedded manifests suffice.
    let registry_dir = RegistryCatalog::find_dir();
    let catalog = if let Some(ref dir) = registry_dir {
        RegistryCatalog::load(dir)?
    } else {
        RegistryCatalog::load_or_embedded()?
    };

    // Resolve repo root for installer (empty path when running from binary)
    let repo_root = registry_dir
        .as_ref()
        .and_then(|d| d.parent().map(|p| p.to_path_buf()))
        .unwrap_or_default();

    match cmd {
        RegistryCommand::List { kind, tag, verbose } => {
            cmd_list(&catalog, kind.as_deref(), tag.as_deref(), verbose)
        }
        RegistryCommand::Info { name } => cmd_info(&catalog, &name),
        RegistryCommand::Install { name, force, build } => {
            cmd_install(&catalog, &repo_root, &name, force, build).await
        }
        RegistryCommand::InstallDefaults { force, build } => {
            cmd_install(&catalog, &repo_root, "lunarwing", force, build).await
        }
    }
}

fn cmd_list(
    catalog: &RegistryCatalog,
    kind: Option<&str>,
    tag: Option<&str>,
    verbose: bool,
) -> anyhow::Result<()> {
    let kind_filter = parse_kind_filter(kind)?;

    let manifests = catalog.list(kind_filter, tag);

    if manifests.is_empty() {
        println!("No extensions found matching the criteria.");
        return Ok(());
    }

    // Print header
    if verbose {
        println!(
            "{:<20} {:<8} {:<8} {:<10} DESCRIPTION",
            "NAME", "KIND", "VERSION", "AUTH"
        );
        println!("{}", "-".repeat(80));
    } else {
        println!("{:<20} {:<8} DESCRIPTION", "NAME", "KIND");
        println!("{}", "-".repeat(60));
    }

    for m in &manifests {
        if verbose {
            let auth = m
                .auth_summary
                .as_ref()
                .and_then(|a| a.method.as_deref())
                .or(m.auth.as_deref())
                .unwrap_or("none");
            println!(
                "{:<20} {:<8} {:<8} {:<10} {}",
                m.name,
                m.kind,
                m.version.as_deref().unwrap_or("-"),
                auth,
                m.description
            );
        } else {
            println!("{:<20} {:<8} {}", m.name, m.kind, m.description);
        }
    }

    println!("\n{} extension(s) found.", manifests.len());

    // Show bundles hint
    let bundle_names = catalog.bundle_names();
    if !bundle_names.is_empty() {
        println!("\nBundles available: {}", bundle_names.join(", "));
        println!("Use `lunarwing registry info <bundle>` for details.");
    }

    Ok(())
}

fn parse_kind_filter(kind: Option<&str>) -> anyhow::Result<Option<ManifestKind>> {
    Ok(match kind {
        Some("tool" | "tools") => Some(ManifestKind::Tool),
        Some("channel" | "channels") => Some(ManifestKind::Channel),
        Some("mcp" | "mcp_server" | "mcp_servers" | "mcp-server" | "mcp-servers") => {
            Some(ManifestKind::McpServer)
        }
        Some(other) => anyhow::bail!("Unknown kind '{}'. Use 'tool', 'channel', or 'mcp'.", other),
        None => None,
    })
}

fn cmd_info(catalog: &RegistryCatalog, name: &str) -> anyhow::Result<()> {
    // Check if it's a bundle
    if let Some(bundle) = catalog.get_bundle(name) {
        println!("Bundle: {}", bundle.display_name);
        if let Some(desc) = &bundle.description {
            println!("  {}", desc);
        }
        println!("\nExtensions:");
        for ext_key in &bundle.extensions {
            if let Some(m) = catalog.get(ext_key) {
                println!("  {} - {} ({})", ext_key, m.description, m.kind);
            } else {
                println!("  {} (not found in registry)", ext_key);
            }
        }
        if let Some(shared) = &bundle.shared_auth {
            println!("\nShared auth: {}", shared);
        }
        return Ok(());
    }

    // Single extension (use get_strict to surface ambiguous bare names)
    let manifest = catalog
        .get_strict(name)
        .map_err(|e| anyhow::anyhow!("{}", e))?;

    println!("{} ({})", manifest.display_name, manifest.kind);
    if let Some(ref version) = manifest.version {
        println!("  Version: {}", version);
    }
    println!("  {}", manifest.description);

    if !manifest.keywords.is_empty() {
        println!("  Keywords: {}", manifest.keywords.join(", "));
    }

    if let Some(ref source) = manifest.source {
        println!("\nSource:");
        println!("  Directory: {}", source.dir);
        println!("  Crate: {}", source.crate_name);
        println!("  Capabilities: {}", source.capabilities);
    }

    if let Some(ref url) = manifest.url {
        println!("\nMCP Server:");
        println!("  Transport: HTTP");
        println!("  URL: {}", url);
    }

    if let Some(McpManifestTransport::Stdio { command, args, env }) = &manifest.transport {
        println!("\nMCP Server:");
        println!("  Transport: stdio");
        println!("  Command: {}", command);
        if !args.is_empty() {
            println!("  Args: {}", args.join(" "));
        }
        if !env.is_empty() {
            let mut names: Vec<_> = env.keys().map(String::as_str).collect();
            names.sort_unstable();
            println!("  Environment: {}", names.join(", "));
        }
    }

    if let Some(artifact) = manifest.artifacts.get("wasm32-wasip2") {
        println!("\nArtifact (wasm32-wasip2):");
        match &artifact.url {
            Some(url) => println!("  URL: {}", url),
            None => println!("  URL: (not yet published)"),
        }
        match &artifact.sha256 {
            Some(sha) => println!("  SHA256: {}", sha),
            None => println!("  SHA256: (not yet computed)"),
        }
    }

    if let Some(auth) = &manifest.auth_summary {
        println!("\nAuthentication:");
        if let Some(method) = &auth.method {
            println!("  Method: {}", method);
        }
        if let Some(provider) = &auth.provider {
            println!("  Provider: {}", provider);
        }
        if !auth.secrets.is_empty() {
            println!("  Secrets: {}", auth.secrets.join(", "));
        }
        if let Some(shared) = &auth.shared_auth {
            println!("  Shared with: {}", shared);
        }
        if let Some(url) = &auth.setup_url {
            println!("  Setup: {}", url);
        }
    }

    if !manifest.tags.is_empty() {
        println!("\nTags: {}", manifest.tags.join(", "));
    }

    Ok(())
}

async fn cmd_install(
    catalog: &RegistryCatalog,
    repo_root: &std::path::Path,
    name: &str,
    force: bool,
    prefer_build: bool,
) -> anyhow::Result<()> {
    let installer = RegistryInstaller::with_defaults(repo_root.to_path_buf());

    let (manifests, bundle) = catalog.resolve(name)?;

    if manifests.is_empty() {
        anyhow::bail!("No extensions found for '{}'.", name);
    }

    if let Some(bundle_def) = bundle {
        if manifests
            .iter()
            .any(|manifest| manifest.kind == ManifestKind::McpServer)
        {
            anyhow::bail!(
                "Bundles containing MCP servers are not supported yet. Install each MCP entry individually."
            );
        }

        // Bundle install
        println!(
            "Installing bundle '{}' ({} extensions)...\n",
            bundle_def.display_name,
            manifests.len()
        );

        let (outcomes, hints) = installer
            .install_bundle(&manifests, bundle_def, force, prefer_build)
            .await;

        println!("\n--- Results ---");
        for outcome in &outcomes {
            let caps_status = if outcome.has_capabilities { "+" } else { "-" };
            println!(
                "  [{}] {} ({}) -> {}",
                caps_status,
                outcome.name,
                outcome.kind,
                outcome.wasm_path.display()
            );
            for w in &outcome.warnings {
                println!("      Warning: {}", w);
            }
        }

        if !hints.is_empty() {
            println!("\nAuth setup:");
            for hint in &hints {
                println!("{}", hint);
            }
        }

        println!(
            "\nInstalled {}/{} extensions.",
            outcomes.len(),
            manifests.len()
        );
    } else {
        // Single extension
        let manifest = manifests[0];
        if manifest.kind == ManifestKind::McpServer {
            let config = mcp_config_from_manifest(manifest)?;
            crate::cli::mcp::persist_server(config, force).await?;

            println!("\nInstalled successfully:");
            println!("  Name: {}", manifest.name);
            println!("  Kind: {}", manifest.kind);
            match (&manifest.url, &manifest.transport) {
                (Some(_), None) => println!("  Transport: HTTP"),
                (None, Some(McpManifestTransport::Stdio { command, args, .. })) => {
                    println!("  Transport: stdio");
                    println!("  Command: {}", command);
                    if !args.is_empty() {
                        println!("  Args: {}", args.join(" "));
                    }
                }
                _ => unreachable!("validated registry MCP transport"),
            }
            println!(
                "\nNext step: restart LunarWing, or activate '{}' through the web UI or conversation, to connect and load its tools.",
                manifest.name
            );
            return Ok(());
        }

        let outcome = installer.install(manifest, force, prefer_build).await?;

        println!("\nInstalled successfully:");
        println!("  Name: {}", outcome.name);
        println!("  Kind: {}", outcome.kind);
        println!("  WASM: {}", outcome.wasm_path.display());
        println!("  Capabilities: {}", outcome.has_capabilities);

        if let Some(auth) = &manifest.auth_summary
            && auth.method.as_deref() != Some("none")
        {
            println!(
                "\nNext step: authenticate with `lunarwing tool auth {}`",
                manifest.name
            );
            if let Some(url) = &auth.setup_url {
                println!("  Setup credentials at: {}", url);
            }
        }
    }

    Ok(())
}

fn mcp_config_from_manifest(manifest: &ExtensionManifest) -> anyhow::Result<McpServerConfig> {
    if manifest.kind != ManifestKind::McpServer {
        anyhow::bail!("Registry entry '{}' is not an MCP server", manifest.name);
    }

    let entry = manifest.to_registry_entry().ok_or_else(|| {
        anyhow::anyhow!(
            "MCP registry entry '{}' must declare exactly one supported transport",
            manifest.name
        )
    })?;
    let mut config = match entry.source {
        ExtensionSource::McpUrl { url } => McpServerConfig::new(&manifest.name, url),
        ExtensionSource::McpStdio { command, args, env } => {
            McpServerConfig::new_stdio(&manifest.name, command, args, env)
        }
        _ => anyhow::bail!("Registry entry '{}' has no MCP transport", manifest.name),
    };
    config.description = Some(manifest.description.clone());
    config.validate()?;
    Ok(config)
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::*;
    use crate::registry::manifest::McpManifestTransport;
    use crate::tools::mcp::config::EffectiveTransport;

    fn stdio_manifest() -> ExtensionManifest {
        ExtensionManifest {
            name: "local-files".to_string(),
            display_name: "Local Files".to_string(),
            kind: ManifestKind::McpServer,
            version: None,
            description: "Read files from an approved local directory".to_string(),
            keywords: Vec::new(),
            source: None,
            artifacts: HashMap::new(),
            auth_summary: None,
            tags: Vec::new(),
            hidden: None,
            url: None,
            transport: Some(McpManifestTransport::Stdio {
                command: "npx".to_string(),
                args: vec![
                    "-y".to_string(),
                    "@modelcontextprotocol/server-filesystem".to_string(),
                    "/srv/data".to_string(),
                ],
                env: HashMap::from([("LOG_LEVEL".to_string(), "warn".to_string())]),
            }),
            auth: Some("none".to_string()),
        }
    }

    #[test]
    fn test_parse_mcp_kind_filter() {
        assert_eq!(
            parse_kind_filter(Some("mcp")).expect("valid filter"),
            Some(ManifestKind::McpServer)
        );
        assert_eq!(
            parse_kind_filter(Some("mcp_server")).expect("valid filter"),
            Some(ManifestKind::McpServer)
        );
    }

    #[test]
    fn test_stdio_manifest_builds_mcp_config() {
        let config = mcp_config_from_manifest(&stdio_manifest()).expect("valid config");
        assert_eq!(
            config.description.as_deref(),
            Some("Read files from an approved local directory")
        );
        match config.effective_transport() {
            EffectiveTransport::Stdio { command, args, env } => {
                assert_eq!(command, "npx");
                assert_eq!(args.last().map(String::as_str), Some("/srv/data"));
                assert_eq!(env.get("LOG_LEVEL").map(String::as_str), Some("warn"));
            }
            other => panic!("expected stdio transport, got {other:?}"),
        }
    }
}
