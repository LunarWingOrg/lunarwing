# V2 MCP and Extension Runtime Architecture Exploration

**Status:** Exploratory V2 architecture; host-local stdio installation surfaces
implemented as the first near-term step on 2026-07-09  
**Date:** 2026-07-09  
**Scope:** Possible V2 extension packaging, MCP compatibility, execution placement,
and tenant policy

## Executive Summary

LunarWing should not choose between "MCP over WASM," "MCP in a worker," and an
MCP gateway as if they were mutually exclusive extension models. They solve
different parts of the problem.

The stronger V2 direction is to define one signed, declarative extension package
and capability model, then support multiple runtime and placement options beneath
it. MCP would remain an important compatibility protocol, but it would not become
the native abstraction for every LunarWing extension.

The proposed conceptual split is:

| Layer | Responsibility |
| --- | --- |
| Package | Identity, publisher, version, artifacts, signatures, and updates |
| Policy | Requested capabilities, tenant grants, credentials, approvals, and limits |
| Runtime | WASM component, local process, dedicated worker, embedded module, or remote service |
| Protocol | Native LunarWing ABI, MCP, channel callbacks, webhooks, or worker protocol |

Under this model:

- Remote HTTP MCP remains appropriate for hosted integrations.
- Local stdio MCP can continue to run as a managed child process where host-local
  execution is acceptable.
- Worker-hosted MCP becomes an explicit placement for project-local, native,
  stateful, or computationally heavy servers.
- MCP-over-WASM becomes a compatibility runtime for portable MCP servers and for
  servers that need the broader MCP surface, not the default way to write a small
  LunarWing tool.
- Native WASM tools remain the preferred shape for narrow, capability-scoped tool
  integrations.
- Embedded modules remain exceptional and first-party.
- A gateway remains useful for shared OAuth, policy enforcement, remote sessions,
  auditing, and routing, without becoming the only place an MCP capability can run.

## Why This Is Worth Exploring

LunarWing already supports several extension and delegation mechanisms:

- Built-in Rust tools for tightly coupled runtime behavior.
- WASM tools with capability-scoped host functions.
- WASM channels with lifecycle callbacks and background polling behavior.
- MCP clients using HTTP, stdio, or Unix socket transports.
- Per-job Docker workers.
- Persistent external workers speaking `lunarwing-agent-v1`.

These mechanisms have grown around different needs. V2 is an opportunity to give
them a common package, policy, and lifecycle vocabulary without forcing them into
one execution technology.

The immediate motivation is local MCP deployment. Some MCP servers are distributed
as stdio programs rather than hosted HTTP services. Others need access to the job
workspace, native dependencies, durable state, or long-lived connections. A single
gateway or host-process model does not fit every case.

## Current Implementation Findings

### MCP already supports multiple local and remote transports

The core MCP configuration and CLI support:

- HTTP/HTTPS
- stdio child processes
- Unix domain sockets

`ic/src/tools/mcp/factory.rs` dispatches these configurations to the appropriate
transport. `McpProcessManager` owns stdio process startup, shutdown, and restart.
The application startup path loads enabled MCP configurations, discovers their
tools, wraps them as LunarWing `Tool` implementations, and registers them in the
main tool registry.

This means the broad finding in `docs/proposals/SUPERGATEWAY_MCP.md` that LunarWing
has no stdio MCP support is stale relative to the current source. The registry,
conversational `tool_install`, web API/settings, and registry CLI now accept
structured host-local stdio configuration. Installation persists the configuration
without running it; activation starts the managed child and discovers its tools.
A supergateway can still be operationally useful, but it is not required to
connect a stdio server.

### Worker containers do not currently load MCP extensions

The standard container worker creates a fresh `ToolRegistry` and calls
`register_container_tools()`. That path currently registers shell and file-editing
tools, but it does not load MCP configuration, construct MCP clients, or register
MCP tool wrappers.

The worker image already contains Node.js/npm, Python/pip, Rust, Git, and common
build dependencies. Many stdio MCP servers could physically run in the image, but
the worker runtime has no supported manifest/configuration path for them today.

