# Issues

* When starting a weechat ws adapter service, it must be done manually in a tmux pane that persists and runs

To make this WAY better, we can:

1. Make the adapter into a systemd/openrc service
2. Automate the installation of aiohttp using pip3 or uv during the mulit-tenant environment set up.
3. Enable service from #1 for the user.
4. additionally, we should automate more of this via mt admin, such as being able to set the ws_adpater local http port. see the other weechat issues for more information on this
