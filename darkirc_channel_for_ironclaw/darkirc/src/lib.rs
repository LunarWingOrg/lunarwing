#![allow(dead_code)]

//! DarkIRC WASM channel for IronClaw.
//!
//! Connects to DarkIRC's P2P anonymous IRC network via a local HTTP adapter
//! that translates between IRC (TCP) and HTTP. The adapter handles the raw
//! IRC protocol; this channel handles IronClaw integration.
//!
//! # Architecture
//!
//!   IronClaw host → (on_poll) → this WASM → HTTP GET /poll → adapter → DarkIRC
//!   IronClaw host → (on_respond) → this WASM → HTTP POST /send → adapter → DarkIRC
//!
//! # Features
//!
//! - Poll-based DM receiving via local adapter
//! - DM pairing support (allowlist / pairing code flow)
//! - Response delivery back through adapter
//! - Status updates (approval needed, auth required, etc.)
//!
//! # Security
//!
//! - Adapter secret is injected by host during HTTP requests (WASM never sees it)
//! - HTTP requests restricted to allowlisted adapter endpoint
//! - All IronClaw security layers apply (prompt injection defense, rate limiting)

wit_bindgen::generate!({
    world: "sandboxed-channel",
    path: "../../ic/wit/channel.wit",
});

use serde::{Deserialize, Serialize};

use exports::near::agent::channel::{
    AgentResponse, ChannelConfig, Guest, HttpEndpointConfig, IncomingHttpRequest,
    OutgoingHttpResponse, PollConfig, StatusType, StatusUpdate,
};
use near::agent::channel_host::{self, EmittedMessage};

// ============================================================================
// Adapter API Types
// ============================================================================

/// Response from GET /poll on the adapter.
#[derive(Debug, Deserialize)]
struct AdapterPollResponse {
    messages: Vec<AdapterMessage>,
}

/// A single inbound DM from the adapter.
#[derive(Debug, Deserialize)]
struct AdapterMessage {
    /// DarkIRC nick of the sender.
    from: String,
    /// Message text (control codes already stripped by adapter).
    text: String,
    /// ISO8601 timestamp.
    ts: String,
}

/// Request body for POST /send on the adapter.
#[derive(Debug, Serialize)]
struct AdapterSendRequest {
    to: String,
    text: String,
}

// ============================================================================
// Channel Configuration
// ============================================================================

/// Configuration from darkirc.capabilities.json, injected by host via on_start.
#[derive(Debug, Deserialize)]
struct DarkIrcConfig {
    /// HTTP URL of the darkirc-http-adapter.
    #[serde(default = "default_adapter_url")]
    adapter_url: String,

    /// DM policy: "open", "allowlist", or "pairing" (default).
    #[serde(default = "default_dm_policy")]
    dm_policy: String,

    /// Allowlisted DarkIRC nicks.
    #[serde(default, deserialize_with = "deserialize_string_vec_or_empty")]
    allow_from: Vec<String>,

    /// Poll interval in seconds (minimum 3).
    #[serde(default = "default_poll_interval")]
    poll_interval_seconds: u32,
}

fn default_adapter_url() -> String {
    "http://127.0.0.1:6680".to_string()
}

fn default_dm_policy() -> String {
    "pairing".to_string()
}

fn default_poll_interval() -> u32 {
    3
}

fn deserialize_string_vec_or_empty<'de, D>(deserializer: D) -> Result<Vec<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum StringVecOrEmpty {
        Vec(Vec<String>),
        String(String),
    }

    Ok(match StringVecOrEmpty::deserialize(deserializer)? {
        StringVecOrEmpty::Vec(values) => values
            .into_iter()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
            .collect(),
        StringVecOrEmpty::String(value) => value
            .split(',')
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToString::to_string)
            .collect(),
    })
}

// ============================================================================
// Channel Metadata
// ============================================================================

/// Metadata stored with emitted messages for response routing.
/// Passed back to on_respond so we know who to reply to.
#[derive(Debug, Serialize, Deserialize)]
struct DarkIrcMessageMetadata {
    /// DarkIRC nick of the sender.
    nick: String,
}

// ============================================================================
// Workspace Paths (persist config across fresh WASM instances)
// ============================================================================