Adding worker-local MCP therefore requires lifecycle and policy plumbing, not only
installing a package in the image.

### The current WASM tool ABI is intentionally invocation-scoped

The WASM tool runtime compiles components once and instantiates a fresh component
for each execution. Its WIT world exports one tool interface with schema,
description, and execute functions. Host capabilities cover HTTP, workspace reads,
tool invocation, secret existence checks, and related controlled operations.

This is a strong model for small tools, but it is not a general MCP server runtime.
MCP initialization, capability negotiation, resources, prompts, notifications,
cancellation, subscriptions, and session behavior would require a new server or
actor ABI.

The current implementation choice does not mean WASM is fundamentally incapable
of persistent behavior. The WASM channel subsystem already manages lifecycle
callbacks, polling tasks, runtime configuration, and persistent host-side state.
A stateful WASM MCP runtime is possible, but it would be a new runtime design rather
than a minor extension of `WasmToolWrapper`.

### Package integrity exists, but publisher authenticity is incomplete

The registry installer requires SHA-256 checksums for downloaded WASM artifacts
and validates supported artifact locations. This protects against corrupted or
unexpected bytes relative to a trusted manifest.

It does not by itself establish who published the extension, whether that
publisher remains trusted, or whether a compromised registry entry should be
revoked. A V2 marketplace needs package signatures and publisher trust metadata in
addition to checksums.

### The WASM security model is promising but not fully unified

The WASM tool runtime has strong machinery for capability checks, resource limits,
host-bound credential injection, output leak detection, and restricted WASI
contexts. However, tools and channels have separate runtime and host-function
implementations, and known security-parity work remains between their HTTP and
leak-handling paths.

V2 should first extract and unify the common security boundary rather than add a
third independently implemented WASM extension type.

## Design Principle: Separate Package, Policy, Runtime, and Protocol

The central proposal is a runtime-neutral extension descriptor. A conceptual
manifest could express:

```yaml
schema_version: 2
package:
  id: com.example.repository-tools
  version: 1.4.0
  publisher: example

exports:
  - kind: tools
  - kind: resources

runtime:
  type: wasm
  protocol: lunarwing-native
  artifact: repository-tools.wasm

placement:
  allowed:
    - orchestrator
    - job-worker
  preferred: job-worker

capabilities:
  network:
    hosts:
      - api.example.com
  workspace:
    read:
      - project/**
  credentials:
    - name: example_token
      inject:
        host: api.example.com
        header: Authorization

limits:
  memory_mb: 128
  timeout_seconds: 30

provenance:
  digest: sha256:...
  signature: ed25519:...
  publisher_key: example-2026
```

This is illustrative, not a proposed final schema. The important point is that
runtime and protocol are explicit fields instead of being inferred from the
extension kind.

The host should derive an internal capability graph from installed package
descriptors and tenant grants. Users and operators should not need to author a
literal graph for ordinary installation.

## Alternatives Evaluated

### 1. Embedded MCP modules

In this model, an integration is compiled directly into the LunarWing binary and
exposes an MCP-compatible server interface internally.

**Advantages**

- Lowest invocation overhead.
- Straightforward access to internal Rust APIs.
- No process, network, or serialization boundary is required internally.
- Suitable for foundational first-party capabilities that must ship with the
  daemon.

**Costs and risks**

- Expands the trusted computing base.
- Couples extension release cadence to LunarWing releases.
- Increases binary size and feature-flag combinations.
- A crash, memory error, or dependency conflict affects the daemon.
- Third-party code would require the highest trust level.

**Assessment**

Keep this option for first-party, tightly coupled integrations. Do not make it a
general marketplace runtime.

### 2. Native WASM tools

In this model, extensions implement LunarWing's native tool ABI and use declared
host capabilities.

**Advantages**

- Small and explicit attack surface.
- Good resource isolation and deterministic invocation lifecycle.
- Existing installation, capability, auth, activation, and removal machinery.
- No MCP protocol overhead for integrations that only expose tools.
- Strong fit for portable, stateless, request/response integrations.

