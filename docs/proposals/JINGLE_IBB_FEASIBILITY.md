# Jingle / IBB File Transfer Feasibility Investigation

## Status

- Research completed 2026-06-27
- Decision: deferred — XEP-0363 HTTP Upload covers ~80% of use cases
- Revisit if large-file P2P transfer or protocol completeness becomes a priority

## Background

LunarWing's XMPP channel currently supports XEP-0363 HTTP File Upload for outbound file transfers and XEP-0066 OOB / XEP-0454 `aesgcm://` for inbound. Jingle File Transfer (XEP-0234) and In-Band Bytestreams (XEP-0047) are not implemented.

This investigation assessed the feasibility of adding Jingle + SOCKS5 Bytestreams (XEP-0260) and IBB (XEP-0261) to the XMPP bridge.

## Client Support Landscape (as of 2026-06)

| Client | XEP-0363 HTTP Upload | XEP-0234 Jingle FT | Notes |
|--------|----------------------|---------------------|-------|
| Conversations | Complete | Limited | HTTP Upload is primary path |
| Dino | Complete | Partial (XEP-0166 also partial) | Best modern desktop candidate for Jingle interop |
| Gajim 2.0.0 | Complete | **Disabled** (bit-rotted) | Jingle FT hidden pending reimplementation |

Modern XMPP guidance: HTTP Upload = strongly recommended. Jingle = optional, "not nearly universal even among modern clients."

## Server-Side Requirements

### XEP-0363 (current)
- Prosody: `mod_http_file_share` (built-in since 0.12)
- Requires HTTP server config + DNS + TLS for upload domain
- No new ports beyond 80/443

### Jingle + SOCKS5 (XEP-0260)
- Prosody: `mod_proxy65` provides SOCKS5 relay
- Requires opening `5000/tcp` (or chosen port)
- Requires DNS record for proxy component (e.g. `proxy.example.com`)
- Server just routes signaling; clients must implement Jingle session management
- NAT traversal needs proxy or direct IP connectivity

### Jingle + IBB (XEP-0261)
- No special server module needed (rides existing XMPP stanzas)
- No new ports, no DNS, no proxy
- Very slow (Base64 overhead, per-chunk ACK through server)
- Standards-mandated fallback of last resort

## Codebase Feasibility

### Current state
- XMPP stack: `tokio-xmpp` 5.0.0 + `xmpp-parsers` 0.22.0
- No Jingle session management exists
- No SOCKS5 bytestream primitives
- No IBB implementation
- No Jingle/SOCKS5/IBB parser types imported
- Bridge is stanza/IQ-centric and HTTP-centric; no general stream session subsystem

### Effort estimates

| Path | Architecture fit | Effort | New ports/infra |
|------|-----------------|--------|-----------------|
| **IBB standalone** | Excellent (rides existing IQ handling) | Moderate | None |
| **Jingle + IBB** (XEP-0261) | Good (Jingle signaling + IBB transport) | Moderate-high | None |
| **Jingle + SOCKS5** (XEP-0260) | Poor (no stream session subsystem) | Very high | proxy65 + DNS + firewall |

### Recommended implementation order (if pursued)
1. Add capability advertisement scaffolding for future transfer methods
2. Add transfer session abstraction in native XMPP code
3. Implement IBB first as a bounded small-file transport
4. Then implement Jingle signaling
5. Then add SOCKS5 bytestream transport engine
6. Finally do client interop testing against Dino/Conversations

## Decision

**Defer.** XEP-0363 HTTP Upload is now working on the maintainer's Prosody server and covers the majority of real-world use cases. Jingle/SOCKS5 adds significant complexity (new subsystem, server proxy config, NAT traversal) for diminishing returns given that Gajim disabled Jingle FT and Dino only has partial support.

Revisit if:
- Large-file P2P transfer becomes a user requirement
- Protocol completeness with advanced XMPP clients is desired
- Jingle audio/video calls are ever planned (code reuse)
