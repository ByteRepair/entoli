import "../../domain/prompt_library.dart";
import "llm/llm_client.dart";

/// The one tool that answers from the library rather than the machine: the
/// model names a skill and is handed its instructions, base directory
/// included. Offered wherever a model-invocable skill exists — reading text
/// needs no shell, so it is offered with or without one, like `ask_user`.
const skillTool = LlmTool(
  name: skillToolName,
  description: "Load a skill's instructions. The skills available to you are "
      "listed under Skills in the system prompt; call this with one's name to "
      "read what it says before doing what it describes. Its files, where it "
      "has any, are under the base directory the result names.",
  schema: {
    "type": "object",
    "properties": {
      "skill": {
        "type": "string",
        "description": "The name of the skill to load.",
      },
      "args": {
        "type": "string",
        "description": "Optional arguments for the skill: the subject it is being applied to.",
      },
    },
    "required": ["skill"],
  },
);

const skillToolName = "skill";

/// What the model is told when it called the tool with no skill named.
const skillFormatError =
    'The $skillToolName tool takes {"skill": "...", "args": "..."}; the '
    '"skill" argument was missing.';

/// What a name the library does not know is answered with. Listing the rest
/// is what turns a refusal into a correction.
String skillUnknown(String name, Iterable<String> available) => available.isEmpty
    ? "There is no skill called '$name'; none are installed."
    : "There is no skill called '$name'. The skills you can load are "
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
