# LunarWing Deep Exploration — Findings & Suggestions

> Compiled by Kumogakure  
> Based on a thorough read of the v1.0.8-dev STAGING codebase on 2026-05-27.
> Written for sun and Baud.
>
> **Update 2026-07-09:** Several suggestions from this document have since been
> implemented in LunarWing:
> - **E-1 Human Delay / Approval Mode** → shipped as `--supervised` mode (v1.1.9).
> - **D-1 Self-Healing Infrastructure Watchdog** → shipped: auto-scheduled
>   infrastructure health-check + self-heal pipeline (host-level, as of v1.1.9).
> - **A-2 Outbound URL Allowlist** → partially addressed: the WASM sandbox proxy
>   already has `DomainAllowlist`; the built-in HTTP tool SSRF protections are
>   documented in `HTTP_TOOL_SSRF_PROTECTIONS.md`.
>
> The suggestions below remain valid as a roadmap document.

---

## What I Explored

| Area | Files Read | Depth |
|------|-----------|-------|
| WASM sandbox (WIT interfaces) | tool.wit, channel.wit | Full |
| Secrets management | mod.rs, store.rs, keychain.rs | Full |
| Safety layer | lib.rs, leak_detector.rs, credential_detect.rs | Full (600+ lines each) |
| Engine V2 architecture | ENGINE-V2.md, CLAUDE.md, scripting.rs | Deep |
| Skills system | lib.rs, v2.rs, types.rs | Moderate |
| Docker sandbox | container.rs, proxy/http.rs | Moderate |
| Network security | NETWORK_SECURITY.md | Full (550+ lines) |
| Infrastructure health-check | infrastructure-health-check.sh | Moderate |
| XMPP bridge | README.md, Cargo.toml | Light |
| Reflex compiler | reflex.rs | Full (earlier session) |

---

## Observations

### 1. LunarWing's Security is Already Exceptional

The codebase shows serious security engineering:

- **Secrets never touch WASM memory.** Secrets are stored AES-256-GCM encrypted, decrypted only at the host boundary, injected into HTTP requests after the WASM sandbox approves the call, and the response is scanned for leakage before the WASM sees it. This is a three-layer defense.
- **Leak detector uses Aho-Corasick + regex** with prefix-based fast-path elimination. 12+ credential patterns recognized across OpenAI, Anthropic, AWS, GitHub, Stripe, PEM, SSH, Google, Slack, Twilio. Block/redact/warn actions.
- **Safety layer wraps all external content** with XML structural boundaries and neutralizes closing-tag injection via zero-width space insertion. Round-trip safe — JSON survives wrap→unwrap intact.
- **Credential detection** in HTTP params is exhaustive: header names (exact + substring), header values (auth scheme prefixes), URL query params, URL userinfo. Adversarial tests cover ZWSP, RTL override, Turkish İ, ZWNJ, emoji, multibyte userinfo — with documented bypass vectors.
- **Network security document** catalogs every listener, its bind address, auth mechanism, known findings, and mitigations. This level of self-documentation is rare and commendable.

### 2. The V2 Engine is Ambitious and Worthwhile

The five-primitive model (Thread, Step, Capability, MemoryDoc, Project) collapsing ~10 v1 abstractions is the right direction. Key insights:

- **Learning missions** (error diagnosis, skill extraction, conversation insights) fire automatically after thread completion. This creates a feedback loop where the system improves itself over time.
- **CodeAct via Monty** follows the RLM pattern: thread context as Python variables (not LLM attention input), `llm_query()` for recursive subagent calls, `asyncio.gather()` for parallel tool dispatch. Compact output metadata instead of dumping full stdout into the attention window.
- **Data Retention: Never Delete LLM Output.** This philosophy — treating every thread message, step, and event as valuable data — is exactly right. The v1 cleanup (evicting caches, not deleting DB rows) is the correct approach.
- **ReliabilityTracker** (per-action EMA success rate and latency) — simple but powerful observability primitive.

### 3. Skills Have a Clear V1→V2 Migration Path

V1 skills (SKILL.md files with YAML frontmatter, Rust-side scoring, filesystem registry) are being migrated to V2:

- V2 skills are **MemoryDocs** with executable Python `CodeSnippets`
- Metrics track usage_count, success_count, failure_count → confidence score
- Skill extraction mission auto-creates skills from successful threads
- Trust model: Trusted (user-placed) vs Installed (external, read-only)

