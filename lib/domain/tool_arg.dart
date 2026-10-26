import "dart:convert";

/// Decode a tool call's arguments JSON to a map, or null when it is missing,
/// empty, not an object, or unparseable. The shared base of [stringArg] and
/// the per-tool arg parsers, so they all read the same way.
Map<String, dynamic>? decodeArgs(String? json) {
  if (json == null || json.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(json);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}

/// Pull a non-empty string argument out of a tool call's JSON, or null when
/// it is missing, not a string, or empty. Shared by the agent (which reads
/// arguments to run) and the UI (which reads them to display), so both parse
/// the same way.
String? stringArg(String? json, String key) {
  final decoded = decodeArgs(json);
  if (decoded == null) return null;
  final value = decoded[key];
  return value is String && value.isNotEmpty ? value : null;
}

/// Pull an integer argument out of a tool call's JSON, or null when it is
/// missing or not an integer. A number the model writes as `1e3` is not an
/// integer it meant, so it is refused rather than rounded.
int? intArg(String? json, String key) {
  final decoded = decodeArgs(json);
  if (decoded == null) return null;
  final value = decoded[key];
  return value is int ? value : null;
}

/// Whether a boolean argument is set to true; anything else, missing or not
/// a boolean, is false.
bool boolArg(String? json, String key) => decodeArgs(json)?[key] == true;