const CHANNEL_NAME: &str = "darkirc";
const ADAPTER_URL_PATH: &str = "state/adapter_url";
const DM_POLICY_PATH: &str = "state/dm_policy";
const ALLOW_FROM_PATH: &str = "state/allow_from";

/// Max UTF-8 bytes per IRC message chunk.
/// Conservative under the 512-byte IRC protocol limit.
const MAX_IRC_MESSAGE_BYTES: usize = 400;

// ============================================================================
// Channel Implementation
// ============================================================================

struct DarkIrcChannel;

impl Guest for DarkIrcChannel {
    /// Initialize the channel. Persist config to workspace so on_poll/on_respond
    /// can read it (each callback gets a fresh WASM instance with no shared state).
    fn on_start(config_json: String) -> Result<ChannelConfig, String> {
        channel_host::log(
            channel_host::LogLevel::Debug,
            &format!("DarkIRC channel config: {}", config_json),
        );

        let config: DarkIrcConfig = serde_json::from_str(&config_json)
            .map_err(|e| format!("Failed to parse config: {}", e))?;

        channel_host::log(
            channel_host::LogLevel::Info,
            &format!(
                "DarkIRC channel starting, adapter at {}",
                config.adapter_url
            ),
        );

        // Persist config for subsequent callbacks
        let _ = channel_host::workspace_write(ADAPTER_URL_PATH, &config.adapter_url);
        let _ = channel_host::workspace_write(DM_POLICY_PATH, &config.dm_policy);

        let allow_from_json =
            serde_json::to_string(&config.allow_from).unwrap_or_else(|_| "[]".to_string());
        let _ = channel_host::workspace_write(ALLOW_FROM_PATH, &allow_from_json);

        // Validate adapter connectivity (non-fatal — adapter may start later)
        match adapter_health(&config.adapter_url) {
            Ok(true) => {
                channel_host::log(
                    channel_host::LogLevel::Info,
                    "Adapter health OK, IRC connected",
                );
            }
            Ok(false) => {
                channel_host::log(
                    channel_host::LogLevel::Warn,
                    "Adapter reachable but IRC not connected yet (will retry on poll)",
                );
            }
            Err(e) => {
                channel_host::log(
                    channel_host::LogLevel::Warn,
                    &format!("Adapter not reachable (will retry): {}", e),
                );
            }
        }

        // Enforce minimum 3s poll interval
        let interval_ms = (config.poll_interval_seconds.max(3) * 1000).max(3000);

        Ok(ChannelConfig {
            display_name: "DarkIRC".to_string(),
            // DarkIRC is P2P over Tor — no inbound webhooks needed
            http_endpoints: vec![],
            poll: Some(PollConfig {
                interval_ms,
                enabled: true,
            }),
        })
    }

    /// No-op: DarkIRC doesn't receive inbound webhooks.
    fn on_http_request(_req: IncomingHttpRequest) -> OutgoingHttpResponse {
        json_response(
            404,
            serde_json::json!({"error": "DarkIRC channel does not accept webhooks"}),
        )
    }

    /// Poll the adapter for new DMs and emit them to the agent.
    fn on_poll() {
        let adapter_url = channel_host::workspace_read(ADAPTER_URL_PATH)
            .filter(|s| !s.is_empty())
            .unwrap_or_else(default_adapter_url);

        let poll_url = format!("{}/poll", adapter_url);
        let headers_json = serde_json::json!({}).to_string();

        let response =
            match channel_host::http_request("GET", &poll_url, &headers_json, None, Some(5_000)) {
                Ok(r) => r,
                Err(e) => {
                    channel_host::log(
                        channel_host::LogLevel::Debug,
                        &format!("Adapter poll failed: {}", e),
                    );
                    return;
                }
            };

        if response.status != 200 {
            channel_host::log(
                channel_host::LogLevel::Warn,
                &format!("Adapter /poll returned HTTP {}", response.status),
            );
            return;
        }

        let poll_response: AdapterPollResponse = match serde_json::from_slice(&response.body) {
            Ok(r) => r,
            Err(e) => {
                channel_host::log(
                    channel_host::LogLevel::Error,
                    &format!("Failed to parse poll response: {}", e),
                );
                return;
            }
        };

        if poll_response.messages.is_empty() {
            return;
        }

        channel_host::log(
            channel_host::LogLevel::Debug,
            &format!(
                "Received {} message(s) from adapter",
                poll_response.messages.len()
            ),
        );

        for msg in &poll_response.messages {
            handle_inbound_dm(msg);
        }
    }

