      5     self-heal: fix lock-fd leak into restarted services (wedged after 1st restart)
      6     
      7     main() opens the single-instance flock as fd 200 (no close-on-exec). When
      8     restart_service restarts a service, rc-service/systemctl spawn a long-lived
      9     supervise-daemon that INHERITED fd 200 and held the flock forever, so every
     10     later self-heal run exited 'another self-heal instance is running' <80><94> self-heal
     11     silently stopped remediating anything after its first successful restart.
     12     
     13     Close fd 200 for the restart dispatch and all its children via '200>&-' on the
     14     case compound in restart_service. Found via live fault-injection on a real
     15     OpenRC multi-tenant host (the mock chaos harness never forks a real daemon, so
     16     it could not surface this). Verified: stop xmpp-bridge-zeus -> grace -> restart
     17     -> recovered, and the lock is NOT held by the restarted supervisor; subsequent
     18     self-heal ticks run clean.
