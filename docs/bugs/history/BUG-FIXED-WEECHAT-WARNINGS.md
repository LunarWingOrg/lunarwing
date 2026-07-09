# BUG: WeeChat relay crate — unused import (fixed) + `rand_check` latent bug (open)

**Status:** Partially fixed (verified 2026-07-09) — the unused `HttpEndpointConfig` import has
been removed. The `rand_check` stub remains (see below).
**Crate:** `lunarwing_weechat_wss/weechat_relay` (WeeChat WSS WASM channel source)

## 1. ~~Unused import~~ (fixed)

~~`HttpEndpointConfig` is imported but not otherwise used in the file, producing an
`unused_imports` warning.~~ **Fixed** — the import has been removed from
`lunarwing_weechat_wss/weechat_relay/src/lib.rs`.

## 2. `rand_check` ignores its argument (latent bug)

`rand_check(probability: f64) -> bool` (line ~1762) never reads `probability`; the body is a
stub that unconditionally returns `false`:

```rust
/// Simple pseudo-random check (returns true with given probability).
fn rand_check(probability: f64) -> bool {
    // ... "For now, just return false (disable random features)"
    false
}
```

Any feature gated on `rand_check(p)` is therefore silently always-off regardless of the intended
probability. Severity is Low because it **fails closed** (random features are simply disabled),
but the signature promises behavior the body doesn't deliver.

**Fix options:** implement a lightweight no-`std::rand` PRNG (e.g. hash some changing workspace
state and compare against the threshold), or remove the dead parameter and its call sites if the
random behavior is no longer wanted.

Both items are pre-existing and unrelated to the change that surfaced them.
