# BUG: WeeChat relay crate — pre-existing warnings + `rand_check` latent bug

**Status:** Open (Low) — verified 2026-06-19
**Crate:** `ironclaw_weechat_wss/weechat_relay` (WeeChat WSS WASM channel source)

Two pre-existing issues in `ironclaw_weechat_wss/weechat_relay/src/lib.rs`, originally noticed
in passing during an unrelated change and left as out-of-scope.

## 1. Unused import (cosmetic)

`HttpEndpointConfig` is imported (around line 47) but not otherwise used in the file, producing
an `unused_imports` warning. Remove it from the `use` list.

## 2. `rand_check` ignores its argument (latent bug)

`rand_check(probability: f64) -> bool` (line ~1766) never reads `probability`; the body is a
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
