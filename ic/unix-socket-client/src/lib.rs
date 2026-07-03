//! `lunarwing repl` — connect to a running LunarWing daemon via Unix socket.
//!
//! The daemon must already be running (e.g. via `systemctl start lunarwing`)
//! and listening on its Unix socket. The default path mirrors the daemon's
//! resolution: `$LUNARWING_SOCKET` (legacy `$IRONCLAW_SOCKET`), then
//! `$XDG_RUNTIME_DIR/lunarwing.sock`, then `<base_dir>/lunarwing.sock`.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::net::unix::OwnedWriteHalf;

/// Protocol messages — must stay in sync with the server's
/// `unix_socket_repl::ReplMessage`.
#[derive(Debug, Serialize, Deserialize)]
enum ReplMessage {
    Connect {
        version: String,
        client_info: Option<String>,
    },
    Message {
        content: String,
        session_id: Option<String>,
    },
    Response {
        content: String,
        session_id: Option<String>,
        is_complete: bool,
    },
    Disconnect {
        session_id: Option<String>,
        reason: Option<String>,
    },
    Ping,
    Pong,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let socket_path = std::env::args()
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(default_socket_path);

    println!("LunarWing Unix Socket Client");
    println!("Connecting to: {}", socket_path.display());

    let stream = UnixStream::connect(&socket_path).await.map_err(|e| {
        anyhow::anyhow!(
            "Failed to connect to LunarWing REPL at {}: {}.\n\
             Make sure the daemon is running (`lunarwing run` or `systemctl start lunarwing`).",
            socket_path.display(),
            e
        )
    })?;

    println!("Connected!");

    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);

    // ── Handshake ────────────────────────────────────────────────
    send_message(
        &mut write_half,
        &ReplMessage::Connect {
            version: env!("CARGO_PKG_VERSION").to_string(),
            client_info: None,
        },
    )
    .await?;

    match read_message(&mut reader).await? {
        ReplMessage::Response { content, .. } => println!("{content}"),
        other => eprintln!("unexpected welcome: {other:?}"),
    }

    println!("Type 'exit' or 'quit' to disconnect.");
    println!("---");

    // ── Main loop ────────────────────────────────────────────────
    let mut stdin = BufReader::new(tokio::io::stdin());
    let mut line = String::new();

    loop {
        {
            use std::io::Write as _;
            print!("> ");
            std::io::stdout().flush()?;
        }

        line.clear();
        let n = stdin.read_line(&mut line).await?;
        if n == 0 {
            // Ctrl-D / EOF
            break;
        }

        let input = line.trim();

        if input.eq_ignore_ascii_case("exit") || input.eq_ignore_ascii_case("quit") {
            send_message(
                &mut write_half,
                &ReplMessage::Disconnect {
                    session_id: None,
                    reason: Some("client requested disconnect".to_string()),
                },
            )
            .await?;
            break;
        }

        if input.is_empty() {
            continue;
        }

        send_message(
            &mut write_half,
            &ReplMessage::Message {
                content: input.to_string(),
                session_id: None,
            },
        )
        .await?;

        match read_message(&mut reader).await {
            Ok(ReplMessage::Response { content, .. }) => println!("{content}"),
            Ok(ReplMessage::Ping) => {
                send_message(&mut write_half, &ReplMessage::Pong).await?;
            }
            Ok(other) => {
                eprintln!("unexpected server message: {other:?}");
            }
            Err(e) => {
                eprintln!("Connection lost: {e}");
                break;
            }
        }
    }

    Ok(())
}

/// Resolve the default socket path, mirroring the daemon's resolution order:
/// `$LUNARWING_SOCKET` (legacy `$IRONCLAW_SOCKET`), then
/// `$XDG_RUNTIME_DIR/lunarwing.sock`, then `<base_dir>/lunarwing.sock` where
/// `<base_dir>` is `$LUNARWING_BASE_DIR` (legacy `$IRONCLAW_BASE_DIR`) or
/// `~/.ironclaw` as the pre-rename fallback.
fn default_socket_path() -> PathBuf {
    if let Ok(path) = std::env::var("LUNARWING_SOCKET") {
        return PathBuf::from(path);
    }
    if let Ok(path) = std::env::var("IRONCLAW_SOCKET") {
        return PathBuf::from(path);
    }
    if let Ok(runtime_dir) = std::env::var("XDG_RUNTIME_DIR") {
        return PathBuf::from(runtime_dir).join("lunarwing.sock");
    }
    let base_dir = std::env::var("LUNARWING_BASE_DIR")
        .or_else(|_| std::env::var("IRONCLAW_BASE_DIR"))
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            dirs::home_dir()
                .unwrap_or_else(|| PathBuf::from("."))
                .join(".ironclaw")
        });
    base_dir.join("lunarwing.sock")
}

async fn send_message(write: &mut OwnedWriteHalf, msg: &ReplMessage) -> anyhow::Result<()> {
    let mut line = serde_json::to_string(msg)?;
    line.push('\n');
    write.write_all(line.as_bytes()).await?;
    Ok(())
}

async fn read_message(
    reader: &mut BufReader<tokio::net::unix::OwnedReadHalf>,
) -> anyhow::Result<ReplMessage> {
    let mut buf = String::new();
    reader.read_line(&mut buf).await?;
    if buf.is_empty() {
        anyhow::bail!("server disconnected");
    }
    let msg = serde_json::from_str(&buf)?;
    Ok(msg)
}