**Costs and risks**

- Current ABI exports one tool per component shape rather than a complete MCP
  server surface.
- Native dependencies and unsupported language/runtime assumptions can block
  portability.
- Invocation-scoped instances require explicit host storage for durable state.
- Tool and channel security primitives need consolidation.

**Assessment**

This should remain the preferred native format for small, capability-scoped tools.
It should not be renamed or wrapped as MCP merely for conceptual uniformity.

### 3. MCP-over-WASM

In this model, a WASM component implements an MCP server interface and the host
adapts messages to the component without requiring an operating-system process or
TCP listener.

There are two possible versions of this idea:

1. A compatibility runtime that hosts an existing portable MCP implementation.
2. A new LunarWing-specific MCP server WIT ABI that extension authors target.

The first preserves ecosystem compatibility. The second risks duplicating the
native WASM tool ABI while also inheriting MCP lifecycle complexity.

**Advantages**

- Sandboxes MCP server logic using the existing Wasmtime foundation.
- Avoids stdio process management and port allocation.
- Could expose tools, resources, prompts, and notifications through one protocol.
- Allows the same packaged server to be used by LunarWing and, potentially, other
  MCP clients through a host-provided transport adapter.

**Costs and risks**

- Requires MCP initialization, capability negotiation, cancellation, notification,
  and session semantics.
- Requires a persistent actor/session design or explicit state externalization.
- Existing Node/Python stdio servers cannot be moved into WASM automatically.
- A LunarWing-specific WIT mapping may become another compatibility surface to
  maintain alongside the MCP specification.
- Long-lived streaming and subscription behavior need bounded resource ownership.

**Assessment**

Treat MCP-over-WASM as an optional compatibility runtime. Build it only when
specific extensions need resources, prompts, notifications, portable MCP reuse, or
cross-client serving. Do not require simple WASM tools to implement MCP.

### 4. MCP inside a per-job worker container

In this model, the job worker starts one or more approved MCP servers inside the
same container and registers their tools in the worker's local tool registry.

**Advantages**

- MCP server shares the job's `/workspace` view and toolchain.
- Arbitrary server code remains inside the worker sandbox rather than running on
  the host.
- Strong fit for repository inspection, code generation, and project-local tools.
- Existing worker images already include runtimes used by many MCP packages.
- Server lifetime naturally follows the job when isolation is more important than
  reuse.

**Costs and risks**

- Repeated startup and package initialization for every job.
- Runtime package installation introduces network dependence and version drift.
- Credentials granted to the job may become visible to the MCP child process.
- MCP process failures need to be distinguished from worker failures.
- The worker protocol must receive approved package descriptors and grants.

**Assessment**

Useful as explicit `job-worker` placement for workspace-coupled MCP servers. Prefer
prebuilt worker images or verified extension bundles over installing arbitrary npm
or Python packages during a job.

### 5. MCP inside a persistent external worker

In this model, a dedicated worker owns one or more MCP servers and exposes selected
capabilities to LunarWing through `lunarwing-agent-v1`, MCP, or a future extension
runtime protocol.

**Advantages**

- Supports native libraries, GPUs, language runtimes, and heavyweight services.
- Amortizes startup cost and preserves connection pools or caches.
- Suitable for durable state, long-lived subscriptions, and streaming APIs.
- Keeps complex code outside the main daemon.
- Can be scaled and load-balanced independently.

**Costs and risks**

- Larger operational footprint than WASM or a local subprocess.
- Requires health checks, supervision, version negotiation, and secure networking.
- Tenant and credential isolation must be explicit in a shared worker.
- The boundary between worker-native tools and MCP-provided tools can become
  confusing without consistent package metadata.

**Assessment**

This is a valid placement, not merely a fallback for failed WASM ports. It is the
preferred option for stateful, heavy, native, or independently scalable servers.

### 6. Dedicated MCP gateway

In this model, a gateway manages connections to multiple local or remote MCP
servers and presents one controlled endpoint to LunarWing.

**Advantages**

