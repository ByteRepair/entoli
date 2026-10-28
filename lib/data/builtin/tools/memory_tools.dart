import "../../../domain/agent_backend.dart";
import "../../../domain/tool_arg.dart";
import "../llm/llm_client.dart";
import "../memory/store.dart";
import "agent_tool.dart";
import "turn.dart";

/// Named beside the tools the way every other tool's is, so that matching on
/// it is compiler-linked to the name the model is actually told.
const memorySaveToolName = "memory_save";
const memorySearchToolName = "memory_search";
const memoryUpdateToolName = "memory_update";
const memoryDeleteToolName = "memory_delete";

/// The memory tools: ordinary tools over the project's store, offered where
/// the turn has one. None raises an approval — two read, and the other two
/// write to the app's own store, which the approval regime does not police;
/// a memory nobody wants is a line the user deletes in the explorer.
abstract class _MemoryTool extends AgentTool {
  _MemoryTool(super.offer);

  @override
  ToolGroup get group => ToolGroup.memory;

  @override
  bool get offered => offer.memory;
}

/// Keep a fact that outlives the conversation. The store is the app's, not
/// the workspace's: a memory is never a file the file tools can see.
class MemorySaveTool extends _MemoryTool {
  MemorySaveTool(super.offer);

  @override
  String get name => memorySaveToolName;

  @override
  String get description => "Save one memory: a short durable fact about the "
      "user or the work that is still true after this conversation ends — a "
      "preference stated, a decision made, a fact learned about a codebase or "
      "an account. One fact per call, in one or two sentences, written so it "
      "still makes sense to someone who was not in the conversation. Do not "
      "save what a file in the workspace already says, and do not save "
      "secrets or keys.";

  @override
  Map<String, dynamic> get schema => const {
        "type": "object",
        "properties": {
          "text": {
            "type": "string",
            "description": "The fact, in one or two sentences.",
          },
        },
        "required": ["text"],
      };

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    final text = stringArg(call.argumentsJson, "text");
    if (text == null) {
      yield* toolRejected(call, 'The $memorySaveToolName tool takes {"text": "..."}; '
          "that argument was missing.");
      return;
    }
    yield toolCalled(call, text);
    try {
      await turn.memoryStore!.add(text, chat: turn.memoryChat);
    } catch (e) {
      yield toolFailed(call, "The memory could not be saved: $e");
      return;
    }
    yield toolOk(call, "Memory saved. Later conversations are offered it when "
        "it looks relevant.");
  }
}

/// Find the memories that are about what the turn is being asked. The hits
/// carry the ids the update and delete tools take, and this is the only place
/// the model sees them.
class MemorySearchTool extends _MemoryTool {
  MemorySearchTool(super.offer);

  @override
  String get name => memorySearchToolName;

  @override
  String get description => "Search this project's memories — the durable "
      "facts saved from earlier conversations — for the ones about what you "
      "are being asked. Use the words a fact would be written with; a few "
      "keywords is enough. Each hit is shown as [id] text; keep the id if the "
      "fact needs correcting or removing.";

  @override
  Map<String, dynamic> get schema => const {
        "type": "object",
        "properties": {
          "query": {
            "type": "string",
            "description": "What the memory is about, as a few keywords.",
          },
        },
        "required": ["query"],
      };

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    final query = stringArg(call.argumentsJson, "query");
    if (query == null) {
      yield* toolRejected(call, 'The $memorySearchToolName tool takes {"query": "..."}; '
          "that argument was missing.");
      return;
    }
    yield toolCalled(call, query);
    final hits = await turn.memoryStore!.search(query);
    yield toolOk(call,
        hits.isEmpty ? "No memories match." : renderRecall(hits, withIds: true));
  }
}

/// Correct a memory a search turned up: the replacement stands where the old
/// fact was, so a memory the user corrected is not left to drift beside its
/// newer version.
class MemoryUpdateTool extends _MemoryTool {
  MemoryUpdateTool(super.offer);

  @override
  String get name => memoryUpdateToolName;

  @override
  String get description => "Correct a memory you found with memory_search: "
      "the fact it held is wrong, outdated, or incomplete, and you have the "
      "better version. Use the id the search showed in square brackets. One "
      "fact per call, the same way memory_save writes one.";

  @override
  Map<String, dynamic> get schema => const {
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
      };

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    final id = stringArg(call.argumentsJson, "id");
    final text = stringArg(call.argumentsJson, "text");
    if (id == null || text == null) {
      yield* toolRejected(call,
          'The $memoryUpdateToolName tool takes {"id": "...", "text": "..."}; '
          "that argument was missing.");
      return;
    }
    yield toolCalled(call, text);
    try {
      if (await turn.memoryStore!.update(id, text, chat: turn.memoryChat) == null) {
        yield toolFailed(call, "The memory could not be updated: no memory with "
            "id $id. Search again for its current id.");
        return;
      }
    } catch (e) {
      yield toolFailed(call, "The memory could not be updated: $e");
      return;
    }
    yield toolOk(call, "Memory updated. The replacement stands where the old "
        "fact was.");
  }
}

/// Drop a memory a search turned up: the fact it held is wrong or no longer
/// true, and nothing replaces it, so a later recall does not carry it.
class MemoryDeleteTool extends _MemoryTool {
  MemoryDeleteTool(super.offer);

  @override
  String get name => memoryDeleteToolName;

  @override
  String get description => "Delete a memory you found with memory_search: "
      "the fact it held is wrong or no longer true, and there is no "
      "replacement to save instead. Use the id the search showed in square "
      "brackets. Do not delete a memory just because it is not relevant to "
      "this conversation.";

  @override
  Map<String, dynamic> get schema => const {
        "type": "object",
        "properties": {
          "id": {
            "type": "string",
            "description": "The id of the memory to delete, as memory_search "
                "showed it.",
          },
        },
        "required": ["id"],
      };

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    final id = stringArg(call.argumentsJson, "id");
    if (id == null) {
      yield* toolRejected(call,
          'The $memoryDeleteToolName tool takes {"id": "..."}; that argument '
          "was missing.");
      return;
    }
    yield toolCalled(call);
    try {
      await turn.memoryStore!.delete(id);
    } catch (e) {
      yield toolFailed(call, "The memory could not be deleted: $e");
      return;
    }
    yield toolOk(call, "Memory deleted, where it named an existing one.");
  }
}
