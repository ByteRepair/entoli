---
name: compact
description: Summarize the earlier part of this conversation so the model carries on from less context; nothing is sent to a model as a prompt
metadata:
  invocation: callback
  argument-hint: "[instructions for what the summary should focus on]"
---
`/compact [instructions]` summarizes the conversation so far. The summary is
what the model reads in place of the earlier messages; what you see in the
conversation is unchanged, and the divider naming it sits where it took over.

Everything said still stands. Instructions after the name tell the summary
what to focus on — "keep the file layout we agreed on", say, or "focus on the
build errors".

Auto-compact does the same thing on its own once a chat reaches the share of
the context window set on the settings page; `/compact` does it when you ask.
