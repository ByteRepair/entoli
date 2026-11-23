# The share sheet

`entoli_share` is the adapter for the platform's share sheet.
`entoli_share.dart` is the whole of it: `PluginShareSheet` answers the core's
`ShareSheet` with `share_plus`, and `main` binds it as `shareSheetProvider`.
It hands a link to the sheet, pointed from the origin an iPad's popover needs,
and declines on Linux, whose `share_plus` opens a `mailto:` that a 100K link
does not survive. What a decline or a failure becomes is the caller's: the
share dialog copies the link instead (see "A shared chat" in
`lib/ui/chat/AGENTS.md`).

It is the only route to a share sheet for a link. A workspace file and an
Android backup are files, and leave through `entoli_files`' `FileHandoff` over
its own `agent_chat/files` channel.
