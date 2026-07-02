● Here's the not-done list, from the session backlog (also saved in memory so it survives):

  SSH harness — deferred

  1. Daemon-side live key loading (the root fix) — make SshAgentServer::add_key drive add_identity at runtime so uploaded keys are signable without any 
  restart, for every consumer (API, web panel — not just mt-admin). Once done, start-tenant's auto-bounce becomes a harmless fallback. This is the biggest
  remaining item and a nice self-contained Rust task.
  2. Production AuditLogger — SSH events still go to NullAuditLogger; the "auditable access" goal needs a persistent implementation.
  3. DELETE /hosts/{host} orphans the key secret (ssh_key_<host> stays in the store after host removal).
  4. RSA key support in the ssh/WASM tools — blocked on a russh upgrade (0.45 signs ssh-rsa with SHA-1).
  5. ssh_git AcceptFirst pin persistence — you chose (option "B") Strict + pinned known_host_key instead; building actual pin persistence remains an option.
  6. Tiny: a full data-transfer ssh_git clone test (seed testrepo.git with a commit) — we accepted the empty-repo transport proof.

  mt-admin — deferred

  7. The interactive onboarding walkthrough — your stated goal, wanted before 1.1.8/1.1.9: a guided setup mode so a fresh operator can't mis-step (the runtime
  persistence we just shipped removes one of its biggest hazards, but the walkthrough itself is unbuilt).
  8. Deferred-Minors cleanup commit — ~9 small items triaged non-blocking across both SDD runs (duplicated comment header, chown-fail warning wording,
  _probe_tcp unescaped interpolation, keys_loaded= blank on curl-fail, unguarded ports_get, doctor's "install docker or podman" advice when the real cause is
  an invalid env value, etc.). One tidy commit clears the lot.

  Housekeeping

  9. sshtest tenant on this box — keep as a standing live-test rig or remove-tenant --purge.

  If you want a recommendation for the next session's pick: #1 (live key loading) is the highest-leverage code item, and #7 (onboarding walkthrough) is the
  one with a release deadline attached — #8 is a good warm-up either way.

