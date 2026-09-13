import "../../domain/tool_arg.dart";
import "llm/llm_client.dart";

/// Package a skill drafted in the workspace and offer it to the user to
/// install. The model writes the skill as a directory containing a `SKILL.md`
/// plus any scripts, references, or assets it needs, then calls this tool with
/// the directory's path. The user reviews and installs it from a card in the
/// chat; the model cannot install it itself.
const createSkillTool = LlmTool(
  name: createSkillToolName,
  description: "Package a skill you have drafted in the workspace and offer it "
      "to the user to install. Write the skill as a directory containing a "
      "SKILL.md plus any scripts, references, or assets it needs, then call "
      "this with the directory's path. The SKILL.md's frontmatter must follow "
      "the Agent Skills spec: a `name` of lowercase letters, digits and "
      "hyphens (max 64 characters, matching the directory's name), a "
      "`description` of at most 1024 characters, and only the keys name, "
      "description, license, compatibility, metadata, allowed-tools — Entoli's "
      "own settings belong under `metadata:`. A frontmatter that does not "
      "conform is refused with the reasons. The user reviews and installs it "
      "from a card in the chat; you cannot install it yourself. The skill "
      "lands in the user's own skills directory, shadowing any bundled skill "
      "of the same name.",
  schema: {
    "type": "object",
    "properties": {
      "path": {
        "type": "string",
        "description": "Workspace-relative path to the skill directory (the "
            "one containing SKILL.md).",
      },
      "name": {
        "type": "string",
        "description": "Optional skill name. Defaults to the directory name.",
      },
    },
    "required": ["path"],
  },
);

const createSkillToolName = "create_skill";

/// What the model is told when it called the tool with no path named.
const createSkillFormatError =
    'The $createSkillToolName tool takes {"path": "...", "name": "..."}; the '
    '"path" argument was missing.';

/// Parsed arguments from a `create_skill` call.
class CreateSkillArgs {
  const CreateSkillArgs({required this.path, this.name});
  final String path;
  final String? name;
}

CreateSkillArgs? createSkillArgsFrom(String json) {
  final args = decodeArgs(json);
  if (args == null) return null;
  final path = stringArg(json, "path");
  if (path == null) return null;
  return CreateSkillArgs(path: path, name: stringArg(json, "name"));
}