 Their commit has init templates we don't have. The differences:           
                                                                               
     ┌─────────────────────────────────┬────────────────────────────────────┐  
     │What e77f0f27 has                │What we have                        │  
     ├─────────────────────────────────┼────────────────────────────────────┤  
     │SERVICE_MAP[lunarvision]         │SERVICE_MAP[lunarvision]="${        │  
     │="lunarvision-sidecar"           │LUNARVISION_SERVICE:-ocr-sidecar}"  │  
     ├─────────────────────────────────┼────────────────────────────────────┤  
     │COMPONENT_CHECK_MAP[lunarvision] │Same ✓                              │  
     │="health-lunarvision.sh"         │                                    │  
     ├─────────────────────────────────┼────────────────────────────────────┤  
     │init-templates/lunarvision-      │❌ Missing                          │  
     │sidecar.service (systemd)        │                                    │  
     ├─────────────────────────────────┼────────────────────────────────────┤  
     │init-templates/lunarvision-      │❌ Missing                          │  
     │sidecar (OpenRC)                 │                                    │  
     └─────────────────────────────────┴────────────────────────────────────┘  
                                                                               
     Our SERVICE_MAP is slightly different — theirs hardcodes lunarvision-     
     sidecar, ours defaults to ocr-sidecar with an env override. The init      
     templates are what we're missing. Want me to cherry-pick those            
     templates, or create our own matching our naming?        