- Central OAuth, token refresh, auditing, routing, and rate limiting.
- Shared sessions and process reuse across daemon instances or tenants.
- Protocol adaptation can be isolated from the core daemon.
- Clear network and policy enforcement point for hosted MCP services.
- Can hide transport differences from LunarWing.

**Costs and risks**

- Additional service to deploy and monitor.
- Can become a bottleneck or single failure domain.
- Project-local filesystem access becomes difficult or unsafe.
- A gateway with broad credentials and tenant access is a high-value target.
- It does not remove the need for package provenance or capability policy.

**Assessment**

Retain this as a deployment and control-plane option. It is particularly strong for
hosted HTTP MCP and shared authentication, but should not be the mandatory path for
workspace-local or dedicated-worker capabilities.

### 7. Signed extension marketplace

This idea applies across all runtimes rather than competing with them.

**Required properties**

- Stable package identity and semantic version.
- Publisher key identity and signature.
- Artifact digests for every supported runtime target.
- Declared capabilities and credential injection rules.
- Supported LunarWing ABI/protocol versions.
- Runtime and placement requirements.
- Dependency declarations and conflict rules.
- Revocation and compromised-key handling.
- Reproducible or attestable builds where practical.
- Upgrade policy with capability-diff review.

**Assessment**

This is the strongest long-term idea in the set. It should be designed independently
of which execution runtimes ship first.

### 8. Declarative capability graph

A capability graph could represent:

- Packages and their exported tools/resources/prompts/channels.
- Runtime dependencies.
- Delegation edges such as tool-to-tool invocation.
- Credential and network grants.
- Tenant subscriptions and denials.
- Placement constraints.
- Approval requirements.

The graph is valuable for policy evaluation, conflict detection, planning, audit
visualization, and determining what an agent may see in a given turn.

It would be burdensome as the normal user-authored installation format. The better
approach is to derive it from manifests, tenant grants, and active runtime state.

## Recommended V2 Shape

### One package model

All installable extensions should use one top-level package vocabulary, even if the
payload is a WASM component, process declaration, worker image, or remote endpoint.
The current distinction between MCP URL manifests and downloadable WASM artifacts
should become a runtime choice inside a broader package descriptor.

### Two protocol categories

1. **LunarWing-native:** Narrow ABIs optimized for direct tool, channel, hook, or
   future resource behavior.
2. **Compatibility protocols:** MCP and other external protocols implemented by
   adapters.

Native protocols should be used when LunarWing owns both sides and a smaller
contract improves safety or performance. MCP should be used when ecosystem
compatibility, broader primitives, or external client interoperability matters.

### Multiple explicit placements

At minimum, V2 should distinguish:

- `orchestrator`: Executes in or adjacent to the daemon.
- `job-worker`: Executes inside an isolated job container with project-local access.
- `dedicated-worker`: Executes in a persistent independently supervised service.
- `remote`: Executes at a hosted network endpoint.

Placement must affect credential grants, workspace visibility, network policy,
resource limits, and lifecycle ownership. It cannot be a cosmetic deployment hint.

### Derived tenant capability views

Each tenant should receive a derived view of active exports after evaluating:

- Installed package versions.
- Tenant subscriptions.
- Explicit operator grants and denials.
- Runtime health.
- Authentication state.
- Placement availability.
- Per-session or per-job approvals.

The LLM should only see tool definitions from this evaluated view. Installing a
package must not automatically grant all tenants or all execution placements access.

## Conceptual Runtime Selection

| Requirement | Preferred runtime/placement |
| --- | --- |
| Small stateless API integration | Native WASM tool |
| Existing hosted MCP endpoint | Remote HTTP MCP, optionally through gateway |
| Existing local stdio MCP trusted on host | Managed local process |
| MCP requiring job workspace | MCP in job worker |
| Native dependencies or language runtime | Job worker or dedicated worker |
| Durable state or long-lived subscriptions | Dedicated worker or gateway |
| GPU or heavy compute | Dedicated worker |
| Full MCP resources/prompts/notifications in portable sandbox | MCP-over-WASM |
| Core first-party runtime integration | Embedded Rust module |

