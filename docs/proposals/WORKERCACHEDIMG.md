the fix for the missing mechanism: after loading a new image     
     into a tenant's store, _ensure_tenant_image should podman image prune -f (drop      
     the now-untagged old one) so updates don't accumulate. That's a one-line addition   
     to the transfer flow
