# XMPP File Transfer Support

## Overview

LunarWing supports file transfers over XMPP in both directions, in DMs and group chats (including OMEMO-encrypted):

- **Outbound** (agent → user): XEP-0363 HTTP File Upload + OOB URL delivery (OMEMO-encrypted when the target is an encrypted room/DM).
- **Inbound** (user → agent): URL extraction from incoming stanzas — and from decrypted OMEMO bodies — with automatic download, including AES-256-GCM-encrypted `aesgcm://` media (XEP-0454).

The XMPP client also advertises its capabilities (XEP-0030/0115) and answers every IQ request, so contacts' clients recognize the agent as a valid recipient instead of refusing to send.

## Protocol Background

| XEP | Role |
|-----|------|
| **XEP-0363** (HTTP File Upload) | Sender requests an upload slot, PUTs the file, shares the GET URL. |
| **XEP-0066** (Out of Band Data) | The file URL travels in `<x xmlns='jabber:x:oob'><url>…</url></x>`. |
| **XEP-0454** (OMEMO Media Sharing) | Encrypted files use an `aesgcm://…#<hex(IV‖key)>` URL; the fetched body is AES-256-GCM ciphertext with the 16-byte tag appended. |
| **XEP-0030 / XEP-0115** (Service Discovery / Entity Caps) | The agent advertises an identity + feature set so clients know what it supports. |
| **XEP-0199** (Ping) | The agent answers pings to confirm liveness. |

Most clients (Conversations, Gajim, Dino) send the file URL as both the message body and an OOB element. Encrypted media usually arrives as an `aesgcm://` URL — sometimes only inside the (encrypted) body, with no cleartext OOB element.

## Capability Advertisement (XEP-0030 / XEP-0115)

The XMPP client (compiled into the bridge) answers incoming IQ stanzas rather than dropping them — required by RFC 6120 §8.2.3, and the reason clients will offer to send files at all:

- `disco#info` get → `<iq type='result'>` with identity `client/bot "LunarWing"` and features `http://jabber.org/protocol/disco#info`, `jabber:x:oob`, `urn:xmpp:ping`. `lunarwing_disco_info()` is the single source of truth.
- `urn:xmpp:ping` get → empty result.
- Any other get/set → `<error type='cancel'><service-unavailable/></error>` (no silent drops).
- Presence carries a XEP-0115 `<c/>` caps element whose `ver` is computed (`caps::compute_disco` + `caps::hash_caps`) from the same `disco#info`, so the advertised hash always matches the response.

Without this, capability-checking clients time out and treat the agent as unable to receive files (some then fall back to Jingle/XEP-0234, which the agent does not implement). Built in `build_iq_reply()` / `build_initial_presence()`.

## Architecture

```
Outbound (agent sends file):
  Agent tool produces OutboundAttachment
    -> XmppChannel.broadcast_with_attachments()
    -> XEP-0363 slot request (IQ to upload service)
    -> HTTP PUT file bytes to slot URL
    -> XMPP message with body=GET_URL + <x xmlns='jabber:x:oob'>
    -> OMEMO encryption if target is an encrypted room/DM

Inbound (user sends file):
  XMPP stanza arrives (OOB element and/or aesgcm:// URL in the body)
    -> XmppChannel.handle_message_stanza()   (OMEMO-decrypts the body first)
    -> extract_inbound_attachments(payloads, body)
         collect_oob_urls()    : <x jabber:x:oob> URLs (capped)
         collect_aesgcm_urls() : aesgcm:// URLs found only in the decrypted body
    -> bounded-concurrency download (<=4 at once), each via download_oob_file():
         http(s)   : GET + streaming size cap (read_capped_body)
         aesgcm:// : GET https form + AES-256-GCM decrypt (download_aesgcm_file)
    -> IncomingMessage.attachments populated with data + metadata
    -> Bridge enqueue_message() base64-encodes into BridgeMessage
    -> WASM channel on_poll() decodes, calls store_attachment_data()
    -> Host reconstructs IncomingAttachment for agent processing
```

## Inbound File Transfer Details

All inbound logic lives in `ic/src/channels/xmpp/mod.rs`.

### URL extraction (`extract_inbound_attachments`)

1. `collect_oob_urls(payloads, MAX_OOB_ATTACHMENTS)` — parses `<x xmlns='jabber:x:oob'>` elements (via `Oob::try_from`), capped at 10 per stanza.
2. `collect_aesgcm_urls(body, …)` — scans the **decrypted body** for `aesgcm://` URLs and adds any not already present (deduped, same cap). This covers encrypted files whose client omits the cleartext OOB element. Plain `https://` links in a body are intentionally **not** auto-downloaded.
3. Downloads run with **bounded concurrency** (`buffered`, ≤4 at once) so one slow URL can't serialize the batch and stall the single client event loop. Results stay in stanza order; per-URL failures are logged and skipped.

### Download (`download_oob_file`)

- **The size cap is enforced while streaming** (`read_capped_body` over `response.bytes_stream()`): the body is read chunk-by-chunk and aborted the moment it exceeds 20 MB, so a missing or understated `Content-Length` cannot cause unbounded buffering. A `Content-Length` header above the cap is also rejected up front.
- MIME type is inferred from the HTTP `Content-Type` (http/https path) and the filename via `filename_from_url()`.

### Encrypted media (`aesgcm://`, XEP-0454)