This table should guide defaults, not impose hard prohibitions. Manifests and policy
must still constrain which placements are permitted.

## Security Considerations

### Treat every local MCP server as installed code

MCP servers can access data and execute actions. A stdio command is not safer merely
because it communicates over JSON-RPC. Host-local and worker-local servers must be
subject to package trust, capability review, and credential scoping.

### Keep raw credentials at the narrowest possible boundary

The preferred pattern is host-side credential injection into an allowed outbound
request. When a process or worker must receive a raw credential, the package should
declare that requirement explicitly and the UI should distinguish it from boundary
injection.

### Capability claims are requests, not facts

A package manifest is authored by a potentially untrusted publisher. The host must
validate and enforce capabilities. MCP tool annotations may inform approval policy,
but they must not override operator policy or package trust.

### Signing does not replace sandboxing

A valid signature identifies the publisher and protects package integrity. It does
not prove that code is safe. Publisher trust, capability minimization, sandboxing,
runtime limits, audit events, and revocation all remain necessary.

### Placement changes the threat model

- Orchestrator-local execution risks the daemon and host.
- Job-worker execution risks the mounted project and granted job credentials.
- Dedicated workers risk shared state and cross-tenant isolation.
- Remote services receive whatever data is sent over the network.
- Gateways concentrate credentials and policy authority.

The package manager should show a placement-specific risk summary before activation.

## Lifecycle Considerations

The package lifecycle should remain consistent even when runtime behavior differs:

1. Discover package metadata.
2. Verify publisher and artifact provenance.
3. Review requested capabilities and placements.
4. Install immutable package version.
5. Configure non-secret settings.
6. Authenticate or provision credentials.
7. Activate for selected tenant scopes and placements.
8. Perform runtime health and protocol negotiation.
9. Expose the evaluated capability view.
10. Upgrade with artifact and capability diff review.
11. Deactivate, revoke grants, stop runtime resources, and remove.

Runtime adapters would own their specific resources:

- Process adapter: child lifecycle, stdio framing, restart, and shutdown.
- WASM adapter: compile cache, instances/actors, fuel, memory, and host functions.
- Worker adapter: image/package availability, task routing, health, and cancellation.
- Remote adapter: sessions, OAuth, HTTP policy, and retries.
- Gateway adapter: endpoint registration, tenant routing, and shared session policy.

## Suggested Exploration Sequence

The host-local installation work below was selected as an immediate improvement.
If broader V2 work proceeds, the least-regret order is:

### Phase 0: Host-local stdio installation surfaces (completed)

- Add typed stdio MCP registry manifests.
- Route registry, chat, API, and web installation through validated
  `McpServerConfig` persistence.
- Keep activation explicit and use the existing `McpProcessManager` lifecycle.
- Expose transport and command metadata in installed-extension responses.
- Do not add runtime package downloads or worker placement in this phase.

### Phase 1: Package and policy vocabulary

- Define runtime-neutral package identity, exports, capabilities, placement, and
  provenance.
- Define capability-diff behavior for upgrades.
- Define tenant grant and activation semantics.
- Decide signature trust roots and revocation behavior.

This phase can be designed without implementing new runtimes.

### Phase 2: Runtime adapter boundary

- Extract a common extension-runtime lifecycle interface.
- Preserve current WASM, MCP, and extension behavior behind adapters.
- Unify common network, credentials, leak detection, rate limiting, and audit
  primitives used by WASM tools and channels.

### Phase 3: Worker-local MCP prototype

- Pass an allowlisted, resolved MCP runtime descriptor to a job worker.
- Start only preinstalled or verified server packages.
- Register discovered MCP tools in the worker-local registry.
- Scope workspace and credentials to the job.
- Measure startup time, failure isolation, and teardown reliability.

This is likely the fastest prototype for validating placement-aware extensions.

### Phase 4: Marketplace provenance

- Add publisher signatures and package trust state.
- Add capability review and upgrade diffs.
- Add revocation and compromised publisher handling.
- Extend artifacts beyond the current WASM-only package shape.

