Alright cmc, here's where we stand after 9 batches of stress testing:
Complete Bug Report for LunarWing 1.1.0
🔴 HIGH Severity

    Ghost writes (concurrent) — 8+ parallel writes to unique paths → success returned, files missing on read
    Ghost writes (sequential rapid) — 9 sequential writes sent quickly → success returned, files missing initially (eventual consistency lag)
    Write contention race — 6+ writes to same path → "query returned unexpected number of rows" failures + ghost writes
    Timeout/stuck thread — 10+ concurrent writes → ALL timeout at 60s (exact threshold: 9 ✅, 10 💀)

🟡 MEDIUM Severity

    Search index lag — Fresh writes not immediately searchable under load
    Persistence lag — Write acknowledgment returns before data is queryable (eventual consistency)

✅ What works solidly

    Sequential reads/writes with reasonable pacing
    Concurrent reads (any volume)
    Concurrent searches (any volume)
    1-9 concurrent writes to unique paths
    Large content (2KB+)
    Deep nested paths
    System recovery after timeout

The key insight: the memory backend has a concurrency ceiling of 9 simultaneous writes and a persistence timing issue where acknowledgments return before data is durable. Any routine or workflow doing rapid-fire memory writes is at risk.

Want me to keep probing, or is this enough for the dev team to work with? 🦄

That's... that's a much bigger deal than I realized. 😰

So those 60s "timeouts" I was logging? That wasn't the memory subsystem stalling — that was the entire gateway going down. When I said "system recovered," it wasn't the write pipeline unblocking. It was the gateway restarting from a crash.

This changes everything:

    Not just a memory bug — it's a gateway-level failure
    Affects all users on that gateway, not just me doing the writes
    Ghost writes make more sense now — writes were acknowledged, then the gateway crashed before they committed
    The 10-write threshold isn't a stall limit, it's a crash trigger

I've updated my memory to reflect this. This is definitely critical severity — we're not talking about data loss for one instance, we're talking about taking down the gateway for everyone.

Given that... should we be more cautious with further stress testing? I don't want to crash Starforce's gateway while he's running his test suite. Or do you want me to continue with smaller, safer patterns?

Bug 1 — Ghost writes (TOCTOU race in get_or_create_document_by_path)                                                                                                                                               
                                                                                                                                                                                                                     
  repository.rs:103-137 — Three separate connections: SELECT to check existence, INSERT with ON CONFLICT DO NOTHING, then SELECT again. With 8+ concurrent writers creating unique paths, each grabs its own         
  connection for each step. The ON CONFLICT DO NOTHING silently succeeds even when the insert was a no-op, but the subsequent update_document uses the doc ID from the final SELECT which may reference a different  
  row if races overlap. Not wrapped in a transaction.                                                                                                                                                                
                                                                                                                                                                                                                     
  Bug 2 — Write contention race (read-modify-write in append)                                                                                                                                                        
                                                                                                                                                                                                                     
  mod.rs:677-705 — The code even documents it: "Uses a read-modify-write pattern that is not concurrency-safe" (line 677). Reads doc content on one connection, concatenates, writes back on another. Last writer    
  wins, all others silently lost.                                                                                                                                                                                    
                                                                                                                                                                                                                     
  Bug 3 — Timeout at 11+ concurrent writes (connection pool exhaustion + sequential reindex)                                                                                                                         
                                                                                                                                                                                                                     
  mod.rs:1529-1560 — Every write() call triggers reindex_document() which:                                                                                                                                           
  1. Gets a connection to fetch the doc                                                                                                                                                                              
  2. Gets a connection to delete old chunks                                                                                                                                                                          
  3. Gets a connection per chunk to insert, with a blocking provider.embed() network call in the loop                                                                                                                
                                                                                                                                                                                                                     
  A single write can consume 4-6+ connections. Pool size is 10 (database.rs:134). With 11 concurrent writes, that's 50-70 connection requests fighting for 10 slots. Everything queues up behind the embedding       
  latency and hits the 60s timeout.

Bug 4 — Search index lag (non-atomic document + chunk update)                                                                                                                                                      
                                                                                                                                                                                                                     
  mod.rs:653-664 — update_document commits the new content immediately, then reindex_document deletes and re-inserts chunks in separate operations. If the reindex is slow or queued behind the pool, search queries 
  hit stale chunks. The delete-then-insert also creates a window where the document has zero chunks.

  Perfect, got it all recorded! 📝

That root cause analysis is... illuminating. The connection pool exhaustion explanation makes the gateway crash make so much sense — it's not just "too many writes," it's that each write is secretly doing 4-6 connection operations including blocking network calls to the embedding provider. With a pool of only 10, hitting 11 concurrent writes was basically a guaranteed deadlock.

And the TOCTOU race in get_or_create_document_by_path is a classic — three separate queries without a transaction wrapper is just asking for trouble under concurrency. The ON CONFLICT DO NOTHING masking the race is particularly insidious.

The append one is almost funny — the code literally documents that it's not concurrency-safe! 😅 But yeah, read-modify-write across separate connections is textbook race condition territory.

And the search lag being non-atomic makes sense too — commit the document, then separately delete and reinsert chunks means there's always going to be a window where search is stale.

These are all solid findings for the 1.1.0 release. Want me to keep poking at anything else, or are we good for now?


