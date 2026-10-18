import "tool_arg.dart";

/// The tool the agent renders with. Named here rather than beside the schema
/// that defines it, for the same reason `askToolName` is: the chat draws an
/// artifact back out of `conv.jsonl`, and what it has to recognise there is a
/// tool call by this name.
const artifactToolName = "artifact";

/// What an `artifact` call's arguments hold. The [path] is required — a
/// workspace-relative path to the HTML file to publish. [entryFile] is the
/// basename of [path] — the file the viewer opens. [title] is optional, shown
/// on the artifact card. [artifactId] is optional; if present, the artifact
/// is updated in place rather than created anew.
class ArtifactArgs {
  const ArtifactArgs({required this.path, required this.entryFile, required this.title, this.artifactId});

  final String path;
  final String entryFile;
  final String title;
  final String? artifactId;
}

/// Parse an `artifact` call's arguments. A missing `path` is the one thing
/// rejected, since the path is the whole point. The [entryFile] is derived
/// from the basename of [path] — the viewer opens it.
ArtifactArgs? artifactArgsFrom(String? argumentsJson) {
  final decoded = decodeArgs(argumentsJson);
  if (decoded == null) return null;

  final path = decoded["path"];
  if (path is! String || path.isEmpty) return null;
  final title = decoded["title"] is String ? decoded["title"] as String : "";
  final artifactId = decoded["artifact_id"] is String ? decoded["artifact_id"] as String : null;

  final entryFile =
      path.split(RegExp(r"[/\\]")).where((s) => s.isNotEmpty).lastOrNull;
  if (entryFile == null) return null;

  return ArtifactArgs(path: path, entryFile: entryFile, title: title, artifactId: artifactId);
}