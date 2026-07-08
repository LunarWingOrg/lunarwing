# Testing Guide

### By Ruffles

**Pre‑Release Test Checklist** (run before every release)

---

## Production Release Checklist

### Pre‑Release Preparation

- [ ] Document the release scope (features, fixes, known issues) and success criteria
- [ ] Confirm stakeholder alignment (dev, ops, support) – a brief review meeting
- [ ] Verify all planned features/fixes are merged and built into the release candidate
- [ ] Validate that code freeze rules are respected (no unapproved commits post‑freeze)

### Environment & Configuration Consistency

- [ ] Run automated environment parity check (compare staging vs. production configs) – Ansible or custom script
- [ ] Test database migration rollback (reversibility) in staging
- [ ] Verify feature flags are correctly placed and default states are safe
- [ ] Confirm that all required services/containers start with the same versions as production

### Testing & Validation

The original functional smoke tests—now grouped under a dedicated section.

#### Multi-Tenant Setup Script

#### Channels

- [ ] **XMPP** – connect, send/receive 1:1, send/receive in MUC, verify no OMEMO fallback spam
- [ ] **WeeChat** – connect, send/receive messages, verify channel stability
- [ ] **Gotify** – send test push notification, confirm delivery

#### Routines

- [ ] **Cron routine** – create, verify fires on schedule, delete
- [ ] **Event‑driven routine** – create with`system_event` trigger, emit test event, verify fires
- [ ] **Manual routine** – create and fire manually via`routine_fire`
- [ ] **Lightweight routine with tools** – routine that calls at least one tool (e.g.`time`,`memory_write`)
- [ ] **Sandbox worker (full_job routine)** – routine that spawns a full autonomous job, verify completion

#### Workers

- [ ] **Nanocode external worker** – submit job, verify execution + completion signaling
- [ ] **Opencode external worker** – submit job, verify WebSocket protocol + completion signaling
- [ ] **Pebble external worker** – submit job, verify NDJSON event streaming + completion signaling
- [ ] **Docker sandbox worker** – submit job, verify execution + result return

#### Tools

- [ ] **GitHub integration** – list repos, list issues, verify auth works
- [ ] **Secret management** –`secret_list` shows expected secrets, no values leaked
- [ ] **Memory** –`memory_read`,`memory_write`,`memory_search` all functional
- [ ] **HTTP tool** – GET request to public endpoint, verify response
- [ ] **Time tool** – now, parse, convert, format, diff operations
- [ ] **Image tools** –`image_generate`,`image_analyze`,`image_edit` (if applicable)
- [ ] **Web search / LLM context** – query returns results

#### Core Features

- [ ] **REPL v2** – interactive session, verify input/output, tool calls from REPL
- [ ] **Job management** –`create_job`,`list_jobs`,`job_status`,`job_prompt`,`cancel_job`
- [ ] **Message tool** – send message to each active channel
- [ ] **Event emit** – emit system event, verify receipt by any listening routines
- [ ] **Skill management** –`skill_list`,`skill_search` return results

#### Database & Config

- [ ] **Database migration** – verify schema version matches expected, no migration errors on startup
- [ ] **Config loading** –`lunarwing.env` parsed correctly, all expected keys present
- [ ] **Web gateway** – starts, serves pages, API endpoints respond

### Security & Compliance

- [ ] Run automated security scan (dependency checks, container image vulnerabilities) – integrated in CI
- [ ] Confirm no secrets or API keys are exposed in logs or client‑facing code
- [ ] Verify that TLS certificates are valid and haven’t expired
- [ ] Check that RBAC/permissions are applied correctly (least privilege)

### Performance & Load Testing

- [ ] Execute a lightweight performance/load test against staging (throughput, latency, error rate)
- [ ] For message‑heavy components, verify that throughput and latency remain within acceptable limits
- [ ] Monitor resource usage (CPU, memory, disk) during load test – no unexpected spikes

### Rollback & Incident Response

- [ ] Test the rollback procedure in a staging environment (full revert and data restoration)
- [ ] Prepare a rollback plan with clear triggers (e.g., error rate > X%) and communication steps
- [ ] Verify that monitoring/alerting will fire if the release introduces errors
- [ ] Ensure the on‑call roster is updated and accessible for the release window

### Documentation & Release Notes

- [ ] Prepare release notes: new features, bug fixes, known issues, upgrade instructions
- [ ] Update internal runbooks or operational documentation if workflows changed
- [ ] Tag the release in version control and build artifacts

### Deployment Readiness

- [ ] Confirm all deployment artifacts are built, tested, and signed
- [ ] Verify CI/CD pipeline gates pass: tests, security scans, linting, production readiness score
- [ ] Schedule the deployment window and notify all stakeholders
- [ ] Freeze configuration changes in production until after post‑release validation

### Post‑Release Monitoring

- [ ] Define a post‑release validation checklist: monitor key metrics (latency, errors, throughput, job completions) for the first hour
- [ ] Establish a feedback loop – collect user feedback and urgent bug reports via a dedicated channel
- [ ] Run a quick production smoke test (subset of “Testing & Validation” items, read‑only if possible)
- [ ] Confirm all monitoring dashboards are healthy and sending alerts as expected

### Post‑Test Cleanup

- [ ] Delete any test routines created during testing
- [ ] Delete any test secrets created during testing
- [ ] Clear test jobs from job list
- [ ] Verify no orphaned processes or containers
- [ ] Re‑enable any feature flags that were temporarily adjusted for testing

---

**DevOps Automation Notes** – Many of these items can be automated using your existing toolchain:

- Environment parity checks → Ansible playbook in CI
- Security scans → integrated into Jenkins/GitLab CI with quality gates
- Performance/load tests → scripted with k6 or Locust, triggered automatically against staging
- Rollback testing → Docker Compose or Podman scripts to spin up a clean staging, then simulate rollback
- Production readiness scoring → adopt a Scorecard (e.g., Cortex) to enforce gates before deployment

## Created ic/scripts/release-test.sh. It automates the following from the testing guide:
 
  What it tests (16 checks with auth, 2 without):
  - Gateway health + status endpoint
  - Web gateway serving pages
  - Settings load + export
  - Memory tree, list, write, read, search
  - Routines list + summary
  - Jobs list + summary
  - Skills list + search
  - Extensions, tools, registry
  - Chat threads + message send (exercises time tool)
  - Gotify tool registration
  - Credential leak detection in settings export
  - Log level endpoint

  What it documents as NOT automated (top-of-file comment block, lines 14-60):
  - Pre-release process steps (human judgment)
  - XMPP channel (needs live bridge + OMEMO)
  - WeeChat channel (no test stub)
  - Sandbox/Docker workers (need Docker daemon + built images)
  - Nanocode worker (use its own smoke test)
  - GitHub integration (needs credentials)
  - Image/vision tools (needs LLM provider)
  - Web search (needs LLM backend)
  - REPL v2 (interactive)
  - Performance/load testing (needs k6/locust)
  - Rollback procedure (inherently manual)
  - Post-release monitoring (needs Grafana)
  - Documentation (human writing)

  Run it with:
  GATEWAY_URL=http://localhost:9098 GATEWAY_AUTH_TOKEN=yourtoken ./ic/scripts/release-test.sh

Treat this checklist as a living artifact—after each release, review what worked and where gaps appeared, then refine accordingly.
