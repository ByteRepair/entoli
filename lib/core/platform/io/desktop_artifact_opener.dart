import "dart:io";

import "../../../domain/artifact_style.dart";

/// Builds an injected temp copy of an artifact's entry HTML for desktop,
/// where the system browser opens a `file://` URL directly. The base
/// stylesheet is injected into the temp file rather than the artifact dir,
/// so the model's `read` tool keeps seeing the file it wrote. Behind a
/// conditional import so `dart:io` never reaches a web build.
///
/// Returns the absolute path of the temp file, or `null` if the source file
/// does not exist. The temp file is best-effort cleaned up 30s later, by
/// which point the browser has it.
Future<String?> writeArtifactTemp(String dir, String entryFile) async {
  final source = File("$dir/$entryFile");
  if (!await source.exists()) return null;
  final html = injectBaseStyles(await source.readAsString());
  final temp = await File(
    "${Directory.systemTemp.path}/entoli-artifact-${DateTime.now().microsecondsSinceEpoch}.html",
  ).create();
  await temp.writeAsString(html);
  Future.delayed(const Duration(seconds: 30), () async {
    try {
      if (await temp.exists()) await temp.delete();
    } catch (_) {}
  });
  return temp.path;
}