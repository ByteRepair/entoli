import "llm/llm_client.dart";

/// Named beside the tools the way every other tool's is, so that matching on
/// it is compiler-linked to the name the model is actually told.
const memorySaveToolName = "memory_save";
const memorySearchToolName = "memory_search";
const memoryUpdateToolName = "memory_update";
const memoryDeleteToolName = "memory_delete";

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

/// Find the memories that are about what the turn is being asked. The hits
/// carry the ids the update and delete tools take.
const memorySearchTool = LlmTool(
  name: memorySearchToolName,
  description: "Search this project's memories — the durable facts saved from "
      "earlier conversations — for the ones about what you are being asked. "
      "Use the words a fact would be written with; a few keywords is enough. "
      "Each hit is shown as [id] text; keep the id if the fact needs "
      "correcting or removing.",
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

/// Correct a memory a search turned up: the replacement stands where the old
/// fact was, so the store holds the new wording once rather than both.
const memoryUpdateTool = LlmTool(
  name: memoryUpdateToolName,
  description: "Correct a memory you found with memory_search: the fact it "
      "held is wrong, outdated, or incomplete, and you have the better "
      "version. Use the id the search showed in square brackets. One fact "
      "per call, the same way memory_save writes one.",
  schema: {
    "type": "object",
    "properties": {
      "id": {
        "type": "string",
        "description": "The id of the memory to replace, as memory_search "
            "showed it.",
      },
      "text": {
        "type": "string",
        "description": "The corrected fact, in one or two sentences.",
      },
    },
    "required": ["id", "text"],
  },
);

/// Drop a memory a search turned up: the fact it held is wrong or no longer
/// true, and nothing replaces it.
const memoryDeleteTool = LlmTool(
  name: memoryDeleteToolName,
  description: "Delete a memory you found with memory_search: the fact it "
      "held is wrong or no longer true, and there is no replacement to save "
      "instead. Use the id the search showed in square brackets. Do not "
      "delete a memory just because it is not relevant to this conversation.",
  schema: {
    "type": "object",
    "properties": {
      "id": {
        "type": "string",
        "description": "The id of the memory to delete, as memory_search "
            "showed it.",
      },
    },
    "required": ["id"],
  },
);
