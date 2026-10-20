import "../../domain/file_tools.dart";
import "llm/llm_client.dart";

/// Read a file from the workspace. Returns the contents with line numbers.
/// Use `offset` and `limit` (1-indexed line numbers) to read a slice.
const readTool = LlmTool(
  name: readToolName,
  description: "Read a file from the workspace and return its contents with "
      "line numbers. Paths are relative to the workspace; prefix with "
      "`project:` to read from the project workspace; an absolute path reads "
      "the machine directly, and the user is asked before it runs. Use "
      "`offset` and `limit` (1-indexed) to read a slice of a large file. "
      "Any AGENTS.md in the directories above the file comes back with it: "
      "follow those instructions.",
  schema: {
    "type": "object",
    "properties": {
      "path": {
        "type": "string",
        "description": "Workspace-relative path, `project:` + path for the "
            "project workspace, or an absolute path (asked of the user).",
      },
      "offset": {
        "type": "integer",
        "description": "Line number to start reading from (1-indexed). "
            "Defaults to 1.",
      },
      "limit": {
        "type": "integer",
        "description": "Maximum number of lines to read.",
      },
    },
    "required": ["path"],
  },
);

/// Write a file to the workspace. Creates or overwrites. No append or merge.
const writeTool = LlmTool(
  name: writeToolName,
  description: "Write a file to the workspace, creating or overwriting it. "
      "Paths are relative to the workspace; prefix with `project:` to write "
      "to the project workspace; an absolute path writes the machine "
      "directly, and the user is asked before it runs. The content is the "
      "full file — no append or merge. Use `edit` for partial changes to an "
      "existing file. An existing file must be read with `read` first, and "
      "read again if it has changed since.",
  schema: {
    "type": "object",
    "properties": {
      "path": {
        "type": "string",
        "description": "Workspace-relative path, `project:` + path for the "
            "project workspace, or an absolute path (asked of the user).",
      },
      "content": {
        "type": "string",
        "description": "The full file content.",
      },
    },
    "required": ["path", "content"],
  },
);

/// Edit a file by exact string replacement. `old_string` must appear exactly
/// once unless `replace_all` is true.
const editTool = LlmTool(
  name: editToolName,
  description: "Edit a file by replacing `old_string` with `new_string`. The "
      "`old_string` must appear exactly once in the file, or set "
      "`replace_all` to replace every occurrence. Paths are relative to the "
      "workspace; prefix with `project:` to edit in the project workspace; "
      "an absolute path edits the machine directly, and the user is asked "
      "before it runs. Use `write` to create a new file or overwrite one "
      "entirely. The file must be read with `read` first, and read again if "
      "it has changed since.",
  schema: {
    "type": "object",
    "properties": {
      "path": {
        "type": "string",
        "description": "Workspace-relative path, `project:` + path for the "
            "project workspace, or an absolute path (asked of the user).",
      },
      "old_string": {
        "type": "string",
        "description": "The exact string to find in the file.",
      },
      "new_string": {
        "type": "string",
        "description": "The string to replace it with.",
      },
      "replace_all": {
        "type": "boolean",
        "description": "Replace every occurrence of `old_string` instead of "
            "requiring it to be unique. Defaults to false.",
      },
    },
    "required": ["path", "old_string", "new_string"],
  },
);

