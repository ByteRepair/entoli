// The directory grant tools. The model asks for write access to a directory
// outside the workspaces with `add_directory`, the user answers on the
// approval banner, and the answer rides the plumbing the sandbox re-prompt
// already has: the directory joins the turn's runtime grant through
// [BuiltinAgent.grantRuntimeDirs], and an "always" answer lands in the named
// tier's `writableDirs` — [ChatRepository.respondApproval] persists
// `ToolApproval.deniedDirs` there, so the tool carries its directory in that
// field. Nothing persists or is granted without the banner: the description
// is the only thing that tells the model the tool exists.
import "llm/llm_client.dart";

const addDirectoryName = "add_directory";
const writableDirectoriesName = "writable_directories";

const addDirectoryTool = LlmTool(
  name: addDirectoryName,
  description: "Request persistent write access to a directory outside the "
      "workspace, when the task needs write access there repeatedly. One "
      "approval covers the directory, so writes in it afterwards run without "
      "asking. Call this when the user has indicated that the work should be "
      "done in a specific folder outside of the chat or project workspaces. "
      "On a denial, carry on with the task; writes in that folder keep "
      "raising the ordinary per-write approval the user answers one at a "
      "time, and do not call this again this turn.",
  schema: {
    "type": "object",
    "properties": {
      "path": {
        "type": "string",
        "description": "The directory to request write access to: an "
            "absolute path, or one starting with ~ for the machine's home. "
            "A directory, not a file.",
      },
    },
    "required": ["path"],
  },
);

const writableDirectoriesTool = LlmTool(
  name: writableDirectoriesName,
  description: "List the directories outside the workspaces that this chat "
      "or project has been granted write access to, plus the workspaces "
      "themselves.",
  schema: {"type": "object", "properties": {}},
);

const directoryToolDefs = <LlmTool>[addDirectoryTool, writableDirectoriesTool];