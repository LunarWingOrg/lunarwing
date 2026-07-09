# Git WASM Tool Proposal (Gitoxide Version)

> **Note:** This proposal uses the pre-fork crate name `ironclaw-md-git`.
> If implemented, the crate should be renamed to `lunarwing-md-git` or
> placed under `ic/tools-src/git/` following the current naming conventions.
> The WASM tool interface should use `lunarwing:agent` (not `near:agent`).

## There are actually two versions of this tool, but I have not committed them to the repo yet.


## Cargo.toml
```toml
[package]
name = "ironclaw-md-git"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
wasm-bindgen = "0.2"
serde = { version = "1.0", features = ["derive"] }
serde-wasm-bindgen = "0.6"
anyhow = "1.0"
walkdir = "2.5"
serde_json = "1.0"
gix = { version = "0.72", default-features = false, features = ["blocking-network-client"] }
pulldown-cmark = "0.10"
```

## src/lib.rs
```rust
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_wasm_bindgen::to_value;
use std::path::Path;
use wasm_bindgen::prelude::*;
use walkdir::WalkDir;

// ============================================================================
// Data Structures
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MarkdownFile {
    pub path: String,
    pub content: String,
    pub word_count: usize,
    pub heading_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitFileInfo {
    pub path: String,
    pub status: String,
    pub is_tracked: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RepoInfo {
    pub path: String,
    pub branch: Option<String>,
    pub commit_hash: Option<String>,
    pub is_dirty: bool,
    pub tracked_files: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MarkdownStats {
    pub total_files: usize,
    pub total_words: usize,
    pub total_headings: usize,
    pub files: Vec<MarkdownFile>,
}

// ============================================================================
// Markdown Operations
// ============================================================================

/// Count words in a string
fn count_words(text: &str) -> usize {
    text.split_whitespace().count()
}

/// Count headings in markdown content
fn count_headings(content: &str) -> usize {
    content
        .lines()
        .filter(|line| line.trim_start().starts_with('#'))
        .count()
}

/// Scan a directory for markdown files
pub fn scan_markdown_files(dir_path: &str) -> Result<Vec<MarkdownFile>> {
    let mut files = Vec::new();
    
    for entry in WalkDir::new(dir_path)
        .into_iter()
        .filter_map(|e| e.ok())
    {
        let path = entry.path();
        if path.extension().map_or(false, |ext| ext == "md") {
            let content = std::fs::read_to_string(path)
                .with_context(|| format!("Failed to read {:?}", path))?;
            
            files.push(MarkdownFile {
                path: path.to_string_lossy().to_string(),
                word_count: count_words(&content),
                heading_count: count_headings(&content),
                content,
            });
        }
    }
    
    Ok(files)
}

/// Get statistics for all markdown files in a directory
pub fn get_markdown_stats(dir_path: &str) -> Result<MarkdownStats> {
    let files = scan_markdown_files(dir_path)?;
    let total_files = files.len();
    let total_words = files.iter().map(|f| f.word_count).sum();
    let total_headings = files.iter().map(|f| f.heading_count).sum();
    
    Ok(MarkdownStats {
        total_files,
        total_words,
        total_headings,
        files,
    })
}

/// Parse markdown structure (headings, code blocks, etc.)
pub fn parse_markdown_structure(content: &str) -> Result<serde_json::Value> {
    use pulldown_cmark::{Event, Parser, Tag};
    
    let mut structure = serde_json::Map::new();
    let mut headings = Vec::new();
    let mut code_blocks = Vec::new();
    
    let parser = Parser::new(content);
    
    for event in parser {
        match event {
            Event::Start(Tag::Heading(level, _, _)) => {
                headings.push(level as u32);
            }
            Event::Start(Tag::CodeBlock(info)) => {
                code_blocks.push(info.to_string());
            }
            _ => {}
        }
    }
    
    structure.insert("headings".to_string(), serde_json::to_value(headings)?);
    structure.insert("code_blocks".to_string(), serde_json::to_value(code_blocks)?);
    
    Ok(serde_json::Value::Object(structure))
}

// ============================================================================
// Git Operations (using gitoxide)
// ============================================================================

/// Get repository information
pub fn get_repo_info(repo_path: &str) -> Result<RepoInfo> {
    let repo = gix::open(repo_path)
        .with_context(|| format!("Failed to open repository at {:?}", repo_path))?;
    
    let branch = repo.head_name()
        .ok()
        .flatten()
        .map(|name| name.to_string());
    
    let commit_hash = repo.head_id()
        .ok()
        .map(|id| id.to_string());
    
    let is_dirty = repo.index().map(|index| index.is_dirty()).unwrap_or(false);
    
    let mut tracked_files = Vec::new();
    if let Ok(index) = repo.index() {
        for entry in index.entries() {
            if let Ok(path) = std::str::from_utf8(&entry.path) {
                tracked_files.push(path.to_string());
            }
        }
    }
    
    Ok(RepoInfo {
        path: repo_path.to_string(),
        branch,
        commit_hash,
        is_dirty,
        tracked_files,
    })
}

/// Get git status for a repository
pub fn get_git_status(repo_path: &str) -> Result<Vec<GitFileInfo>> {
    let repo = gix::open(repo_path)?;
    let mut status = Vec::new();
    
    // Get worktree changes
    if let Ok(worktree) = repo.worktree() {
        let options = gix::worktree::stream::Options {
            emit_untracked: gix::worktree::stream::EmitUntracked::All,
            ..Default::default()
        };
        
        let changes = worktree.changes(options)?;
        for change in changes {
            if let Ok(change) = change {
                let path = change.location.to_string();
                let is_tracked = matches!(change.status, gix::worktree::stream::change::Status::Modification { .. });
                
                status.push(GitFileInfo {
                    path,
                    status: format!("{:?}", change.status),
                    is_tracked,
                });
            }
        }
    }
    
    Ok(status)
}

// ============================================================================
// WASM Bindings
// ============================================================================

#[wasm_bindgen]
pub fn scan_markdown_files_wasm(dir_path: &str) -> Result<JsValue, JsValue> {
    let files = scan_markdown_files(dir_path)
        .map_err(|e| JsValue::from_str(&e.to_string()))?;
    
    to_value(&files).map_err(|e| JsValue::from_str(&e.to_string()))
}

#[wasm_bindgen]
pub fn get_markdown_stats_wasm(dir_path: &str) -> Result<JsValue, JsValue> {
    let stats = get_markdown_stats(dir_path)
        .map_err(|e| JsValue::from_str(&e.to_string()))?;
    
    to_value(&stats).map_err(|e| JsValue::from_str(&e.to_string()))
}

#[wasm_bindgen]
pub fn parse_markdown_structure_wasm(content: &str) -> Result<JsValue, JsValue> {
    let structure = parse_markdown_structure(content)
        .map_err(|e| JsValue::from_str(&e.to_string()))?;
    
    to_value(&structure).map_err(|e| JsValue::from_str(&e.to_string()))
}

#[wasm_bindgen]
pub fn get_repo_info_wasm(repo_path: &str) -> Result<JsValue, JsValue> {
    let info = get_repo_info(repo_path)
        .map_err(|e| JsValue::from_str(&e.to_string()))?;
    
    to_value(&info).map_err(|e| JsValue::from_str(&e.to_string()))
}

#[wasm_bindgen]
pub fn get_git_status_wasm(repo_path: &str) -> Result<JsValue, JsValue> {
    let status = get_git_status(repo_path)
        .map_err(|e| JsValue::from_str(&e.to_string()))?;
    
    to_value(&status).map_err(|e| JsValue::from_str(&e.to_string()))
}
```

## Usage

Build for WASM:
```bash
rustup target add wasm32-unknown-unknown
cargo build --target wasm32-unknown-unknown --release
```

The WASM module exports:
- `scan_markdown_files_wasm(dir_path)` - Scan directory for markdown files
- `get_markdown_stats_wasm(dir_path)` - Get statistics for markdown files
- `parse_markdown_structure_wasm(content)` - Parse markdown structure
- `get_repo_info_wasm(repo_path)` - Get git repository info
- `get_git_status_wasm(repo_path)` - Get git status

## GitLab Integration

The tool uses gitoxide (gix) for pure-Rust git operations. For GitLab authentication, use the `GITLAB_TOKEN` environment variable with HTTP Basic auth or the "Private-Token" header.
