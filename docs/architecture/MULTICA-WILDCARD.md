Found it. The host_matches function checks self.host == url_host (exact match) or *.example.com (subdomain wildcard). A bare "*" doesn't match anything because:
  - "*" == "multica.ai" → false    
  - "*".strip_prefix("*.") → None (no dot after the star)

  So "host": "*" in the capabilities JSON is silently a no-op. The allowlist validator doesn't support a bare * as a universal wildcard.
                                                     
● That's a bug — the capabilities declare "host": "*" intending "any host", but the validator only supports *.domain.com subdomain wildcards, not bare *.
