import "../../domain/app_settings.dart";
import "../../domain/profile.dart";
import "../../domain/tone.dart";
import "../../domain/tool_arg.dart";
import "llm/llm_client.dart";

/// The tools that change Entoli's own settings. Offered only once the session
/// has loaded [customizationSkill], so an ordinary turn's tool list, and the
/// warmed prefix over it, is what it was.
const customizationSkill = "entoli-customization";

const setProfileName = "set_profile";
const setToneName = "set_tone";

/// How the tools write: the settings notifier's own update, so a change lands
/// in the state the app holds rather than under it.
typedef SettingsEditor = Future<void> Function(void Function(AppSettings) change);

const _profileFields = {
  "name": "The user's name.",
  "date_of_birth": "Date of birth, YYYY-MM-DD.",
  "religion": "The user's religion.",
  "profession": "The user's profession.",
};

final setProfileTool = LlmTool(
  name: setProfileName,
  description: "Set fields of the user's Entoli profile. Only the fields "
      "passed change; an empty string clears one.",
  schema: {
    "type": "object",
    "properties": {
      for (final MapEntry(:key, :value) in _profileFields.entries)
        key: {"type": "string", "description": value},
    },
  },
);

final setToneTool = LlmTool(
  name: setToneName,
  description: "Set the tone Entoli's replies are written in.",
  schema: {
    "type": "object",
    "properties": {
      "tone": {
        "type": "string",
        "enum": [for (final tone in Tone.values) tone.label.toLowerCase()],
      },
    },
    "required": ["tone"],
  },
);

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
