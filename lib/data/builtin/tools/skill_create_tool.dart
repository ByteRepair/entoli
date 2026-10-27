import "../../../domain/agent_backend.dart";
import "../../../domain/shell.dart";
import "../../../domain/tool_arg.dart";
import "../../prompts/skill_import.dart" show SkillImportException;
import "../../prompts/skill_validate.dart"
    show skillDescriptionMax, skillNameMax, skillSpecKeys;
import "../approval_gate.dart";
import "../llm/llm_client.dart";
import "agent_tool.dart";
import "turn.dart";

final _specKeys = skillSpecKeys.toList()..sort();

/// Package a skill the model drafted in its workspace and offer it to the
/// user to install. Mirrors `artifact`: the model writes files, calls the
/// tool, and a card appears in the chat. The user reviews and installs from
/// the card — the model cannot install it itself, and a sub-agent is not
/// offered it, having no card to show.
class CreateSkillTool extends AgentTool {
  CreateSkillTool(super.offer);

  @override
  String get name => createSkillToolName;

  @override
  bool get offered => offer.caps.createSkill;

  // Interpolates the spec's caps and key list from [skill_validate.dart] —
  // the validator is what the model's draft is held to, so the description
  // is not a second copy of its numbers to drift.
  @override
  String get description => "Package a skill you have drafted in the "
      "workspace and offer it to the user to install. Write the skill as a "
      "directory containing a SKILL.md plus any scripts, references, or "
      "assets it needs, then call this with the directory's path. The "
      "SKILL.md's frontmatter must follow the Agent Skills spec: a `name` of "
      "lowercase letters, digits and hyphens (max $skillNameMax characters, "
      "matching the directory's name), a `description` of at most "
      "$skillDescriptionMax characters, and only the keys $_specKeys — "
      "Entoli's own settings belong under `metadata:`. A frontmatter that "
      "does not conform is refused with the reasons. The user reviews and "
      "installs it from a card in the chat; you cannot install it yourself. "
      "The skill lands in the user's own skills directory, shadowing any "
      "bundled skill of the same name.";

  @override
  Map<String, dynamic> get schema => const {
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "Workspace-relative path to the skill directory "
                "(the one containing SKILL.md).",
          },
          "name": {
            "type": "string",
            "description": "Optional skill name. Defaults to the directory name.",
          },
        },
        "required": ["path"],
      };

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    final args = createSkillArgsFrom(call.argumentsJson);
    if (args == null) {
      yield* toolRejected(call, createSkillFormatError);
      return;
    }
    final fs = turn.fs;
    final path = turn.resolvePath(args.path);
    yield toolCalled(call, args.path);
    String? installId;
    String? skillName;
    final outcome = GateOutcome();
    yield* turn.gate.path(call, path, createSkillToolName, () async {
      if (!await fs.directory(path).exists()) {
        return ShellResult.failed(
            "The directory '$path' does not exist. Write the skill there first "
            "with write/edit, then call $createSkillToolName.");
      }
      if (!await fs.file(fs.path.join(path, "SKILL.md")).exists()) {
        return ShellResult.failed(
            "The directory '$path' has no SKILL.md. A skill needs one.");
      }
      try {
        final result = await turn.packageSkill!(args.path, args.name);
        installId = result.installId;
        skillName = result.name;
      } on SkillImportException catch (e) {
        return ShellResult.failed(
            "SKILL.md does not conform to the Agent Skills spec: $e. "
            "Fix the frontmatter and call $createSkillToolName again.");
      }
      return const ShellResult(returnCode: 0, output: "");
    }, outcome);
    final id = installId;
    if (outcome.result!.returnCode != 0 || id == null) {
      yield ToolResultEvent(outcome.resultOf(call));
      return;
    }
    final name = skillName ?? args.name ?? args.path;
    yield SkillInstallEvent(installId: id, title: name);
    yield toolOk(call, "Skill '$name' packaged. "
        "The user can review and install it from the card below.");
  }
}

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
  final path = stringArg(json, "path");
  if (path == null) return null;
  return CreateSkillArgs(path: path, name: stringArg(json, "name"));
}