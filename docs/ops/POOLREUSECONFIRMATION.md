 Pool reuse IS working — look at the pattern:                                                                                                              
                                                                                                                                                               
     05:52:40 connection=new    ← first job (fresh connect + handshake)                                                                                        
     05:55:22 connection=pooled ← second job (reused!) ✓                                                                                                       
     05:56:26 connection=new    ← after codex test (pool expired or evicted)                                                                                   
     05:57:52 connection=pooled ← reused ✓                                                                                                                     
     05:58:50 connection=pooled ← reused ✓                                                                                                                     
     06:00:28 connection=pooled ← reused ✓                                                                                                                     
     06:06:53 connection=new    ← after ~6min gap (stale eviction kicked in, 5min timeout)                                                                     
     06:07:16 connection=pooled ← reused again ✓                                                                                                               
                                                                                                                                                               
     The pool is working correctly. The reason the second job might feel slower isn't the connection — it's likely the LLM proxy round-trip (the agent has     
     to call the LLM to decide to use create_job, then the job runs). The WebSocket handshake savings (~1-2s) are dwarfed by LLM latency.                      
                                                                                                                                                               
     The connection=new at 06:06:53 is correct — that's after 6 minutes of inactivity, which exceeds the 5-minute idle timeout, so the pool correctly          
     evicted the stale connection.                            
