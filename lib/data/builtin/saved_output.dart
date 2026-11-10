import "dart:io";

import "package:path/path.dart" as p;

import "../../core/log.dart";
import "../../domain/file_tools.dart" show guestWorkspacePath;

/// Where a chat keeps the results too large to word in full: a directory of
/// its own workspace, beside the background jobs' logs, so `read` and `tail`
/// reach it from every shell, a guest's included, and it goes when the chat
/// does. See "Tools" in `lib/data/builtin/AGENTS.md`.
const savedOutputDir = ".entoli-output";

/// Save [output], the result of the call [callId], into [workspace]'s
/// [savedOutputDir], and answer with the path the model is told it is at —
/// the guest's path where the commands run in one ([guestRoot], where
/// [projectWorkspace] appears inside it), the machine's otherwise.
///
/// Named by the call, and never over another call's file: a provider that
/// gives no ids of its own has them numbered per response, so the same id
/// comes round again, and an earlier result's path must keep naming what it
/// named. Null where the file could not be written; the result is then
/// worded as it always was, cut to its ends.
Future<String?> saveOutput(
  String output, {
  required String callId,
  required String workspace,
  required String projectWorkspace,
  String? guestRoot,
}) async {
  final stem = callId.replaceAll(RegExp(r"[^A-Za-z0-9_-]"), "_");
  try {
    final dir = Directory(p.join(workspace, savedOutputDir));
    dir.createSync(recursive: true);
    late File file;
    for (var n = 1; ; n++) {
      file = File(p.join(dir.path, n == 1 ? "$stem.txt" : "$stem-$n.txt"));
      try {
        // Exclusive, so two saves racing for a name cannot both take it.
        file.createSync(exclusive: true);
        break;
      } on PathExistsException {
        continue;
      }
    }
    await file.writeAsString(output, flush: true);
    final name = p.basename(file.path);
    return guestRoot == null
        ? file.path
        : p.posix.join(
            guestWorkspacePath(guestRoot, projectWorkspace, workspace),
            savedOutputDir,
            name,
          );
  } catch (e) {
    logFailure("output", "could not save the result of call $callId", e);
    return null;
  }
}
