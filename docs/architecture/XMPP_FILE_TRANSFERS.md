# XMPP File Transfer Support

## Overview

LunarWing supports file transfers over XMPP in both directions:

- **Outbound** (agent to user): XEP-0363 HTTP File Upload + OOB URL delivery
- **Inbound** (user to agent): OOB URL extraction from incoming stanzas with automatic download

Both paths work in DMs and group chats, including OMEMO-encrypted rooms.

## Protocol Background

XMPP file transfer uses two complementary XEPs:

- **XEP-0363 (HTTP File Upload)**: The sender requests an upload slot from the server, PUTs the file to the returned URL, then shares the GET URL with the recipient.
- **XEP-0066 (Out of Band Data)**: The file URL is embedded in the message stanza as `<x xmlns='jabber:x:oob'><url>...</url></x>`. This tells the recipient that the message contains a downloadable file.

Most XMPP clients (Conversations, Gajim, Dino) send the file URL as both the message body and an OOB element. The body provides a clickable link for clients that don't understand OOB; the OOB element enables structured handling.

## Architecture

```
Outbound (agent sends file):
  Agent tool produces OutboundAttachment
    -> XmppChannel.broadcast_with_attachments()
    -> XEP-0363 slot request (IQ to upload service)
    -> HTTP PUT file bytes to slot URL
    -> XMPP message with body=GET_URL + <x xmlns='jabber:x:oob'>
    -> OMEMO encryption if target is encrypted room/DM

Inbound (user sends file):
  XMPP stanza arrives with <x xmlns='jabber:x:oob'>
    -> XmppChannel.handle_message_stanza()
    -> extract_oob_attachments() parses OOB payloads
    -> reqwest GET downloads file bytes (30s timeout, 20MB limit)
    -> IncomingMessage.attachments populated with data + metadata
    -> Bridge enqueue_message() base64-encodes into BridgeMessage
    -> WASM channel on_poll() decodes, calls store_attachment_data()
    -> Host reconstructs IncomingAttachment for agent processing
```

## Inbound File Transfer Details

### OOB Extraction (XmppChannel)

`extract_oob_attachments()` in `ic/src/channels/xmpp/mod.rs`:

1. Iterates message payloads looking for `<x xmlns='jabber:x:oob'>` elements
2. Parses each with `xmpp_parsers::oob::Oob::try_from()`
3. Downloads the file via HTTP GET with a 30-second timeout
4. Enforces a 20MB per-file size limit (matching the WASM `store_attachment_data` ceiling)
5. Infers MIME type from the HTTP `Content-Type` response header
6. Extracts filename from the URL path

**Body deduplication**: When the message body exactly matches an OOB URL (the common XMPP client pattern), the body is cleared to avoid the agent seeing a redundant raw URL alongside the structured attachment.

**Empty-body handling**: Messages with no text body but valid OOB attachments are accepted rather than dropped.

### Bridge Transport

The bridge contract (`BridgeMessage`) carries attachments as `Vec<BridgeAttachment>` with base64-encoded file data. The field uses `#[serde(default)]` for backward compatibility with older bridge/channel versions that don't include it.

### WASM Channel Processing

The WASM XMPP channel (`ic/channels-src/xmpp/src/lib.rs`) decodes inbound attachments during `on_poll()`:

1. Base64-decodes each `BridgeIncomingAttachment.data_base64`
2. Stores bytes via `channel_host::store_attachment_data()`
3. Emits `InboundAttachment` records with the `EmittedMessage`
4. The host merges stored data into `IncomingAttachment.data` for agent consumption

## Limits

| Limit | Value | Enforced at |
|-------|-------|-------------|
| Per-file download size | 20 MB | XmppChannel (OOB download) |
| Download timeout | 30 seconds | XmppChannel (reqwest client) |
| Per-attachment store | 20 MB | WASM host (`store_attachment_data`) |
| Total attachment store per callback | 50 MB | WASM host |
| Upload PUT timeout | 120 seconds | XmppChannel (outbound) |

## Files

| Component | File |
|-----------|------|
| XmppChannel (OOB extraction + download) | `ic/src/channels/xmpp/mod.rs` |
| Bridge contract (BridgeMessage with attachments) | `ic/openclaw-ports/xmpp/bridge/src/lib.rs` |
| Bridge service (enqueue_message forwarding) | `ic/bridges/xmpp-bridge/src/main.rs` |
| WASM XMPP channel (decode + emit) | `ic/channels-src/xmpp/src/lib.rs` |
| WIT interface (InboundAttachment, store-attachment-data) | `ic/wit/channel.wit` |
| WASM host (attachment storage + validation) | `ic/src/channels/wasm/host.rs` |

## Supported Attachment Types

The WASM host enforces a MIME type allowlist. The `AttachmentKind` classification:

- `Image` — `image/*`
- `Audio` — `audio/*`
- `Document` — everything else (PDF, text, archives, etc.)

## OMEMO Considerations

OOB URLs in OMEMO-encrypted messages are embedded in the plaintext body (before encryption), not in the outer stanza. After OMEMO decryption, the plaintext may contain a URL that was the original OOB body. The OOB `<x>` element itself is typically NOT encrypted — it appears alongside the `<encrypted>` element in the outer stanza.

In practice:
- **Unencrypted messages**: OOB element is present in `msg.payloads` and extracted directly
- **Encrypted DMs/rooms**: The OOB URL may appear in the decrypted plaintext body. The OOB `<x>` element in the outer stanza (if present) is still parsed. Some clients omit the outer OOB element for encrypted messages to avoid leaking the URL to the server.

## Implementation

### Finished phase 1

### Finished phase 2

### Finished phase 3

### Apply patch [X] Now