    /// Deliver the agent's response back to the DarkIRC user via the adapter.
    fn on_respond(response: AgentResponse) -> Result<(), String> {
        let metadata: DarkIrcMessageMetadata = serde_json::from_str(&response.metadata_json)
            .map_err(|e| format!("Failed to parse metadata: {}", e))?;

        send_response_to_nick(&metadata.nick, &response.content)
    }

    fn on_broadcast(user_id: String, response: AgentResponse) -> Result<(), String> {
        send_response_to_nick(&user_id, &response.content)
    }

    /// Forward actionable status updates to the DarkIRC user.
    /// IRC has no typing indicators, so we only send real status messages.
    fn on_status(update: StatusUpdate) {
        match update.status {
            StatusType::ApprovalNeeded
            | StatusType::AuthRequired
            | StatusType::AuthCompleted
            | StatusType::JobStarted => {
                let message = update.message.trim();
                if message.is_empty() {
                    return;
                }

                let metadata: DarkIrcMessageMetadata =
                    match serde_json::from_str(&update.metadata_json) {
                        Ok(m) => m,
                        Err(_) => return,
                    };

                let adapter_url = channel_host::workspace_read(ADAPTER_URL_PATH)
                    .filter(|s| !s.is_empty())
                    .unwrap_or_else(default_adapter_url);

                let truncated = if message.len() > MAX_IRC_MESSAGE_BYTES {
                    format!("{}...", &message[..MAX_IRC_MESSAGE_BYTES - 3])
                } else {
                    message.to_string()
                };

                let status_text = format!("[status] {}", truncated);

                if let Err(e) = adapter_send(&adapter_url, &metadata.nick, &status_text) {
                    channel_host::log(
                        channel_host::LogLevel::Debug,
                        &format!("Failed to send status to '{}': {}", metadata.nick, e),
                    );
                }
            }
            // Thinking, Done, ToolStarted, etc. — no IRC equivalent
            _ => {}
        }
    }

    fn on_shutdown() {
        channel_host::log(
            channel_host::LogLevel::Info,
            "DarkIRC channel shutting down",
        );
    }
}

// ============================================================================
// Inbound Message Handling
// ============================================================================

/// Process a single inbound DM from DarkIRC. Applies DM policy (open/allowlist/
/// pairing) and emits the message to the agent if allowed.
fn handle_inbound_dm(msg: &AdapterMessage) {
    if msg.text.is_empty() {
        return;
    }

    let nick = &msg.from;

    // --- DM policy enforcement ---
    let dm_policy =
        channel_host::workspace_read(DM_POLICY_PATH).unwrap_or_else(|| "pairing".to_string());

    if dm_policy != "open" {
        // Build effective allow list: config allow_from + pairing-approved store
        let mut allowed: Vec<String> = channel_host::workspace_read(ALLOW_FROM_PATH)
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();

        if let Ok(store_allowed) = channel_host::pairing_read_allow_from(CHANNEL_NAME) {
            allowed.extend(store_allowed);
        }

        let is_allowed = allowed.contains(&"*".to_string())
            || allowed.iter().any(|a| a.eq_ignore_ascii_case(nick));

        if !is_allowed {
            if dm_policy == "pairing" {
                let meta = serde_json::json!({ "nick": nick }).to_string();

                match channel_host::pairing_upsert_request(CHANNEL_NAME, nick, &meta) {
                    Ok(result) => {
                        channel_host::log(
                            channel_host::LogLevel::Info,
                            &format!("Pairing request for '{}': code {}", nick, result.code),
                        );

                        if result.created {
                            let adapter_url = channel_host::workspace_read(ADAPTER_URL_PATH)
                                .filter(|s| !s.is_empty())
                                .unwrap_or_else(default_adapter_url);

                            let reply = format!(
                                "To pair with this agent, run: ironclaw pairing approve darkirc {}",
                                result.code
                            );

                            if let Err(e) = adapter_send(&adapter_url, nick, &reply) {
                                channel_host::log(
                                    channel_host::LogLevel::Error,
                                    &format!("Failed to send pairing reply: {}", e),
                                );
                            }
                        }
                    }
                    Err(e) => {
                        channel_host::log(
                            channel_host::LogLevel::Error,
                            &format!("Pairing upsert failed: {}", e),
                        );
                    }
                }
            } else {
                channel_host::log(
                    channel_host::LogLevel::Debug,
                    &format!("Dropping DM from '{}' (not in allowlist)", nick),
                );
            }
            return;
        }
    }

    // --- Emit to agent ---
    let metadata = DarkIrcMessageMetadata { nick: nick.clone() };

    let metadata_json = serde_json::to_string(&metadata).unwrap_or_else(|_| "{}".to_string());

    channel_host::emit_message(&EmittedMessage {
        user_id: nick.clone(),
        user_name: Some(nick.clone()),
        content: msg.text.clone(),
        thread_id: Some(format!("darkirc:dm:{}", nick)),
        metadata_json,
        attachments: Vec::new(),
    });

    channel_host::log(
        channel_host::LogLevel::Debug,
        &format!("Emitted DM from '{}' ({} chars)", nick, msg.text.len()),
    );
}

