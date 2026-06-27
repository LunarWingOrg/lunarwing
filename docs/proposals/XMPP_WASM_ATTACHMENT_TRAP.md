# XMPP WASM Attachment Trap Investigation

## Status

- Draft proposal
- Investigated on 2026-06-27
- Not yet validated by a code patch / live re-test

## Problem Summary

Inbound XMPP attachments are successfully delivered from the bridge to the daemon, but the XMPP WASM channel traps during `on_poll()` before the message reaches the agent.

Observed log shape:

- `/v1/messages` returns a message with:
  - `content = ""`
  - one attachment (example: `filename = "1118314.png"`, `mime_type = "image/png"`, base64 payload present)
- immediately after polling, the daemon logs:
  - `Polling callback failed channel=xmpp error=Channel xmpp WASM execution trapped: error while executing at wasm backtrace:`
- the same message is re-polled on later ticks, indicating the cursor never advances past the failing message

This affects plain file shares and OMEMO-delivered file shares once they arrive at the bridge as attachment payloads.

## Important Files and Functions

### WASM XMPP channel

- `ic/channels-src/xmpp/src/lib.rs`
  - `on_poll()`
  - `decode_inbound_attachments()`

This is the most likely crash site.

### WASM wrapper and trap mapping

- `ic/src/channels/wasm/wrapper.rs`
  - `execute_poll()`
  - `map_wasm_error()`

This is where the trap is surfaced to the daemon log as `WASM execution trapped`.

### Host-side attachment handling

- `ic/src/channels/wasm/host.rs`
  - `store_attachment_data()`
  - `emit_message()`

These host functions validate and store attachment bytes after the WASM channel hands them off.

### Resource limiting / trap source

- `ic/src/tools/wasm/limits.rs`
  - `memory_growing()`

If linear memory growth is denied by the limiter, Wasmtime can surface that as a trap.

### Default WASM channel limits

- `ic/src/channels/wasm/runtime.rs`
  - default memory limit: 50 MB
  - default fuel limit: 10,000,000

### Bridge attachment schema

- `ic/openclaw-ports/xmpp/bridge/src/lib.rs`
  - bridge message / attachment JSON schema used by the XMPP WASM channel

## High-Confidence Diagnosis

The most probable root cause is **WASM linear memory exhaustion during inbound attachment decoding**, not a serde mismatch, not an empty-content bug, and not a base64 decode error.

### Why this is the likely cause

The XMPP WASM channel appears to hold several copies of the attachment data inside WASM linear memory during a single poll cycle:

1. raw `/v1/messages` HTTP response body (JSON with base64 payload)
2. parsed JSON representation containing the base64 string
3. decoded attachment bytes (`Vec<u8>`) after base64 decode
4. attachment structs and component-model overhead

Even for a ~1 MB PNG, this creates multiple megabytes of in-flight allocations at the same time.

The host-side attachment storage limit is not the first problem here; the problem is that the data appears to peak in **WASM memory before the host can fully own it**.

If `memory_growing()` denies a growth request at the 50 MB channel ceiling, Wasmtime can surface that denial as a trap, which matches the observed daemon log.

## Why other explanations are less likely

### Not a bridge/serde schema mismatch

The bridge successfully returns JSON containing `attachments`, and the attachment field names appear to match what the WASM side expects. If deserialization were failing, this would likely show up as a handled parse error rather than a trap.

### Not an empty-content bug

The failing messages show `content = ""`, but empty content itself should be acceptable once an attachment exists. The important detail is that the trap happens while processing the attachment-bearing poll response.

### Not just a base64 error

A normal base64 decoding failure would be expected to produce a recoverable error path or dropped attachment, not a repeated WASM trap on every poll.

### Probably not fuel exhaustion

Fuel exhaustion should surface differently from a generic trap. The observed error shape is more consistent with memory growth denial / trap behavior.

## Proposed Fixes

### Fix 1: Drop large temporary buffers earlier in the WASM XMPP channel

In `ic/channels-src/xmpp/src/lib.rs`:

- free the raw HTTP response buffer as early as possible after parsing
- reduce how long the parsed JSON and decoded attachment buffers coexist
- avoid keeping decoded bytes alive after they are handed to `store_attachment_data()`

Goal: reduce peak concurrent WASM memory usage during `on_poll()`.

### Fix 2: Explicitly shorten attachment decode lifetime

Inside `decode_inbound_attachments()`:

- decode one attachment
- hand it off to host storage immediately
- release the WASM-side decoded buffer immediately
- avoid accumulating extra temporary copies

Goal: avoid multiple large attachment copies surviving longer than necessary.

### Fix 3: Increase XMPP channel WASM memory limit

As defense in depth, increase the XMPP channel memory limit above the current 50 MB default (for example to 128 MB), either:

- in `ic/src/channels/wasm/runtime.rs` defaults, or
- via a per-channel override if that is supported by the capabilities/runtime path

Goal: provide headroom for attachment-heavy poll responses.

### Fix 4: Add a regression test

Add a regression test that simulates a `/v1/messages` response containing:

- empty content
- one ~1 MB base64 image attachment

The test should verify:

- `on_poll()` does not trap
- the cursor advances
- the message is emitted to the agent queue with the attachment intact

## Verification Plan

All Rust verification should follow the Arch VM constraints:

```bash
cd /home/dame/lunarwing/ic
taskset -c 0-5 cargo test -j6 -- --test-threads=6
```

Targeted steps:

### Rebuild XMPP WASM channel

```bash
cd /home/dame/lunarwing/ic
./channels-src/xmpp/build.sh
```

### Run targeted tests

```bash
cd /home/dame/lunarwing/ic
taskset -c 0-5 cargo test -j6 xmpp -- --nocapture
```

If a dedicated regression test is added in WASM/channel wrapper coverage, run that exact test as well.

### Live verification

1. send a PNG attachment over XMPP to the agent
2. watch daemon logs
3. confirm the repeated line disappears:
   - `Polling callback failed channel=xmpp error=Channel xmpp WASM execution trapped...`
4. confirm the cursor advances instead of replaying the same message
5. confirm the agent receives the attachment successfully

Useful live log symptoms:

- **bad / current behavior**: repeated poll trap, same message replayed
- **good / expected behavior after fix**: successful poll processing, no repeated trap, attachment visible to the agent

## Risks / Notes

- This diagnosis is high-confidence from code inspection and log shape, but should still be treated as **not fully proven** until a patch is applied and the live scenario is re-tested.
- Raising memory limits alone may hide the symptom without addressing excessive temporary allocation patterns.
- The more robust fix is to reduce temporary WASM-side copies first, then increase limits only if needed.
- If the actual trap turns out to be something narrower in the component model boundary, the same regression test should still catch it.

## Recommendation

Priority order:

1. patch `ic/channels-src/xmpp/src/lib.rs` to reduce temporary attachment memory pressure
2. add a regression test for large inbound base64 attachments
3. increase XMPP channel memory headroom if needed
4. live-test with a real PNG sent over XMPP and confirm the cursor advances
