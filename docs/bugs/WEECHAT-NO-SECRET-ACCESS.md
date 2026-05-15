Answers from the code                                                                                                                                                                            
                                                                                                                                                                                                   
  Q: Is the IRC-facing agent the same process or a separate daemon?                                                                                                                                

  It's the same process. A single LunarWing daemon runs multiple channels simultaneously. The ChannelsConfig (ic/src/config/channels.rs:14) holds CLI, HTTP, gateway, XMPP, and WASM
  channels all at once. WASM channels (like WeeChat) are loaded from a directory (~/.lunarwing/channels/ by default, or WASM_CHANNELS_DIR), and the ChannelManager merges all their message streams
   into one. There is no separate daemon for IRC — the WeeChat WASM channel is loaded into the same process that also runs the CLI/REPL.
 
  Q: Where does it live on disk?                                                                  

  It's the same binary. The WeeChat WASM channel is a .wasm file in the wasm_channels_dir. The ws_adapter.py is a separate Python process that holds the WebSocket to WeeChat, but it's just a
  proxy — it doesn't run an agent. The architecture is:

  ws_adapter.py (Python, WebSocket to WeeChat) ←→ HTTP on 127.0.0.1:6681
       ↑                                                                                          
       polls
       ↑                                                                                          
  WeeChat WASM channel (inside the LunarWing daemon)
       ↑                                                                                          
       same process
       ↑                                                                                          
  Agent loop, tools, secrets store, etc.

  Q: Does the IRC-facing agent have brave_api_key?                                                

  Yes, if it's the same daemon — but here's the catch. Secrets are scoped by owner_id and LUNARWING_BASE_DIR. If Kageho's unix_socket_repl and the WeeChat channel run in the same daemon instance
  (same LUNARWING_BASE_DIR), they share the same secrets store, and brave_api_key is available to the web_search WASM tool regardless of which channel triggered the conversation.

  The credential flow for WASM tools (ic/src/tools/wasm/credential_injector.rs) works at the HTTP-request level: when the web_search tool makes a request to api.search.brave.com, the host
  intercepts it and injects brave_api_key as the X-Subscription-Token header. The WASM tool itself calls near::agent::host::secret_exists("brave_api_key") to check availability
  (ic/src/tools/wasm/host.rs:242), and the host resolves it from the shared secrets store.        
 
  The likely problem scenario: If someone set up a separate instance (different LUNARWING_BASE_DIR, different DB) to handle IRC traffic, that instance would have its own secrets store — and
  brave_api_key wouldn't be there unless explicitly added. This is the most probable explanation for "it works on Kageho's REPL but not on IRC."

  For Ruffles (LunarWing 1.0.4): The exact same architecture applies. Nothing in the fork changes how secrets are scoped or how WASM tools get credentials. If Ruffles runs a single daemon with
  both REPL and WeeChat channels enabled, brave_api_key will work for both. If it's split into separate instances, the second instance needs its own lunarwing secret set brave_api_key <key>.

  That's a much more interesting bug. If secrets don't work through WeeChat even on the same daemon, the issue is in the execution path — something about how WASM channel-originated messages flow
   through tool execution loses the credential context. Let me trace that path.

  Searched for 2 patterns, read 1 file (ctrl+o to expand)                                         

● Found it. Line 1108 is the key: let credential_user_id = ctx.user_id.clone();. The credential resolution uses ctx.user_id, which comes from the channel. Let me check what user_id WeeChat
  messages produce vs REPL.                                                                       

  Searched for 1 pattern, read 2 files (ctrl+o to expand)

● Now let me see how user_id gets set in the JobContext for messages from different channels — specifically what the WeeChat channel emits vs. what the REPL/CLI sets.

  Searched for 1 pattern, read 1 file (ctrl+o to expand)
  ⎿  Loaded ic/src/agent/CLAUDE.md

● There it is. JobContext is created with message.user_id (line 143). Let me check what user_id WeeChat emits vs what the REPL/CLI uses, and how the secrets store resolves credentials with that
  user_id.                                       

  Searched for 2 patterns, read 1 file (ctrl+o to expand)

● Now let me see what user_id the WeeChat channel emits — I already saw it in lib.rs:

  Read 1 file (ctrl+o to expand)                 

● Now let me confirm how the WASM channel wrapper maps the emitted user_id into the IncomingMessage:

  Searched for 2 patterns, read 1 file (ctrl+o to expand)

● That's the bug. Here's the chain:

  1. WeeChat emits user_id = "id:nick!user@host" (line 1038 of lib.rs)                            
  2. resolve_message_scope checks if sender_id == owner_actor_id. For WeeChat, owner_actor_id is typically not set (no entry in wasm_channel_owner_ids), so it falls into the else branch
  3. The resolved_user_id becomes the raw IRC hostmask: "id:nick!user@host"
  4. This flows into IncomingMessage.user_id, then into JobContext.user_id (dispatcher.rs:143)
  5. When the web_search tool executes, credential_user_id = ctx.user_id = "id:nick!user@host" (wrapper.rs:1108)
  6. The secrets store does store.get_decrypted("id:nick!user@host", "brave_api_key") — which returns nothing, because brave_api_key was stored under user "default"

  Now let me check the fallback logic:
  
  Read 1 file (ctrl+o to expand)                                                                  

● Wait, I see a "default" fallback was mentioned earlier at line 1524. Let me re-read that section more carefully.

  Read 1 file (ctrl+o to expand)                 

● The comment on line 1524 says "fallback to 'default'" but the code doesn't actually do it. It tries get_decrypted(user_id, ...), gets None, and immediately gives up. The fallback to "default"
  described in the comment is never implemented.                                                  

  Let me confirm there's no fallback elsewhere:                                                   

  Searched for 1 pattern, read 1 file (ctrl+o to expand)                                          

● This is fascinating. The test at line 3112 explicitly asserts that the fallback to "default" must NOT happen: assert!(result.resolved.is_empty(), "must not fallback to default"). So the comment
   at line 1524 describes a fallback that was intentionally removed (or never implemented) — the test enforces that credential resolution is strictly scoped to the requesting user_id.

  Here's the confirmed bug chain:                                                                 

  1. REPL/CLI creates messages with user_id = "default" (repl.rs:379)                             
  2. WeeChat creates messages with user_id = "id:nick!user@host" (lib.rs:1038)
  3. Secrets are stored under owner_id (typically "default")                                      
  4. resolve_host_credentials at wrapper.rs:1526 does store.get_decrypted(user_id, "brave_api_key") — with user_id "id:nick!user@host", this finds nothing
  5. The fallback to "default" is commented but intentionally not implemented (test at line 3112 enforces this)
  6. The tool fails with "credentials not configured"                                             

  The fix is in one of two places (or both):                                                      

  - Option A: In resolve_message_scope (wrapper.rs:768) — when no owner_actor_id is set, fall back to owner_scope_id instead of using the raw sender_id as the workspace user. The message already
  carries .with_owner_id(&self.owner_scope_id) (line 2202), but the user_id field is what drives tool execution.
  - Option B: In resolve_host_credentials — add the "default" fallback that the comment describes but the code doesn't implement. The test was written to prevent cross-user credential leakage,
  but for non-OAuth secrets like API keys (stored once by the owner), falling back to the owner scope makes sense.

  Option A is cleaner — it means "messages from WeeChat should execute tools under the instance owner's credential scope, not under the IRC user's scope." The sender_id is still preserved
  separately for audit/routing. Ruffles would get the same fix since the code path is identical in LunarWing 1.0.4.

  Want me to implement one of these?                                                              

✻ Brewed for 3m 14s
