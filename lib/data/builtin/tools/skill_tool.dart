import "../../../domain/prompt_library.dart";
import "../../../domain/agent_backend.dart";
import "../../../domain/tool_arg.dart";
import "../llm/llm_client.dart";
import "agent_tool.dart";
import "turn.dart";

/// The one tool that answers from the library rather than the machine: the
/// model names a skill and is handed its instructions, base directory
/// included. Offered wherever a model-invocable skill exists — reading text
/// needs no shell, so it is offered with or without one, like `ask_user`.
/// Read-only and instant, so no approval and no running label.
///
/// The refusal for a `disable-model-invocation` skill is deliberate wording
/// rather than a plain no: the skill is *available*, just not to the model,
/// and one that is told only "no" will try the workflow by other means.
class SkillTool extends AgentTool {
  SkillTool(super.offer);

  @override
  String get name => skillToolName;

  Iterable<PromptDocument> get _usable =>
      offer.skills.where((s) => s.modelInvocable && !s.isCallback);

  @override
  bool get offered => _usable.isNotEmpty;

  /// The skills the model may load itself, listed. Absent rather than empty
  /// where there are none, so a device with no skills keeps its prompt — and
  /// the warmed prefix over it — exactly as it was.
  @override
  String get section => skillsSection(offer.skills);

  @override
  String get description => "Load a skill's instructions. The skills "
      "available to you are listed under Skills in the system prompt; call "
      "this with one's name to read what it says before doing what it "
      "describes. Its files, where it has any, are under the base directory "
      "the result names.";

  @override
  Map<String, dynamic> get schema => const {
        "type": "object",
        "properties": {
          "skill": {
            "type": "string",
            "description": "The name of the skill to load.",
          },
          "args": {
            "type": "string",
            "description": "Optional arguments for the skill: the subject it "
                "is being applied to.",
          },
        },
        "required": ["skill"],
      };

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    final name = stringArg(call.argumentsJson, "skill");
    if (name == null) {
      yield* toolRejected(call, skillFormatError);
      return;
    }
    final arguments = stringArg(call.argumentsJson, "args") ?? "";
    yield toolCalled(call, arguments.isEmpty ? name : "$name $arguments");

    final document = offer.skills.where((s) => s.name == name).firstOrNull;
    if (document == null) {
      yield toolFailed(call, skillUnknown(name, _usable.map((s) => s.name)));
      return;
    }
    // A callback's body is the user-facing note, never a procedure for the
    // model to read — the same reason composition refuses to expand it.
    if (!document.modelInvocable || document.isCallback) {
      yield toolFailed(call, skillReserved(name));
      return;
    }
    // The base directory translated to the guest's paths, where the shell
    // runs inside one, so the model can `cd` to it and run its scripts.
    var body = skillPrompt(document, arguments);
    for (final MapEntry(:key, :value) in turn.shell.hostToGuestPaths.entries) {
      body = body.replaceAll(key, value);
    }
    yield toolOk(call, body);
  }
}

/// The skills the model may load itself, as the system prompt lists them.
/// Empty produces nothing.
String skillsSection(List<PromptDocument> skills) {
  final usable =
      skills.where((s) => s.modelInvocable && !s.isCallback).toList();
  if (usable.isEmpty) return "";
  final listed = [
    for (final skill in usable)
      "- ${skill.name}: ${skill.description ?? "(no description)"}",
  ];
  return """## Skills

Skills are named procedures, packaged as instructions with whatever files they
need. Available to you:

${listed.join("\n")}

Load one with the `$skillToolName` tool when the task suits it. The result
carries its instructions and the base directory its files are in.""";
}

const skillToolName = "skill";

/// What the model is told when it called the tool with no skill named.
const skillFormatError =
    'The $skillToolName tool takes {"skill": "...", "args": "..."}; the '
    '"skill" argument was missing.';

/// What a name the library does not know is answered with. Listing the rest
/// is what turns a refusal into a correction; the tool is offered only where
/// there is something to list.
String skillUnknown(String name, Iterable<String> available) =>
    "There is no skill called '$name'. The skills you can load are "
    "${available.map((s) => "'$s'").join(", ")}.";

/// What a skill reserved for the user is answered with. The refusal says not
/// to work around it, because a model told only "no" will try the same thing
/// by other means.
String skillReserved(String name) =>
    "The skill '$name' is reserved for explicit user invocation: it runs only "
    "when the user sends it as /$name. Do not replicate this skill's workflow "
    "by other means.";

/// The skill as the tool hands it over — [withArguments] over the document's
/// body, which is the same string a `/name` message records, so both routes
/// put the same words in front of the model.
String skillPrompt(PromptDocument document, String arguments) =>
    withArguments(document.body, arguments);
