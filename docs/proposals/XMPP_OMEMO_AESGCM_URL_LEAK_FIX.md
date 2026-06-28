# OMEMO aesgcm:// URL Leak Fix

## Status

- Fixed on 2026-06-27
- Commit: `1fdcf362`
- Not yet compile-verified or live-tested

## Problem

When a user sent an OMEMO-encrypted file share over XMPP, the bridge correctly decrypted the message body and `extract_inbound_attachments()` correctly downloaded and decrypted the `aesgcm://` file. However, the raw `aesgcm://` URL **survived into the agent's LLM context** alongside the decrypted attachment bytes.

The agent's HTTP tool then refused the URL (HTTPS-only scheme check), and the LLM narrated the failure as "SSRF protection" or "only https:// allowed" — misleading the user about what actually happened.

## Root Cause

`ic/src/channels/xmpp/mod.rs`, lines 1537–1546 (pre-fix):

```rust
let content = if !attachments.is_empty()
    && attachments
        .iter()
        .any(|a| a.source_url.as_deref() == Some(content.trim()))
{
    String::new()
} else {
    content
};
```

This only cleared the body when the **entire message body** equaled the attachment URL. For real messages like `"check this out aesgcm://host/file.jpg#key thanks"`, neither the prose alone nor the full string matched the URL by itself, so the URL leaked.

Meanwhile `download_aesgcm_file()` (line 3060) correctly downloaded and decrypted the file, and set `source_url: Some(url.to_string())` on the attachment (line 3104, with a comment saying "so body deduplication matches" — aspirational, not actually working).

## Fix

Replaced the all-or-nothing equality check with `strip_attachment_urls()` — a helper that strips each attachment's `source_url` as a substring from the body, then clears the body if only whitespace remains.

```rust
fn strip_attachment_urls(mut content: String, attachments: &[IncomingAttachment]) -> String {
    for attachment in attachments {
        if let Some(url) = attachment.source_url.as_deref() {
            content = content.replace(url, "");
        }
    }
    if content.trim().is_empty() {
        String::new()
    } else {
        content
    }
}
```

Two regression tests added:
- `strip_attachment_urls_removes_embedded_aesgcm_urls` — URL embedded in prose
- `strip_attachment_urls_clears_url_only_body` — body is only the URL

## Verification Needed

```bash
cd /home/dame/lunarwing/ic
taskset -c 0-5 cargo check -j6
taskset -c 0-5 cargo test -j6 xmpp -- --nocapture
```

Live test: send an OMEMO-encrypted file share to the agent and confirm the agent no longer sees the raw `aesgcm://` URL in its context.
