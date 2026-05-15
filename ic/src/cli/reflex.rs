//! `lunarwing reflex` — manage compiled reflex patterns from the CLI.
//!
//! Provides subcommands for listing, deleting, and checking the status of
//! reflex patterns without starting the full agent.

use std::sync::Arc;

use clap::Subcommand;
use uuid::Uuid;

use crate::db::Database;

/// Reflex subcommands.
#[derive(Subcommand, Debug, Clone)]
pub enum ReflexCommand {
    /// List reflex patterns
    List {
        /// Include disabled patterns
        #[arg(long)]
        disabled: bool,

        /// Output as JSON (for scripting)
        #[arg(long)]
        json: bool,
    },

    /// Show details for a specific reflex pattern
    Show {
        /// Pattern ID (UUID)
        id: String,
    },

    /// Delete a reflex pattern
    #[command(alias = "rm")]
    Delete {
        /// Pattern ID (UUID)
        id: String,

        /// Skip confirmation prompt
        #[arg(short, long)]
        yes: bool,
    },

    /// Show reflex compiler status
    Status,
}

/// Run a reflex CLI command against the database.
pub async fn run_reflex_command(
    cmd: ReflexCommand,
    db: Arc<dyn Database>,
    user_id: &str,
) -> anyhow::Result<()> {
    match cmd {
        ReflexCommand::List { disabled, json } => list(&db, user_id, disabled, json).await,
        ReflexCommand::Show { id } => show(&db, user_id, &id).await,
        ReflexCommand::Delete { id, yes } => delete(&db, user_id, &id, yes).await,
        ReflexCommand::Status => status(&db, user_id).await,
    }
}

// ── List ────────────────────────────────────────────────────

async fn list(
    db: &Arc<dyn Database>,
    user_id: &str,
    show_disabled: bool,
    json: bool,
) -> anyhow::Result<()> {
    let patterns = db.list_reflex_patterns(user_id).await?;

    let filtered: Vec<_> = patterns
        .into_iter()
        .filter(|p| show_disabled || p.status == "active")
        .collect();

    if json {
        let items: Vec<serde_json::Value> = filtered
            .iter()
            .map(|p| {
                serde_json::json!({
                    "id": p.id.to_string(),
                    "normalized_pattern": p.normalized_pattern,
                    "original_pattern": p.original_pattern,
                    "tool_name": p.tool_name,
                    "match_count": p.match_count,
                    "status": p.status,
                    "compilation_attempts": p.compilation_attempts,
                    "last_matched_at": p.last_matched_at,
                    "created_at": p.created_at,
                })
            })
            .collect();
        println!("{}", serde_json::to_string_pretty(&items)?);
        return Ok(());
    }

    if filtered.is_empty() {
        println!("No reflex patterns found.");
        return Ok(());
    }

    // Header
    println!(
        "{:<36}  {:<30}  {:<20}  {:<8}  {:>6}  {:<22}",
        "ID", "Pattern", "Tool", "Status", "Matches", "Last Matched"
    );
    println!("{}", "-".repeat(130));

    for p in filtered {
        let last_matched = p
            .last_matched_at
            .map(|dt| dt.format("%Y-%m-%d %H:%M:%S").to_string())
            .unwrap_or_else(|| "Never".to_string());
        let pattern_preview = if p.normalized_pattern.len() > 28 {
            format!("{}...", &p.normalized_pattern[..25])
        } else {
            p.normalized_pattern.clone()
        };
        let tool_preview = if p.tool_name.len() > 18 {
            format!("{}...", &p.tool_name[..15])
        } else {
            p.tool_name.clone()
        };
        println!(
            "{:<36}  {:<30}  {:<20}  {:<8}  {:>6}  {:<22}",
            p.id,
            pattern_preview,
            tool_preview,
            p.status,
            p.match_count,
            last_matched,
        );
    }

    Ok(())
}

// ── Show ────────────────────────────────────────────────────

async fn show(db: &Arc<dyn Database>, user_id: &str, id: &str) -> anyhow::Result<()> {
    let patterns = db.list_reflex_patterns(user_id).await?;

    let pattern = patterns
        .into_iter()
        .find(|p| p.id.to_string() == id)
        .ok_or_else(|| anyhow::anyhow!("Reflex pattern '{}' not found", id))?;

    println!("Reflex Pattern Details");
    println!("======================");
    println!("ID:                  {}", pattern.id);
    println!("Normalized Pattern:  {}", pattern.normalized_pattern);
    println!("Original Pattern:    {}", pattern.original_pattern);
    println!("Tool Name:           {}", pattern.tool_name);
    println!("Match Count:         {}", pattern.match_count);
    println!("Status:              {}", pattern.status);
    println!("Compilation Attempts: {}", pattern.compilation_attempts);
    println!(
        "Last Matched:        {}",
        pattern
            .last_matched_at
            .map(|dt| dt.to_rfc3339())
            .unwrap_or_else(|| "Never".to_string())
    );
    println!(
        "Created:             {}",
        pattern.created_at.to_rfc3339()
    );
    println!(
        "Updated:             {}",
        pattern.updated_at.to_rfc3339()
    );

    Ok(())
}

// ── Delete ──────────────────────────────────────────────────

async fn delete(
    db: &Arc<dyn Database>,
    user_id: &str,
    id: &str,
    yes: bool,
) -> anyhow::Result<()> {
    let uuid = Uuid::parse_str(id)
        .map_err(|_| anyhow::anyhow!("Invalid UUID: '{}'", id))?;

    // Verify the pattern exists and belongs to this user
    let patterns = db.list_reflex_patterns(user_id).await?;
    let pattern = patterns
        .into_iter()
        .find(|p| p.id == uuid)
        .ok_or_else(|| anyhow::anyhow!("Reflex pattern '{}' not found", id))?;

    if !yes {
        println!(
            "Are you sure you want to delete reflex pattern '{}' ({})? [y/N]",
            pattern.normalized_pattern, id
        );
        let mut input = String::new();
        std::io::stdin().read_line(&mut input)?;
        if !input.trim().eq_ignore_ascii_case("y") {
            println!("Cancelled.");
            return Ok(());
        }
    }

    db.disable_reflex_pattern(uuid).await?;
    println!("Deleted reflex pattern '{}' ({})", pattern.normalized_pattern, id);

    Ok(())
}

// ── Status ──────────────────────────────────────────────────

async fn status(db: &Arc<dyn Database>, user_id: &str) -> anyhow::Result<()> {
    let patterns = db.list_reflex_patterns(user_id).await?;

    let active_count = patterns.iter().filter(|p| p.status == "active").count();
    let disabled_count = patterns.iter().filter(|p| p.status == "disabled").count();
    let total_matches: i32 = patterns.iter().map(|p| p.match_count).sum();

    println!("Reflex Compiler Status");
    println!("======================");
    println!("Active Patterns:   {}", active_count);
    println!("Disabled Patterns: {}", disabled_count);
    println!("Total Patterns:    {}", patterns.len());
    println!("Total Matches:     {}", total_matches);

    if !patterns.is_empty() {
        let top_pattern = patterns
            .iter()
            .max_by_key(|p| p.match_count)
            .unwrap();
        println!(
            "Top Pattern:       '{}' ({} matches)",
            top_pattern.normalized_pattern, top_pattern.match_count
        );
    }

    Ok(())
}