The v1 selector/gating/registry/catalog modules are explicitly marked for removal post-migration.

---

## Suggestions — What LunarWing Could Consider

### Category A: Security Hardening

#### A-1. Bridge-Side Pre-Command Threat Scanning (Tirith-style)

**Current state:** LunarWing has an excellent outbound leak detector and safety layer for tool outputs. It does NOT scan the *commands themselves* before execution for shell injection, homograph attacks, steganography, or data exfiltration patterns.

**What Hermes/Tirith offers:** Tirith is a Rust binary that scans every terminal command before execution across 80+ rules: homograph domain attacks (xn--), terminal escape injection, pipe-to-shell patterns (`| sh`, `| bash`), data exfiltration (base64 + curl piping), credential patterns in command args, code obfuscation, and steganography detection.

**Suggestion:** Add a pre-execution scan step inside the Monty executor and `EffectExecutor` that runs a fast deterministic check on action parameters before dispatching. Could be:
- A Rust crate pulled from the Tirith pattern library
- Integrated into the existing `PolicyEngine` in the capability layer as a new rule type
- Run on every `EffectExecutor::execute_action()` call — fast enough to add negligible latency

The key insight: LunarWing's leak detector protects *outbound data*. A command scanner would protect *execution paths*. These are complementary.

#### A-2. Outbound URL Allowlist for the Built-in HTTP Tool

**Current state:** The built-in `http` tool has excellent SSRF protections (HTTPS-only, localhost blocked, private IP blocked, DNS rebinding protection, metadata endpoint blocked, no redirects). But it does NOT have a **domain allowlist** — it allows any non-blocked destination.

**Suggestion:** Add an optional allowlist configuration (`HTTP_ALLOWED_DOMAINS`) that restricts the built-in HTTP tool to specific domains. The sandbox proxy already has this pattern (`DomainAllowlist` struct). Extending it to the built-in tool would provide defense-in-depth.

#### A-3. Credential Detection in Monty Code Blocks

**Current state:** The credential detector scans HTTP request params (`params_contain_manual_credentials`). It does not appear to scan Monty Python code blocks for embedded credentials.

**Suggestion:** Before executing Tier 1 Python code, scan the code string with `LeakDetector::scan()` for credential patterns. An LLM that accidentally (or maliciously) includes API keys in generated code would be caught before the code runs.

### Category B: Skills Ecosystem

#### B-1. Skills as Self-Improving Procedural Memory (Hermes model)

**Current state:** LunarWing's skill-extraction mission creates skills from successful threads. This is good but reactive.

**What Hermes does:** Hermes Skills are loaded at the start of every conversation. If a skill is used and proves insufficient (wrong commands, missing steps), the agent patches it immediately. Skills evolve continuously through real use.

**Suggestion:** Add a "skill patching" capability to the error-diagnosis learning mission. When a thread fails and the error traces back to an extracted skill, the mission should:
1. Diagnose what went wrong
2. Propose a patch to the skill's prompt or code snippet
3. Increment the skill version
4. Track patch history

This closes the loop from "skill extracted" → "skill used" → "skill failed" → "skill improved."

#### B-2. Skill Confidence-Based Demotion

**Current state:** `SkillMetrics` already tracks success/failure counts and computes confidence. But I didn't see where low-confidence skills get demoted or pruned.

**Suggestion:** Add a periodic mission (or on-skill-load check) that:
- Demotes skills with confidence below 0.3 to a "deprecated" trust level (no auto-activation)
- After N consecutive failures without any success, marks skills for deletion
- Notifies the user when skills are demoted or pruned

This prevents skill rot from accumulating bad patterns.

#### B-3. Cross-Agent Skill Sharing via a Registry

**Current state:** Skills are project-scoped (MemoryDocs in a project). There's no mechanism for one LunarWing instance to share skills with another.

**Suggestion:** Consider a `clawhub` registry (the catalog module already exists behind a feature flag) that allows:
- Publishing trusted skills
- Pulling community-vetted skills with a trust score
- Versioned skill updates

This would let the community of LunarWing users collectively build a skill library, similar to how Hermes Skills can be shared.

### Category C: Agent Orchestration & Multi-Agent

