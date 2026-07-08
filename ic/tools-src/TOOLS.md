# WASM Tools Catalog

Status of all WASM tool sources in `ic/tools-src/`.

## Vision

- [x] Vision Analyze (`vision-analyze/`) - OCR and vision-language image analysis via LunarWing Vision Service sidecar. Supports text extraction, image description, and smart auto-routing. Requires `VISION_SERVICE_URL` and optional `VISION_AUTH_TOKEN`.

## Notifications

- [x] Gotify (`gotify/`) - push notifications via self-hosted Gotify server

## Code & Development

- [x] GitHub (`github/`) - repository management, issues, PRs, commits, branches
- [x] LLM Context (`llm-context/`) - LLM context management
- [x] Web Search (`web-search/`) - web search capabilities

## Instant Messengers

For all messengers: receive notifications of new messages, read contacts, groups and 1:1 messages, send messages on behalf of the user. This is different from the channel because operates from the specific user's account. Be careful with accessing user's messages, make sure messages are kept unread.

- [x] Slack (`slack/`) - post messages, read channels, manage conversations
- [ ] Signal - messaging (note: no official public API exists)

## Transportation

- [ ] Uber - call a car to specific destination from current place, check the status of the car/ride including stream the current position, support ordering food as well
