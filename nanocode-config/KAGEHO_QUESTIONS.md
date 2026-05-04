2026-04-24 20:07:06     kageho  ```markdown                                                                                                                                                                          
# Agnostic Coding Worker Design                                                                                                                                                                                      
                                                                                                                                                                                                                     
## Overview                                                                                                                                                                                                          
                                                                                                                                                                                                                     
A vendor-neutral coding-tool worker container that can run multiple backends (nanocode, opencode, Claude Code, aider, etc.) without rebuilding the pipeline.                                                         
                                                                                                                                                                                                                     
---                                                                                                                                                                                                                  
                                                                                                                                                                                                                     
## 1) One container image, multiple backends                                                                                                                                                                         
                                                                                                                                                                                                                     
**Base tools (always present):**                                                                                                                                                                                     
- `git`, `ripgrep`, `jq`, `patch`, `python3`, `node` (if nanocode/opencode need it)                                                                                                                                  
2026-04-24 20:07:06     kageho  - Optional: `go`, `rust` depending on backend requirements                                                                                                                           
                                                                                                                                                                                                                     
**Entry command chooses backend by env var:**                                                                                                                                                                        
- `WORKER_TOOL=nanocode|opencode|claude_code|aider`                                                                                                                                                                  
- `WORKER_ARGS=...` or a JSON config file                                                                                                                                                                            
                                                                                                                                                                                                                     
---                                                                                                                                                                                                                  
                                                                                                                                                                                                                     
## 2) Standardized secret injection                                                                                                                                                                                  
                                                                                                                                                                                                                     
Use IronClaw’s native approach:                                                                                                                                                                                      
- Vault secret name → env var inside container via `credentials`                                                                                                                                                     
- Worker reads:                                                                                                                                                                                                      
  - `OPENAI_API_KEY` (or whatever nanocode uses)                                                                                                                                                                     
2026-04-24 20:07:06     kageho  - Possibly `ANTHROPIC_API_KEY`, `GITHUB_TOKEN`, etc.                                                                                                                                 
                                                                                                                                                                                                                     
**No bridge needed** if the job is launched by the correct daemon (secret exists in that daemon’s vault).                                                                                                            
                                                                                                                                                                                                                     
---                                                                                                                                                                                                                  
                                                                                                                                                                                                                     
## 3) Standard input/output contract                                                                                                                                                                                 
                                                                                                                                                                                                                     
Make the worker behave predictably:                                                                                                                                                                                  
                                                                                                                                                                                                                     
**Inputs:**                                                                                                                                                                                                          
- Mounted project directory                                                                                                                                                                                          
- Prompt text (env var or file, e.g. `/workspace/prompt.txt`)                                                                                                                                                        
                                                                                                                                                                                                                     
**Outputs:**                                                                                                                                                                                                         
- Writes a patch to `/workspace/out/changes.patch`                                                                                                                                                                   
2026-04-24 20:07:07     kageho  - Writes a short report to `/workspace/out/report.md`                                                                                                                                
                                                                                                                                                                                                                     
This makes it easy to automate review/apply steps downstream.                                                                                                                                                        
                                                                                                                                                                                                                     
---                                                                                                                                                                                                                  
                                                                                                                                                                                                                     
## 4) Open questions to finalize       
1) **How do you run nanocode today?**
   - Command line example (even approximate)

2) **What does it require?**
   - Node? Python? A single binary?

3) **What auth does it expect?**
   - `OPENAI_API_KEY`? Something else?

2026-04-24 20:07:08     kageho  4) **Apply changes automatically, or emit patch only?**
   - Auto-apply: riskier but faster
   - Patch-only: safer, requires review step

---

## 5) Deliverables (once questions answered)

- Clean `Dockerfile`
- `entrypoint.sh` that routes to the selected backend 
- Minimal "job recipe" JSON for IronClaw `create_job` 
- README runbook (shareable with Ruffles/Starforce)

---

2026-04-24 20:07:09     kageho  *This file serves as the design spec for the agnostic coding worker.*
```

</final>
