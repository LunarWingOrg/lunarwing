# Testing Guide

### By Ruffles

**Pre‑Release Test Checklist** (run before every release)

### MT Admin

### Channels
- [ ] **XMPP** – connect, send/receive 1:1, send/receive in MUC, verify no OMEMO fallback spam  
- [ ] **WeeChat** – connect, send/receive messages, verify channel stability  
- [ ] **Gotify** – send test push notification, confirm delivery  

### Routines
- [ ] **Cron routine** – create, verify fires on schedule, delete  
- [ ] **Event‑driven routine** – create with `system_event` trigger, emit test event, verify fires  
- [ ] **Manual routine** – create and fire manually via `routine_fire`  
- [ ] **Lightweight routine with tools** – routine that calls at least one tool (e.g. `time`, `memory_write`)  
- [ ] **Sandbox worker (full_job routine)** – routine that spawns a full autonomous job, verify completion  

### Workers
- [ ] **Nanocode external worker** – submit job, verify execution + completion signaling  
- [ ] **Docker sandbox worker** – submit job, verify execution + result return  

### Tools
- [ ] **GitHub integration** – list repos, list issues, verify auth works  
- [ ] **Secret management** – `secret_list` shows expected secrets, no values leaked  
- [ ] **Memory** – `memory_read`, `memory_write`, `memory_search` all functional  
- [ ] **HTTP tool** – GET request to public endpoint, verify response  
- [ ] **Time tool** – now, parse, convert, format, diff operations  
- [ ] **Image tools** – `image_generate`, `image_analyze`, `image_edit` (if applicable)  
- [ ] **Web search / LLM context** – query returns results  

### Core Features
- [ ] **REPL v2** – interactive session, verify input/output, tool calls from REPL  
- [ ] **Job management** – `create_job`, `list_jobs`, `job_status`, `job_prompt`, `cancel_job`  
- [ ] **Message tool** – send message to each active channel  
- [ ] **Event emit** – emit system event, verify receipt by any listening routines  
- [ ] **Skill management** – `skill_list`, `skill_search` return results  

### Database & Config
- [ ] **Database migration** – verify schema version matches expected, no migration errors on startup  
- [ ] **Config loading** – `lunarwing.env` parsed correctly, all expected keys present  
- [ ] **Web gateway** – starts, serves pages, API endpoints respond  

### Post‑Test Cleanup
- [ ] Delete any test routines created during testing  
- [ ] Delete any test secrets created during testing  
- [ ] Clear test jobs from job list  
- [ ] Verify no orphaned processes or containers