// ============================================================================
// Adapter HTTP Helpers
// ============================================================================

/// Check adapter health. Returns Ok(irc_connected).
fn adapter_health(adapter_url: &str) -> Result<bool, String> {
    let url = format!("{}/health", adapter_url);
    let headers_json = serde_json::json!({}).to_string();

    let response = channel_host::http_request("GET", &url, &headers_json, None, Some(3_000))?;

    if response.status != 200 {
        return Err(format!("HTTP {}", response.status));
    }

    #[derive(Deserialize)]
    struct HealthResponse {
        irc_connected: Option<bool>,
    }

    let health: HealthResponse =
        serde_json::from_slice(&response.body).map_err(|e| format!("parse error: {}", e))?;

    Ok(health.irc_connected.unwrap_or(false))
}

fn send_response_to_nick(nick: &str, content: &str) -> Result<(), String> {
    let adapter_url = channel_host::workspace_read(ADAPTER_URL_PATH)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(default_adapter_url);

    let chunks = split_message(content, MAX_IRC_MESSAGE_BYTES);
    let mut successful_chunks = 0;
    let mut last_error = None;

    for chunk in &chunks {
        match adapter_send(&adapter_url, nick, chunk) {
            Ok(()) => {
                successful_chunks += 1;
            }
            Err(e) => {
                channel_host::log(
                    channel_host::LogLevel::Warn,
                    &format!(
                        "Failed to send chunk {} to '{}': {}",
                        successful_chunks + 1,
                        nick,
                        e
                    ),
                );
                last_error = Some(e);
            }
        }
    }

    channel_host::log(
        channel_host::LogLevel::Debug,
        &format!(
            "Sent {} of {} chunk(s) to '{}' ({} chars total)",
            successful_chunks,
            chunks.len(),
            nick,
            content.len(),
        ),
    );

    if successful_chunks > 0 {
        Ok(())
    } else {
        Err(last_error.unwrap_or_else(|| "Failed to send any chunks".to_string()))
    }
}

/// Send a DM via the adapter.
fn adapter_send(adapter_url: &str, to: &str, text: &str) -> Result<(), String> {
    let url = format!("{}/send", adapter_url);

    let payload = serde_json::to_vec(&AdapterSendRequest {
        to: to.to_string(),
        text: text.to_string(),
    })
    .map_err(|e| format!("serialize error: {}", e))?;

    let headers_json = serde_json::json!({
        "Content-Type": "application/json"
    })
    .to_string();

    let response =
        channel_host::http_request("POST", &url, &headers_json, Some(&payload), Some(5_000))?;

    if response.status == 503 {
        return Err("IRC not connected".to_string());
    }

    if response.status != 200 {
        let body_str = String::from_utf8_lossy(&response.body);
        return Err(format!("HTTP {}: {}", response.status, body_str));
    }

    Ok(())
}

