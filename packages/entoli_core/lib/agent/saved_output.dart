import "package:file/file.dart" show File, FileSystem;
import "package:path/path.dart" as p;

import "../model/log.dart";
import "../model/file_tools.dart" show guestWorkspacePath;
import "../model/shell_job.dart" show fileStemOf;

/// Where a chat keeps the results too large to word in full: a directory of
/// its own workspace, beside the background jobs' logs, so `read` and `tail`
/// reach it from every shell, a guest's included, and it goes when the chat
/// does. See "Tools" in `packages/entoli_core/lib/agent/AGENTS.md`.
const savedOutputDir = ".entoli-output";

/// [relative], a path inside the chat's [workspace], as the model is given
/// it: absolute, so a command reaches it from wherever the shell has moved,
/// and the guest's path where the commands run in one ([guestRoot], where
/// [projectWorkspace] appears inside it) — which `read` maps back. A saved
/// result and a job's log are both named this way.
String shellPath(
  String relative, {
  required String workspace,
  required String projectWorkspace,
  String? guestRoot,
}) => guestRoot == null
    ? p.join(workspace, relative)
    : p.posix.join(
        guestWorkspacePath(guestRoot, projectWorkspace, workspace),
        relative,
      );

/// [output], the result of the call [callId], saved where it is longer than
/// [limit] — the one test of "too large to word in full" — and the path the
/// model is told it is at. Null where it fits, where there is no limit, or
/// where the save failed.
Future<String?> saveIfLarge(
  FileSystem fs,
  String output,
  int? limit, {
  required String callId,
  required String workspace,
  required String projectWorkspace,
  String? guestRoot,
}) async {
  if (limit == null || output.length <= limit) return null;
  return saveOutput(
    fs,
    output,
    callId: callId,
    workspace: workspace,
    projectWorkspace: projectWorkspace,
    guestRoot: guestRoot,
  );
}

/// Save [output], the result of the call [callId], into [workspace]'s
/// [savedOutputDir], and answer with its [shellPath].
///
/// Named by the call, and never over another call's file: a provider that
/// gives no ids of its own has them numbered per response, so the same id
/// comes round again, and an earlier result's path must keep naming what it
/// named. Null where the file could not be written; the result is then
/// worded as it always was, cut to its ends.
Future<String?> saveOutput(
  FileSystem fs,
  String output, {
  required String callId,
  required String workspace,
  required String projectWorkspace,
  String? guestRoot,
}) async {
  final stem = fileStemOf(callId);
  try {
    final dir = fs.directory(p.join(workspace, savedOutputDir));
    dir.createSync(recursive: true);
    late File file;
    for (var n = 1; ; n++) {
      file = fs.file(p.join(dir.path, n == 1 ? "$stem.txt" : "$stem-$n.txt"));
      // Checked and created with no await between, so two saves racing for
      // a name cannot both take it. Not `exclusive`: package:file drops it.
      if (!file.existsSync()) {
        file.createSync();
        break;
      }
    }
    await file.writeAsString(output, flush: true);
    return shellPath(
      p.join(savedOutputDir, p.basename(file.path)),
      workspace: workspace,
      projectWorkspace: projectWorkspace,
      guestRoot: guestRoot,
    );
  } catch (e) {
    logFailure("output", "could not save the result of call $callId", e);
    return null;
  }
}
