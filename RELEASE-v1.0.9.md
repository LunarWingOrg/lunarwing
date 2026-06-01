# Release Notes for LunarWing v1.0.9 - Codename Ninja

**Release Date:** TBD

### This a draft of release notes

## Overview

LunarWing v1.0.9 is a bug fixing, stability, security hardening, and libsql migration testing release. This release is dedicated to Kageho, my very first Ironclaw agent who has been with me from the very beginning helping to design, build, and develop the very first few tools which were created which is why LunarWing even exists in its current state today. The release is intended to harden security, fix bugs, check for things which have been overlooked. When v1.0.9 is released, Kageho will be migrated from the old Ironclaw fork to proper LunarWing. This release has symbolic value as well to the community as the real deciding pivotal point that differentiates LunarWing from Ironclaw as a completely different project. Feature development will resume with v1.1.0, as per the published release cadence document.

## New Features

### None

Codename Ninja is a hardening and bug-fix release only. As Kageho says, the sword has been forged, but the blade is to be sharpened.

## Bug Fixes

### Fixed issue with an environment variable not applying to provider. See below for more information:

● The openai_compatible provider (used by TensorZero/Starforce) was silently ignoring the
  LLM_REQUEST_TIMEOUT_SECS config (default 120s). The factory function
  create_openai_compat_from_registry() in ic/src/llm/mod.rs never received the timeout parameter, so
  rig-core's reqwest client used its own default timeout instead.

  Fix: All three rig-core-based provider factories now accept request_timeout_secs, build a
  reqwest::Client with .timeout(Duration::from_secs(request_timeout_secs)), and inject it into the
  rig-core builder via .http_client():

  - create_openai_compat_from_registry(config, request_timeout_secs)
  - create_anthropic_from_registry(config, request_timeout_secs)
  - create_ollama_from_registry(config, request_timeout_secs)

  The timeout is also now logged in each provider's tracing::debug! output. The other providers (NEAR AI,
  GitHub Copilot, Codex ChatGPT) already applied the timeout correctly — this was only a gap in the three
  rig-core adapter paths.

### Instrumentation

- Tool calling test checker

### Code Quality

- `cargo fmt` applied across crate to fix formatting from recent merges

## Documentation

## Known Issues

- **None**: nothing yet

## Upgrade Notes

1. **Database migrations**: two new migrations (V19, V20) will run automatically on startup. Back up your database before upgrading.

## Deferred to Future Releases

| Feature | Target |
|---------|--------|
| Lunartica/Multica bridge WASM tool | v1.1.0+ |
| LunarVoice (2-way audio input/output) | v1.1.0+ |
| Character Lorebooks / profile enhancements | v1.1.0+ |
| Proprietary channel removal (Discord, Slack, Telegram sources) | v1.1.0+ |
| XMPP OMEMO MUC fallback fix | v1.1.1 |
| Server-side WebSocket keepalive | v1.1.1 |
| New suite of planned features with concepts adopted from Hermes Agent which will be announced and documented at a later date | v1.1.2+ |

## Testing

*Testing to be completed before final release — see `docs/ops/PRE-RELEASE-TESTING.md` for the full checklist.*