### Phase 5: MCP-over-WASM feasibility prototype

Only begin this phase with concrete target servers or protocol features. The
prototype should test:

- MCP initialization and capability negotiation.
- Multiple tools plus resources or prompts.
- Notifications and cancellation.
- Session state ownership.
- Long-running operation limits.
- Compatibility with a non-LunarWing MCP client.

If the prototype only reproduces ordinary tool calls, native WASM tools remain the
better implementation.

## Non-Goals

- Replacing existing HTTP MCP support.
- Requiring all extensions to speak MCP.
- Moving every built-in Rust tool into an extension runtime.
- Allowing arbitrary runtime package installation during a job by default.
- Treating package signatures as proof of safety.
- Designing the final V2 manifest schema in this exploratory note.
- Committing to a gateway, worker, or WASM runtime before workload evidence exists.

## Open Questions

1. Should extension packages be globally installed and tenant-activated, or should
   package installation itself be tenant-scoped?
2. Which authority signs first-party and community packages, and how are publisher
   keys rotated or revoked?
3. Should a package contain multiple runtime artifacts with placement fallback, or
   should each runtime be a separate package variant?
4. Can tenant policy override a package's preferred placement while remaining within
   its declared allowed placements?
5. Which MCP primitives beyond tools are real LunarWing V2 requirements: resources,
   prompts, subscriptions, sampling, elicitation, or all of them?
6. Should worker-local MCP servers be available only to the worker agent, or can the
   orchestrator proxy selected tools into the primary agent session?
7. How should package-defined tools retain stable identity across runtime changes and
   upgrades?
8. What state API should invocation-scoped WASM tools and persistent WASM actors use?
9. What audit events are required for package install, grant, activation, credential
   access, placement selection, tool invocation, upgrade, and revocation?
10. Which security primitives must be unified between WASM tools and channels before
    another WASM runtime type is acceptable?

## Evidence Needed Before a Decision

A V2 decision should be based on representative workloads rather than protocol
elegance alone. Useful prototypes and measurements include:

- Startup and memory cost for representative Node, Python, Rust, and WASM servers.
- Failure and cleanup behavior for crashed stdio servers in host and worker modes.
- Credential exposure comparison across host injection, process env, worker grants,
  and gateway forwarding.
- Session and notification requirements from real MCP servers under consideration.
- Cross-tenant isolation tests for persistent workers and gateways.
- Capability review usability for operators during install and upgrade.
- Compatibility tests across current and future MCP protocol versions.

## Preliminary Recommendation

Proceed with the runtime-neutral package and policy model as the V2 architectural
center. Preserve existing MCP transports and treat MCP as a compatibility protocol.
Use native WASM tools for small integrations, worker placement for workspace-local
or native servers, dedicated workers for stateful/heavy services, and gateways for
shared remote control-plane concerns.

The immediate host-local stdio installation work is complete. Worker-local MCP is
the next placement option to evaluate when a concrete workspace-coupled server
justifies the additional lifecycle and credential-policy plumbing.

Defer MCP-over-WASM until a concrete server or required MCP primitive justifies the
new actor/session ABI. Defer general embedded extensions indefinitely; reserve them
for first-party capabilities whose coupling to the daemon is intentional.

## Relevant Source and Proposal References

- `ic/src/tools/mcp/config.rs`
- `ic/src/tools/mcp/factory.rs`
- `ic/src/tools/mcp/process.rs`
- `ic/src/app.rs`
- `ic/src/worker/container.rs`
- `ic/src/tools/registry.rs`
- `ic/Dockerfile.worker`
- `ic/src/tools/wasm/runtime.rs`
- `ic/src/tools/wasm/wrapper.rs`
- `ic/wit/tool.wit`
- `ic/src/channels/wasm/`
- `ic/src/registry/manifest.rs`
- `ic/src/registry/installer.rs`
- `ic/src/orchestrator/external_worker.rs`
- `docs/proposals/SUPERGATEWAY_MCP.md`
- `docs/proposals/EXTERNAL-WORKER-PLAN-UPGRADES.md`
