# Issue Description

## When utilizing a multi-tenant environment setup, the local http port for ADAPTER_PORT in the ws_adapter.py script

* is not configurable
* is not designated a port in the port registry
* must be manually changd in the python source code prior to running

### Unfortunately, this issue currently sort of breaks multi-tenant weechat environments and can be addressed and fixed easily.