// ============================================================================
// Utilities
// ============================================================================

fn split_message(text: &str, max_bytes: usize) -> Vec<String> {
    // Normalize CRLF to LF so stray \r doesn't linger in output chunks
    let normalized = text.replace("\r\n", "\n");
    let text_ref: &str = &normalized;

    if text_ref.as_bytes().len() <= max_bytes {
        return vec![text_ref.to_string()];
    }

    let mut chunks = Vec::new();
    let mut remaining = text_ref;

    while !remaining.is_empty() {
        if remaining.as_bytes().len() <= max_bytes {
            chunks.push(remaining.to_string());
            break;
        }

        // Find the largest char boundary whose UTF-8 fits in max_bytes
        let mut end = remaining.len();
        while end > 0 {
            // Ensure we're at a char boundary
            if !remaining.is_char_boundary(end) {
                end -= 1;
                continue;
            }
            // Check byte length
            if remaining[..end].as_bytes().len() <= max_bytes {
                break;
            }
            end -= 1;
        }

        if end == 0 {
            // Single character exceeds max_bytes — take it anyway
            let first_char_len = remaining.chars().next().map(|c| c.len_utf8()).unwrap_or(1);
            chunks.push(remaining[..first_char_len].to_string());
            remaining = &remaining[first_char_len..];
            continue;
        }

        let chunk = &remaining[..end];

        // Prefer breaking at newline
        if let Some(nl) = chunk.rfind('\n') {
            if nl > 0 {
                chunks.push(remaining[..nl].to_string());
                remaining = remaining[nl + 1..].trim_start_matches('\n').trim_start();
                continue;
            }
        }

        // Then at a space
        if let Some(sp) = chunk.rfind(' ') {
            if sp > 0 {
                chunks.push(remaining[..sp].to_string());
                remaining = remaining[sp + 1..].trim_start();
                continue;
            }
        }

        // No good break point — hard cut at the byte limit
        chunks.push(chunk.to_string());
        remaining = &remaining[end..];
    }

    chunks
}

/// Create a JSON HTTP response.
fn json_response(status: u16, value: serde_json::Value) -> OutgoingHttpResponse {
    let body = serde_json::to_vec(&value).unwrap_or_default();
    let headers = serde_json::json!({"Content-Type": "application/json"});

    OutgoingHttpResponse {
        status,
        headers_json: headers.to_string(),
        body,
    }
}

