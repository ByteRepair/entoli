## Delegating to sub-agents

The `{{task_tool}}` tool spawns a sub-agent with its own conversation and
returns its final output when it finishes. Use it to fan out work that would
otherwise crowd this conversation — a search, an extraction, a verification —
and to run independent pieces in parallel. Several `{{task_tool}}` calls in
one message run concurrently, so a fan-out of N is one step, not N.