# XMPP File Transfer Methods — Quick Reference

### docs/ops/XMPP_TRANSFERS.md

*Created 2026-06-18, Kestrel*

## Overview

XMPP supports multiple file transfer methods, each with different tradeoffs in terms of server requirements, privacy, and file size limits.

---

## Protocol Comparison

| Protocol | XEP | Method | Server Required | File Size | Encryption |
|----------|-----|--------|-----------------|-----------|------------|
| **HTTP File Upload** | XEP-0363 | Server-mediated | Yes (upload slot) | Limited by server | OMEMO + HTTPS |
| **Jingle File Transfer** | XEP-0234 | Peer-to-peer | No (NAT traversal) | Unlimited | OMEMO + DTLS |
| **Out-of-Band Data** | XEP-0066 | External URL | No | Unlimited | Depends on URL |
| **In-Band Bytestreams** | XEP-0361 | Base64 in stanza | No | Small only (<1MB) | OMEMO |

---

## Implementation Status (LunarWing XMPP Bridge)

### ✅ Implemented

| Feature | Status | Notes |
|---------|--------|-------|
| `jabber:x:oob` (XEP-0066) | ✅ Implemented | Parses `<x xmlns='jabber:x:oob'>` elements |
| `aesgcm://` URLs (OMEMO) | ✅ Implemented | AES-256-GCM decryption for encrypted media |
| HTTP File Upload URLs (XEP-0363) | ✅ Implemented | Handles server-generated upload URLs |
| Bounded concurrency | ✅ Implemented | 4 concurrent downloads max |
| Size cap | ✅ Implemented | 20MB limit per file |
| Unit tests | ✅ Implemented | `ic/src/channels/xmpp/mod.rs` |

### ⏳ Pending

| Feature | Status | Notes |
|---------|--------|-------|
| End-to-end validation | ⏳ Pending | Live testing with Conversations/Gajim |
| Inbound download SSRF guard | ⏳ Deferred | Network boundary relied upon for now |

### ❌ Not Implemented

| Feature | Status | Notes |
|---------|--------|-------|
| Jingle File Transfer (XEP-0234) | ❌ Not in scope | P2P direct connection — requires ICE/STUN/TURN |
| In-Band Bytestreams (XEP-0361) | ❌ Not in scope | Base64 in stanzas — inefficient for files |

---

## Architecture

### Inbound File Transfer Flow

```
XMPP Client → XMPP Bridge → Agent
    │              │            │
    │  1. Extract URLs (oob/aesgcm/XEP-0363)
    │  2. Download (concurrent, capped)
    │  3. Decrypt (if aesgcm://)
    │  4. Base64 encode
    │  5. Attach to IncomingMessage
    │              │            │
    │              └───────────→│ 6. Process attachment
```

### Code Locations

- **URL extraction:** `ic/src/channels/xmpp/mod.rs` — `extract_inbound_attachments()`
- **OOB parsing:** `Oob::try_from` (XEP-0066)
- **AES-GCM decryption:** `download_aesgcm_file()`
- **HTTP download:** `download_oob_file()` (with `read_capped_body`)
- **Bridge message:** `BridgeMessage` (base64-encoded attachments)
- **WASM channel:** `on_poll()` decodes and calls `store_attachment_data()`

---

## Testing Checklist

### Phase 1: Unit Tests (✅ Complete)
- [x] OOB URL parsing
- [x] AES-GCM decryption
- [x] HTTP download with size cap
- [x] Concurrent download limits

### Phase 2: End-to-End Validation (⏳ Pending)
- [ ] Test with Conversations (Android)
- [ ] Test with Gajim (Linux)
- [ ] Test with Dino (Linux)
- [ ] Verify OMEMO-encrypted file transfers
- [ ] Verify HTTP Upload URL handling
- [ ] Verify OOB URL handling

### Phase 3: SSRF Hardening (⏳ Deferred)
- [ ] Implement allowlist for download domains
- [ ] Add network isolation for download workers
- [ ] Document security tradeoffs

---

## Prosody XEP-0363 Configuration (Reference)

For HTTP File Upload support, Prosody requires `mod_http_upload`:

```lua
-- Prosody config (prosody.cfg.lua)
Component "files.example.com" "http_upload"
    file_limit = 10485760  -- 10MB
    external_component_secret = "your-secret"
```

**Known Issue:** XEP-0363 module setup requires proper slot provisioning and CORS configuration. See `docs/bugs/` for troubleshooting notes.

---

## Related Documentation

- `docs/architecture/XMPP_FILE_TRANSFERS.md` — Full implementation details
- `docs/bugs/XMPP-OMEMO-BUG-TO-DO.md` — Bug tracking
- `docs/ops/GOALS_1.1.5.md` — Release goals including XMPP polish
- `ic/testing/lunarwing-xmpp/` — Test harness setup

---

## Release Notes for v1.1.5

**New Features:**
- Inbound file transfer support (OOB, AES-GCM, HTTP Upload URLs)
- Bounded concurrency (4 downloads max)
- 20MB file size cap

**Known Issues:**
- End-to-end testing pending
- SSRF guard deferred (network boundary relied upon)

**Not Included:**
- Jingle File Transfer (XEP-0234) — out of scope

---

*Glory is for admirals. Uptime is forever.*

