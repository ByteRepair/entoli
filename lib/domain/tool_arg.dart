import "dart:convert";

/// Pull a non-empty string argument out of a tool call's JSON, or null when
/// it is missing, not a string, or empty. Shared by the agent (which reads
/// arguments to run) and the UI (which reads them to display), so both parse
/// the same way.
String? stringArg(String? json, String key) {
  if (json == null || json.isEmpty) return null;
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map) return null;
    final value = decoded[key];
    return value is String && value.isNotEmpty ? value : null;
  } catch (_) {
    return null;
  }
}