# known issues

* omemo devices may need to be trusted in seperate client
* for http file uploads:

● So IncomingMessage does have an attachments field. Let me check if the XMPP channel populates it for inbound OOB/file messages:
● Line 764 is the key — attachments: Vec::new(). That's where incoming messages are constructed:
● That's the pairing reply, not the incoming message construction. Let me find where actual incoming chat messages are built:
● That confirms it. Incoming messages are built with IncomingMessage::new(...) but .with_attachments() is never called — no OOB URL extraction from inbound stanzas.
  The bridge supports sending files (outbound XEP-0363 upload + OOB), but receiving files (parsing OOB URLs from incoming stanzas) isn't implemented. The agent is correct — inbound file uploads aren't compatible
  because the bridge simply doesn't extract them.
  This would be a feature to add: parse <x xmlns='jabber:x:oob'> and/or <url> elements from incoming message stanzas, download the file, and attach it to IncomingMessage.