#### C-1. Kanban-Style Multi-Agent Task Board

**Current state:** LunarWing has ThreadTree for parent-child relationships and ThreadManager for spawn/stop/join. This is solid infrastructure. But there's no high-level task decomposition and parallel execution board.

**What Hermes offers:** Kanban orchestrator decomposes complex tasks into subtasks, spawns workers for each, tracks progress on a board, and handles dependency ordering. It has anti-temptation rules to prevent over-decomposition.

**Suggestion:** Build a mission that acts as a project-level orchestrator:
1. User says "build me X" → orchestrator mission decomposes into sub-threads
2. Spawns workers in parallel where dependencies allow
3. Tracks progress via ThreadTree + event sourcing
4. Reports status back to user

The infrastructure already exists (ThreadManager, ThreadTree, missions). This would be a new mission type that composes them.

#### C-2. Agent Profiles / Personalities

**Current state:** LunarWing has one agent personality.

**What Hermes offers:** 14 switchable personalities (different system prompts, behaviors, tones).

**Suggestion:** Add a `personality` field to `ThreadConfig` that loads different system prompt templates. Personalities could be:
- Default (balanced)
- Code-reviewer (pedantic, thorough)
- Architect (high-level, design-focused)
- Debugger (systematic root-cause analysis)
- Creative (brainstorming, ideation)

This is relatively low-cost to implement (just prompt templates) but adds significant user-facing value.

#### C-3. Thread Continuation / Session Persistence Across Restarts

**Current state:** Threads can be suspended and resumed. The Store trait persists everything to DB.

**Suggestion:** This is already largely built. Ensure that:
- Suspended threads survive process restart (rehydrate from DB on startup)
- A user returning hours later sees their thread exactly as they left it
- Long-running background threads auto-resume

Check that `ThreadManager` handles the "load from DB on startup" case — if not, it's a small addition with big UX impact.

### Category D: Infrastructure & Operations

#### D-1. Self-Healing Infrastructure Watchdog

**Current state:** The infrastructure health-check is a bash script that runs component checks and produces JSON. It is manual — you run it when something seems wrong.

**Suggestion:** Add an auto-remediation layer:
1. Health check runs on a cron (already has `cron-wrapper.sh`)
2. When a component is unhealthy, attempt restart (already has service management via systemd/OpenRC/launchd)
3. If restart fails N times, escalate to notification (already has `send-notification.sh`)
4. Log all remediation actions

The pieces are largely there — it needs orchestration.

#### D-2. Filesystem Checkpoints Before Risky Operations

**Current state:** LunarWing has workspace mounts for Docker sandboxes. There's no filesystem snapshot mechanism.

**What Hermes offers:** Checkpoints — filesystem rollback points before and after operations.

**Suggestion:** Before executing a high-risk thread (user explicitly marks it, or policy engine flags it), create a git commit or tar snapshot of the workspace. On failure, offer to roll back. This is especially valuable for code-modification agents.

#### D-3. Webhook Subscriptions for Event-Driven Agents

**Current state:** The HTTP webhook server receives external messages. Bridges connect external platforms.

**What Hermes offers:** Webhook subscriptions that trigger agent runs on external events.

**Suggestion:** Extend the webhook handler to support subscriptions:
- `POST /webhook/subscribe` — register a URL to be called when an event occurs
- `POST /webhook/unsubscribe` — remove subscription
- Thread completion, error diagnosis, and skill extraction events trigger webhook calls

This lets LunarWing integrate into CI/CD pipelines naturally.

### Category E: Developer Experience

#### E-1. Human Delay / Approval Mode

**Current state:** The Gate system handles pending/approval states. The built-in HTTP tool requires approval.

**What Hermes offers:** Human Delay Mode — the agent pauses before executing anything, giving the human time to review and intervene.

**Suggestion:** Add a thread-level "supervised mode" where:
- Every action is paused before execution
- User sees the proposed action and can approve/deny/modify
- Can be toggled per-thread or globally
- Useful for new users learning to trust the agent

The Gate infrastructure already supports approval flows — this would be a mode that gates *every* action.

#### E-2. Structured Plan Mode

**Current state:** Thread execution is immediate — the agent starts working as soon as a thread is created.

**Suggestion:** Add a "plan thread" type that:
1. Writes a markdown plan with file paths, edits, and task breakdown
2. Presents plan for human review
3. Only executes after explicit approval
4. Stores the plan as a MemoryDoc for post-execution comparison

