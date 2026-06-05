mod bridge;
mod executor;
mod health;
mod protocol;

use std::net::SocketAddr;
use std::sync::Arc;

#[tokio::main]
async fn main() {
    let config = bridge::BridgeConfig::from_env();
    eprintln!(
        "[pebble4lunarwing] worker_id={} version={}",
        config.worker_id,
        protocol::WORKER_VERSION
    );
    eprintln!(
        "[pebble4lunarwing] ws={}:{}{} health=:{} auth={}",
        config.bind_host,
        config.ws_port,
        config.ws_path,
        config.health_port,
        if config.auth_token.is_some() {
            "enabled"
        } else {
            "disabled"
        }
    );
    eprintln!(
        "[pebble4lunarwing] pebble_bin={} model={} permission_mode={}",
        config.pebble_bin, config.model, config.permission_mode
    );

    let state = Arc::new(health::WorkerState::new(&config.worker_id));

    let health_addr: SocketAddr = ([0, 0, 0, 0], config.health_port).into();
    let health_state = Arc::clone(&state);
    tokio::spawn(async move {
        if let Err(e) = health::serve(health_addr, health_state).await {
            eprintln!("[pebble4lunarwing] health server error: {e}");
        }
    });

    if let Err(e) = bridge::run(config, state).await {
        eprintln!("[pebble4lunarwing] bridge error: {e}");
        std::process::exit(1);
    }
}