- `download_aesgcm_file()` handles `aesgcm://` URLs. `parse_aesgcm_url()` splits the URL into its https fetch form and the `IV‖key` from the `#fragment`; the ciphertext is fetched (same streaming cap) and `decrypt_aesgcm()` AES-256-GCM-decrypts it. Both the standard 12-byte IV and the legacy 16-byte IV are supported.
- Because the server stores ciphertext, MIME is inferred from the URL filename (`mime_guess`) rather than `Content-Type`. The original `aesgcm://` URL is kept as `source_url` so body deduplication still matches.

### Filenames (`filename_from_url`)

The last URL path segment is used, with any query/fragment stripped. A missing extension is fine — an opaque XEP-0363 segment (e.g. a UUID) is still a unique, useful name, which keeps distinct files from colliding on the downstream `oob-{filename}` storage key.

### Body deduplication / empty-body handling

- When the message body exactly equals an attachment's `source_url` (the common client pattern, and the `aesgcm://`-only-in-body case), the body is cleared so the agent doesn't see a redundant raw URL alongside the structured attachment.
- Messages with no text body but a valid attachment URL are accepted rather than dropped.

### Bridge transport

`BridgeMessage` carries attachments as `Vec<BridgeAttachment>` with base64-encoded file data. The field uses `#[serde(default)]` for backward compatibility with older bridge/channel versions.

### WASM channel processing

The WASM XMPP channel (`ic/channels-src/xmpp/src/lib.rs`) decodes inbound attachments during `on_poll()`: base64-decodes each `BridgeIncomingAttachment`, stores bytes via `store_attachment_data()`, and emits `InboundAttachment` records the host merges into `IncomingAttachment.data`.

## Limits

| Limit | Value | Enforced at |
|-------|-------|-------------|
| OOB/aesgcm URLs processed per stanza | 10 (`MAX_OOB_ATTACHMENTS`) | XmppChannel |
| Concurrent inbound downloads | 4 (`MAX_CONCURRENT_OOB_DOWNLOADS`) | XmppChannel |
| Per-file download size (enforced while streaming) | 20 MB (`OOB_MAX_FILE_SIZE`) | XmppChannel |
| Download timeout | 30 seconds | XmppChannel (reqwest client) |
| Per-attachment store | 20 MB | WASM host (`store_attachment_data`) |
| Total attachment store per callback | 50 MB | WASM host |
| Upload PUT timeout | 120 seconds | XmppChannel (outbound) |

## Files

| Component | File |
|-----------|------|
| XmppChannel — IQ/disco responder, caps, extraction, download, aesgcm decrypt | `ic/src/channels/xmpp/mod.rs` |
| Bridge contract (BridgeMessage with attachments) | `ic/openclaw-ports/xmpp/bridge/src/lib.rs` |
| Bridge service (enqueue_message forwarding) | `ic/bridges/xmpp-bridge/src/main.rs` |
| WASM XMPP channel (decode + emit) | `ic/channels-src/xmpp/src/lib.rs` |
| WIT interface (InboundAttachment, store-attachment-data) | `ic/wit/channel.wit` |
| WASM host (attachment storage + validation) | `ic/src/channels/wasm/host.rs` |

## Supported Attachment Types

The WASM host enforces a MIME-type allowlist. `AttachmentKind` classification:

- `Image` — `image/*`
- `Audio` — `audio/*`
- `Document` — everything else (PDF, text, archives, etc.)

## OMEMO Considerations

Encrypted file shares are handled end-to-end:

- **Unencrypted messages**: the OOB `<x>` element is present in `msg.payloads` and extracted directly; `https://` files are downloaded as-is.
- **Encrypted DMs/rooms**: the body is OMEMO-decrypted first, then scanned for `aesgcm://` URLs (`collect_aesgcm_urls`) — covering clients that omit the cleartext OOB element to avoid leaking the URL to the server. `aesgcm://` media is fetched and AES-256-GCM-decrypted locally (`download_aesgcm_file`). An `aesgcm://` URL carried in an OOB element is handled the same way.
- Plain `https://` URLs that appear only in a (decrypted) body are **not** auto-downloaded — only the explicit `aesgcm://` encrypted-media scheme is.

## Security Notes

- Inbound downloads fetch sender-supplied URLs. There is currently **no SSRF guard** on these fetches (private/loopback/metadata IPs are not blocked); this is deferred. Deployments rely on the network boundary and the `ALLOW_PRIVATE_IPS` model. A future phase can reuse `config/helpers.rs::validate_base_url` (gated on `ALLOW_PRIVATE_IPS`, via `spawn_blocking`).
- Size limits are enforced during streaming, and the per-stanza URL count and download concurrency are bounded, so a crafted stanza cannot exhaust memory or stall the connection.

## Implementation Status

Implemented and unit-tested (`cargo test channels::xmpp`); the standalone `xmpp-bridge` builds in release. Delivered in four phases:

1. **Capability advertisement** — `disco#info` responder, ping, `service-unavailable` for other IQs, XEP-0115 caps in presence.
2. **Download hardening** — bounded concurrency, per-stanza URL cap, streaming size enforcement.
3. **Encrypted media** — `aesgcm://` (XEP-0454) download + AES-256-GCM decrypt; decrypted-body URL re-parsing.
4. **Filename robustness** — `filename_from_url` (no longer drops extensionless/opaque names).

**Remaining:** live end-to-end validation against a real server (e.g. Conversations/Gajim → agent over a working XEP-0363 host); an optional SSRF guard.
