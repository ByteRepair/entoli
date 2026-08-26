import "llm/llm_client.dart";

/// Named beside the tools the way every other tool's is, so that matching on
/// it is compiler-linked to the name the model is actually told.
const memorySaveToolName = "memory_save";
const memorySearchToolName = "memory_search";

/// Keep a fact that outlives the conversation. The store is the app's, not the
/// workspace's: a memory is never a file the file tools can see.
const memorySaveTool = LlmTool(
  name: memorySaveToolName,
  description: "Save one memory: a short durable fact about the user or the work "
      "that is still true after this conversation ends — a preference stated, "
      "a decision made, a fact learned about a codebase or an account. One "
      "fact per call, in one or two sentences, written so it still makes sense "
      "to someone who was not in the conversation. Do not save what a file in "
      "the workspace already says, and do not save secrets or keys.",
  schema: {
    "type": "object",
    "properties": {
      "text": {
        "type": "string",
        "description": "The fact, in one or two sentences.",
      },
    },
    "required": ["text"],
  },
);

/// Find the memories that are about what the turn is being asked.
const memorySearchTool = LlmTool(
  name: memorySearchToolName,
  description: "Search this project's memories — the durable facts saved from "
      "earlier conversations — for the ones about what you are being asked. "
      "Use the words a fact would be written with; a few keywords is enough.",
  schema: {
    "type": "object",
    "properties": {
      "query": {
        "type": "string",
        "description": "What the memory is about, as a few keywords.",
      },
    },
    "required": ["query"],
  },
);