This would be a ThreadType variant with the execution loop gated behind plan approval.

#### E-3. Spike / Throwaway Execution Mode

**Current state:** All thread execution is durable (never deletes data).

**Suggestion:** Add a "spike" ThreadType that:
- Creates a throwaway workspace (tmpdir or git worktree)
- Executes the thread in isolation
- Discards everything on completion unless the user explicitly saves
- Useful for "what if I tried this?" experiments

Simple to implement since the sandbox already supports workspace isolation.

### Category F: Architecture Observations

#### F-1. The Engine V2 Trait Boundary is Elegant

The three traits — `LlmBackend`, `Store`, `EffectExecutor` — create a clean seam between the engine and the host. This means:
- The engine can be tested with mock implementations
- The host can swap LLM providers, databases, or tool registries without touching engine code
- It's a natural API boundary for future multi-process architectures

**Suggestion:** Protect this boundary. Any feature that crosses it (new traits, new trait methods) should be scrutinized carefully. Three traits is a beautiful, small number.

#### F-2. The V1→V2 Migration Strategy is Smart but Needs a Kill Date

The codebase explicitly marks v1 modules for deletion (`// remove after migration`, `#[cfg(feature = "...")]`). This is good. But I didn't see a target date or checklist.

**Suggestion:** Create a `MIGRATION.md` document tracking:
- Which v1 modules are deleted
- Which remain (and why)
- Target completion date
- Blockers

Without this, v1 code tends to fossilize.

#### F-3. The Leak Detector Custom Pattern API is Under-Documented

`LeakDetector::add_pattern()` exists but there's no public API or CLI for users to add custom credential patterns. This is a power-user feature waiting to be exposed.

**Suggestion:** Add a CLI command (`lunarwing safety add-pattern <name> <regex>`) and persist custom patterns alongside secrets.

---

## Priority Matrix

| Suggestion | Impact | Effort | Priority |
|-----------|--------|--------|----------|
| A-1: Command scanning (Tirith-style) | High | Medium | ★★★ |
| B-1: Self-improving skills with patching | High | Medium | ★★★ |
| C-1: Kanban multi-agent task board | High | High | ★★ |
| D-1: Self-healing infrastructure watchdog | Medium | Low | ★★★ |
| E-1: Human delay / supervision mode | Medium | Low | ★★ |
| A-3: Credential scan in Monty code | Medium | Low | ★★★ |
| B-2: Skill confidence demotion | Medium | Low | ★★ |
| E-2: Structured plan mode | Medium | Medium | ★★ |
| C-2: Agent personalities | Low | Low | ★ |
| D-2: Filesystem checkpoints | Medium | Medium | ★★ |
| A-2: HTTP domain allowlist | Low | Low | ★ |
| B-3: Cross-agent skill sharing | High | High | ★ |
| C-3: Thread continuation across restart | Medium | Medium | ★★ |
| D-3: Webhook subscriptions | Medium | Medium | ★ |
| E-3: Spike/throwaway mode | Low | Low | ★ |
| F-1: Protect trait boundary | High | N/A (philosophy) | ★★★ |
| F-2: Migration kill-date document | Low | Low | ★ |
| F-3: CLI for custom leak patterns | Low | Low | ★ |

---

## Final Thoughts

LunarWing is *NOT* a toy. The security architecture alone — encrypted secrets, leak detection at sandbox boundaries, credential scanning in HTTP params, structural XML boundaries against prompt injection, adversarial Unicode tests — puts it in a different league from most agent frameworks.

# The V2 engine is the right bet. 
# Five primitives replacing ten.
# Learning missions creating feedback loops.
# CodeAct with Monty for Python-native agent reasoning.
# Never-delete data retention.

The gaps I see are mostly in the *operational* layer: command-level threat scanning (Tirith's domain), self-improving skills with patching feedback loops, multi-agent orchestration, and infrastructure self-healing. These are features, not architectural flaws.

If I were ranking what to build next:
1. **Command scanning** — closes the biggest remaining security gap
2. **Skill patching loop** — turns skill extraction from a one-shot into continuous improvement
3. **Self-healing infra watchdog** — low effort, high operational value

*salutes with a wing*

— Kumogakure