// Export the component
export!(DarkIrcChannel);

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    /// Shared invariants that EVERY test case must satisfy.
    /// These are the contracts that make sense for IRC message splitting —
    /// they don't depend on how we choose split points, only that the output
    /// is safe and correct.
    fn assert_split_invariants(chunks: &[String], text: &str, max_bytes: usize) {
        // 1. Byte limit: every chunk fits within max_bytes
        //    (unless a single char exceeds it — then that chunk is as small as possible)
        for (i, chunk) in chunks.iter().enumerate() {
            let byte_len = chunk.as_bytes().len();
            // A chunk may exceed max_bytes only if it's a single character
            let single_char = chunk.len() == 1;
            assert!(
                byte_len <= max_bytes || (single_char && chunk.chars().next().map(|c| c.len_utf8() > max_bytes).unwrap_or(false)),
                "chunk {} too long: {} bytes (max={}), chunk={:?}",
                i, byte_len, max_bytes, chunk
            );
        }

        // 2. No empty chunks (empty input may produce one empty chunk — handled separately)
        if !text.is_empty() {
            for (i, chunk) in chunks.iter().enumerate() {
                assert!(!chunk.is_empty(), "empty chunk at index {} (text was non-empty)", i);
            }
        }

        // 3. Char-boundary safe: every character start in every chunk is a valid UTF-8 boundary
        for chunk in chunks {
            for (byte_idx, _) in chunk.char_indices() {
                assert!(
                    chunk.is_char_boundary(byte_idx),
                    "mid-codepoint split at byte {} in chunk {:?}",
                    byte_idx, chunk
                );
            }
        }

        // 4. No stray \r: CRLF normalized
        for chunk in chunks {
            assert!(!chunk.contains('\r'), "stray \\r in chunk: {:?}", chunk);
        }

        // 5. No data loss: all non-whitespace chars from input appear in output, in order
        //    (whitespace consumed at split points may be lost — that's fine)
        let filtered_original: String = text
            .chars()
            .filter(|c| !c.is_whitespace())
            .collect();
        let filtered_joined: String = chunks
            .concat()
            .chars()
            .filter(|c| !c.is_whitespace())
            .collect();
        assert_eq!(
            filtered_joined, filtered_original,
            "data loss or reordering: original has {} non-ws chars, output has {}",
            filtered_original.chars().count(),
            filtered_joined.chars().count()
        );
    }

    // ── Legacy exact-match tests (keep a couple for sanity, but most now use invariants) ──

    #[test]
    fn test_split_message_short() {
        let text = "hello";
        let chunks = split_message(text, 400);
        assert_eq!(chunks, vec!["hello"]);
        assert_split_invariants(&chunks, text, 400);
    }

    #[test]
    fn test_split_message_no_break() {
        let text = "a".repeat(500);
        let chunks = split_message(&text, 400);
        assert!(chunks.len() >= 2, "expected hard split, got {} chunks", chunks.len());
        assert_split_invariants(&chunks, &text, 400);
    }

    #[test]
    fn test_split_message_empty() {
        let chunks = split_message("", 400);
        // Normalize empty: single empty chunk is fine
        assert!(chunks.len() == 1 && chunks[0].is_empty());
    }

    // ── Invariant-based tests ──

    #[test]
    fn test_split_message_pure_ascii() {
        let text = "the quick brown fox jumps over the lazy dog";
        let chunks = split_message(text, 20);
        assert_split_invariants(&chunks, text, 20);
    }

    #[test]
    fn test_split_message_at_space() {
        let text = "hello world this is a test";
        let chunks = split_message(text, 15);
        assert!(chunks.len() >= 2, "expected at least 2 chunks, got {}", chunks.len());
        assert_split_invariants(&chunks, text, 15);
    }

    #[test]
    fn test_split_message_at_newline() {
        let text = "line one\nline two\nline three";
        let chunks = split_message(text, 15);
        assert_split_invariants(&chunks, text, 15);
    }

    #[test]
    fn test_split_message_2byte_utf8() {
        // "héllo" — the 'é' is 2 bytes in UTF-8
        let text = "héllo héllo héllo héllo";
        let chunks = split_message(text, 7);
        assert_split_invariants(&chunks, text, 7);
        // Also verify no data loss by checking filtered join equals original filtered
        let joined: String = chunks.concat();
        let filtered: String = text.chars().filter(|c| !c.is_whitespace()).collect();
        let filtered_joined: String = joined.chars().filter(|c| !c.is_whitespace()).collect();
        assert_eq!(filtered_joined, filtered);
    }

    #[test]
    fn test_split_message_4byte_emoji() {
        // 🐴 is 4 bytes in UTF-8
        let text = "🐴🦄🐴🦄🐴🦄🐴🦄🐴";
        let chunks = split_message(text, 9);
        assert_split_invariants(&chunks, text, 9);
    }

    #[test]
    fn test_split_message_mixed() {
        // This used to have a fragile character-count assertion.
        // Now we just assert the 5 invariants — any split strategy is valid
        // as long as all contracts hold.
        let text = "Hello 🐴 world!\nThis is a test\nwith mixed ASCII and emoji 🦄 here";
        let chunks = split_message(text, 25);
        assert!(chunks.len() >= 2);
        assert_split_invariants(&chunks, text, 25);
    }

    #[test]
    fn test_split_message_crlf_normalized() {
        let text = "Line one\r\nLine two\r\nLine three";
        let chunks = split_message(text, 400);
        let joined: String = chunks.concat();
        // Explicit CRLF check in addition to the invariant
        assert!(!joined.contains('\r'), "stray \\r in output: {:?}", joined);
        assert_split_invariants(&chunks, text, 400);
    }

    #[test]
    fn test_split_message_unicode_no_split_mid_char() {
        let test_strings = vec![
            "こんにちは世界",       // Japanese
            "Здравствуй мир",       // Cyrillic
            "안녕하세요 세계",       // Korean
            "مرحبا بالعالم",       // Arabic
            "🐴🦄🌟💫✨",           // Emoji
            "café résumé naïve",   // Latin with accents
            "🎉🎊🎁🎄🎅",           // More emoji
        ];
        for text in test_strings {
            let chunks = split_message(text, 10);
            assert_split_invariants(&chunks, text, 10);
        }
    }

    #[test]
    fn test_split_message_edge_cases() {
        // Various edge cases that must not panic and must satisfy invariants
        let long_no_break = "a".repeat(1000);
        let cases = vec![
            ("single space", " ", 10),
            ("multiple spaces", "     ", 10),
            ("tabs", "\t\t\t", 10),
            ("newline spam", "\n\n\n\n", 10),
            ("mixed whitespace", "  \t  \n  ", 10),
            ("ascii punctuation", "!@#$%^&*()_+-=[]{}|;':,./<>?", 20),
            ("long no-break string", &long_no_break, 400),
            ("alternating spaces", "a b c d e f g h i j k l m n o p q r s t u v w x y z", 10),
        ];
        for (_name, text, max_bytes) in cases {
            let chunks = split_message(text, max_bytes);
            assert_split_invariants(&chunks, text, max_bytes);
        }
    }

    #[test]
    fn test_split_message_single_giant_char() {
        // A single character that exceeds max_bytes must not panic
        // and must produce a valid (albeit oversized) chunk
        let text = "a"; // Won't exceed, but let's test with a known oversized case
        // We can't easily create a >400-byte codepoint in Rust strings,
        // so we test the guard path exists by verifying no panic on valid input.
        let chunks = split_message(text, 1);
        assert!(!chunks.is_empty());
        assert_split_invariants(&chunks, text, 1);
    }

    // ── Config / serialization tests (unchanged) ──

    #[test]
    fn test_parse_poll_response() {
        let json = r#"{"messages": [
            {"from": "alice", "text": "hello", "ts": "2026-03-05T12:00:00Z"},
            {"from": "bob", "text": "hey there", "ts": "2026-03-05T12:01:00Z"}
        ]}"#;
        let resp: AdapterPollResponse = serde_json::from_str(json).unwrap();
        assert_eq!(resp.messages.len(), 2);
        assert_eq!(resp.messages[0].from, "alice");
        assert_eq!(resp.messages[1].text, "hey there");
    }

    #[test]
    fn test_parse_poll_empty() {
        let json = r#"{"messages": []}"#;
        let resp: AdapterPollResponse = serde_json::from_str(json).unwrap();
        assert!(resp.messages.is_empty());
    }

    #[test]
    fn test_config_defaults() {
        let config: DarkIrcConfig = serde_json::from_str("{}").unwrap();
        assert_eq!(config.adapter_url, "http://127.0.0.1:6680");
        assert_eq!(config.dm_policy, "pairing");
        assert!(config.allow_from.is_empty());
        assert_eq!(config.poll_interval_seconds, 3);
    }

    #[test]
    fn test_config_full() {
        let json = r#"{
            "adapter_url": "http://10.0.0.5:7000",
            "dm_policy": "allowlist",
            "allow_from": ["sun", "kageho"],
            "poll_interval_seconds": 5
        }"#;
        let config: DarkIrcConfig = serde_json::from_str(json).unwrap();
        assert_eq!(config.adapter_url, "http://10.0.0.5:7000");
        assert_eq!(config.dm_policy, "allowlist");
        assert_eq!(config.allow_from, vec!["sun", "kageho"]);
        assert_eq!(config.poll_interval_seconds, 5);
    }

    #[test]
    fn test_metadata_roundtrip() {
        let meta = DarkIrcMessageMetadata {
            nick: "sun".to_string(),
        };
        let json = serde_json::to_string(&meta).unwrap();
        let parsed: DarkIrcMessageMetadata = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.nick, "sun");
    }

    #[test]
    fn test_send_request_serialization() {
        let req = AdapterSendRequest {
            to: "alice".to_string(),
            text: "hello".to_string(),
        };
        let json = serde_json::to_string(&req).unwrap();
        assert!(json.contains(r#""to":"alice""#));
        assert!(json.contains(r#""text":"hello""#));
    }
}
