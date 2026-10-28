import "../../../domain/profile.dart";
import "../../../domain/tone.dart";
import "../../../domain/tool_arg.dart";
import "../../../domain/agent_backend.dart";
import "../llm/llm_client.dart";
import "agent_tool.dart";
import "turn.dart";

/// The tools that change Entoli's own settings. Offered only once the session
/// has loaded [customizationSkill], so an ordinary turn's tool list, and the
/// warmed prefix over it, is what it was.
const customizationSkill = "entoli-customization";

const setProfileName = "set_profile";
const setToneName = "set_tone";

const _profileFields = {
  "name": "The user's name.",
  "date_of_birth": "Date of birth, YYYY-MM-DD.",
  "religion": "The user's religion.",
  "profession": "The user's profession.",
};

/// Set fields of the user's profile. Offered, with [SetToneTool], only once
/// the session has loaded [customizationSkill].
class SetProfileTool extends AgentTool {
  SetProfileTool(super.offer);

  @override
  ToolGroup get group => ToolGroup.settings;

  @override
  String get name => setProfileName;

  @override
  bool get offered => offer.customizing;

  @override
  String get description => "Set fields of the user's Entoli profile. Only "
      "the fields passed change; an empty string clears one.";

  @override
  Map<String, dynamic> get schema => {
        "type": "object",
        "properties": {
          for (final MapEntry(:key, :value) in _profileFields.entries)
            key: {"type": "string", "description": value},
        },
      };

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    yield toolCalled(call);
    String? error;
    await turn.editSettings!((s) {
      final edited = editedProfile(s.profile, call.argumentsJson);
      error = edited.error;
      if (error == null) s.profile = edited.profile;
    });
    yield error == null ? toolOk(call, "Profile saved.") : toolFailed(call, error!);
  }
}

/// Set the tone replies are written in.
class SetToneTool extends AgentTool {
  SetToneTool(super.offer);

  @override
  ToolGroup get group => ToolGroup.settings;

  @override
  String get name => setToneName;

  @override
  bool get offered => offer.customizing;

  @override
  String get description => "Set the tone Entoli's replies are written in.";

  @override
  Map<String, dynamic> get schema => {
        "type": "object",
        "properties": {
          "tone": {
            "type": "string",
            "enum": [for (final tone in Tone.values) tone.label.toLowerCase()],
          },
        },
        "required": ["tone"],
      };

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    final tone = toneArg(call.argumentsJson);
    if (tone == null) {
      yield* toolRejected(call, 'The $setToneName tool takes {"tone": '
          '"default" | "direct" | "kind" | "formal"}.');
      return;
    }
    yield toolCalled(call, tone.label);
    await turn.editSettings!((s) => s.tone = tone);
    yield toolOk(call, "Tone set to ${tone.label}.");
  }
}

/// [was] with the fields [argumentsJson] sets, or an error to hand the model.
({Profile? profile, String? error}) editedProfile(
    Profile? was, String argumentsJson) {
  final args = decodeArgs(argumentsJson) ?? const {};
  final unknown = args.keys.where((k) => !_profileFields.containsKey(k));
  if (unknown.isNotEmpty) {
    return (profile: was, error: "Unknown field: ${unknown.join(", ")}.");
  }
  String? field(String key, String? old) => switch (args[key]) {
        null => old,
        final String v => v.trim().isEmpty ? null : v.trim(),
        _ => old,
      };
  final dob = field("date_of_birth", was?.dateOfBirth);
  if (dob != null &&
      (!RegExp(r"^\d{4}-\d{2}-\d{2}$").hasMatch(dob) ||
          DateTime.tryParse(dob) == null)) {
    return (profile: was, error: "date_of_birth must be YYYY-MM-DD.");
  }
  final next = Profile(
    name: field("name", was?.name),
    dateOfBirth: dob,
    religion: field("religion", was?.religion),
    profession: field("profession", was?.profession),
  );
  return (profile: next.isEmpty ? null : next, error: null);
}

/// The tone [argumentsJson] names, by its label, or null.
Tone? toneArg(String argumentsJson) {
  final name = stringArg(argumentsJson, "tone")?.toLowerCase();
  return Tone.values.where((t) => t.label.toLowerCase() == name).firstOrNull;
}
