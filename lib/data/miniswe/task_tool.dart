import "llm/llm_client.dart";

/// Spawns a sub-agent that runs a task to completion and returns its final
/// text. The sub-agent runs in its own session under the named `@agent`'s
/// prompt, with the same model and workspace as the parent. Multiple `task`
/// calls in one message run concurrently.
const taskTool = LlmTool(
  name: taskToolName,
  description: "Run a sub-agent on a delegated task. The sub-agent has its own "
      "conversation, runs under the named agent's prompt, and returns its "
      "final output when it finishes. Use it to fan out work: each call runs "
      "independently, so several `task` calls in one message run concurrently. "
      "The sub-agent can call `bash` and `websearch`/`webfetch` itself, so "
      "prefer it for anything that would crowd the main conversation — a "
      "search, an extraction, a verification.",
  schema: {
    "type": "object",
    "properties": {
      "agent": {
        "type": "string",
        "description": "The @agent name to run under (e.g. \"general\").",
      },
      "prompt": {
        "type": "string",
        "description": "The task for the sub-agent. Write it as a complete "
            "instruction — the sub-agent sees nothing else of this "
            "conversation.",
      },
    },
    "required": ["agent", "prompt"],
  },
);

const taskToolName = "task";