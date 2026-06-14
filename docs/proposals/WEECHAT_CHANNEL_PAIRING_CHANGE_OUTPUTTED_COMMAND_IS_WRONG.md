# The situation

## When pairing mode is enabled in capabilities json:

* The message that gets outputted to the user in the weechat message is something akin to:

12:20:13 agentname │ To pair with this agent, run: ironclaw pairing approve weechat XNXXXX96

* This should be changed to something like:

lunarwing pairing approve weechat XNXXXX96

* especially since the ACTUAL command to pair is something like:

```
sudo -u agentname env LUNARWING_BASE_DIR=/home/agentname/lunarwing/state /home/agentname/lunarwing/ic/target/release/lunarwing pairing approve weechat XNXXXX96
```

* The command it shows in the response is simply incorrect and a reference to the old IronClaw tool that needs to be rectified (because it is simply incorrect)
