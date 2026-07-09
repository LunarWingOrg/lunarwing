# BUG: e2e bootstrap-greeting tests fail (greeting not observed by the test rig)

**Status:** Open
**Severity:** Medium — test-only; the production greeting path (DB persist + SSE broadcast) is not
known to be broken, but the assertion fails so the suite is not green.
**Found:** 2026-06-07 — surfaced once the `cargo test` compile blocker (`e2e_telegram_message_routing.rs`
`Arc::new(agent).run()`) was fixed. **Pre-existing**: this binary never built before, so it never ran.
**Affects:** `cargo test --test e2e_advanced_traces`

## Affected tests

- `advanced::bootstrap_greeting_fires` — `tests/e2e_advanced_traces.rs:828` (panics at `:834`)
- `advanced::bootstrap_onboarding_clears_bootstrap` — `tests/e2e_advanced_traces.rs:862` (panics at `:874`)

## Symptoms

```
thread 'advanced::bootstrap_greeting_fires' panicked at tests/e2e_advanced_traces.rs:834:9:
bootstrap greeting should produce a response
thread 'advanced::bootstrap_onboarding_clears_bootstrap' panicked at tests/e2e_advanced_traces.rs:874:9:
bootstrap greeting should arrive
```

Both build a rig with `TestRigBuilder::new().with_bootstrap()` and call
`rig.wait_for_responses(1, TIMEOUT)` expecting one proactive response containing the static greeting
text (`"chief of staff"`, from `src/workspace/seeds/BOOTSTRAP.md`). No response arrives within the
timeout, so `responses` is empty and the assertion fails. **No LLM/`StubLlm` is involved** — the
greeting is static.

## How it surfaced

Not a regression from any recent change. Before the telegram test was fixed, `cargo test` failed to
compile, so `e2e_advanced_traces` was never executed and these failures were invisible. Fixing the
compile blocker unmasked them.

## Root-cause analysis (hypothesis — not yet confirmed)

The proactive bootstrap greeting is **persisted to the DB and broadcast over SSE at startup**, not
emitted as a channel `OutgoingResponse`:

- `ic/src/agent/agent_loop.rs:392–399` — on `run()`, if `workspace.take_bootstrap_pending()` is true,
  the static greeting is **persisted to the DB before `start_all()`**.
- `ic/src/agent/agent_loop.rs:840–841` — the greeting is then **broadcast via SSE for any clients
  already connected**.
- `ic/src/workspace/mod.rs:425–426` — `bootstrap_pending` is the `AtomicBool` the loop checks/clears.

The test rig, however, observes **channel `OutgoingResponse`s** via `wait_for_responses`
(`tests/support/test_rig.rs:97`, `tests/support/test_channel.rs:132`), and `with_bootstrap()` keeps
`bootstrap_pending` and names the channel `"gateway"` because "the bootstrap greeting targets only the
gateway channel" (`tests/support/test_rig.rs:769–771`).

So the failure is most likely **one of**:
1. **Path mismatch** — the greeting reaches DB + SSE but is not delivered through the channel
   `OutgoingResponse` path the rig captures, so `wait_for_responses` never sees it.
2. **Startup-ordering race** — the greeting is broadcast "for any clients already connected," but the
   test channel subscribes *after* the broadcast and misses it.

Both point at a divergence between how the greeting is delivered and how the rig listens — i.e. the
test's expectation (or the rig's capture wiring), rather than the production greeting itself, may be
what's stale.

## Affected code

| File | Relevance |
|------|-----------|
| `ic/src/agent/agent_loop.rs:392–399, 840–841` | Persists + SSE-broadcasts the static greeting |
| `ic/src/workspace/mod.rs:425–426` | `bootstrap_pending` flag |
| `ic/src/workspace/seeds/BOOTSTRAP.md` | Source of the `"chief of staff"` greeting text |
| `ic/tests/support/test_rig.rs:472–474, 591–594, 769–771` | `with_bootstrap()`, gateway-channel wiring |
| `ic/tests/e2e_advanced_traces.rs:828–852, 862+` | The two failing tests |

## Proposed next steps (investigation)

1. Confirm whether the proactive greeting is delivered as a channel `OutgoingResponse` at all, or only
   via DB row + SSE. If DB/SSE only, decide whether the test should assert against the DB/SSE surface
   instead of `wait_for_responses`.
2. If it *is* meant to flow through the channel, check the startup ordering: is the greeting
   broadcast before the test channel is registered/listening? If so, the rig must subscribe before
   `run()` starts, or the greeting must be queued for late subscribers.
3. Reproduce in isolation: `cargo test --test e2e_advanced_traces bootstrap -- --nocapture` and add
   tracing around `take_bootstrap_pending()` and the broadcast site.

## Notes

- Test-only; no evidence the production bootstrap greeting is broken (the assertion concerns the test
  rig's observation channel).
- Tracked in `docs/releases/RELEASE-v1.1.1.md` Known Issues and `docs/bugs/README.md`.
