// What a `bash` result says when the work has moved to a folder outside the
// writable set: that `add_directory` grants it once, where the model was
// otherwise leaving the sandbox command by command. See "Approvals" in
// `lib/data/builtin/AGENTS.md`.
//
// The signals are the sandbox's refusals, read off the kernel's own errors
// (`sandbox_denials.dart`), and the call's own arguments: whether it asked to
// leave the sandbox, the directory its leading `cd` names, the one the shell
// was standing in and the one it was left in. A command that merely failed
// in such a folder says nothing — a failing test or a `grep` with no match
// is not a refused write.

import "dart:io";

import "package:path/path.dart" as p;

import "../../../domain/permission.dart" show addDirectoryName;
import "../../../domain/file_tools.dart" show outsideWorkspaces;
import "../../../domain/shell.dart" show repositoryRootOf;
import "../../../domain/work_folders.dart" show refuseFolder;

/// One turn's account of which folders it has suggested a grant for, and how
/// often it asked to leave the sandbox in each. A folder is named once a
/// turn: a note on every command would be the noise the model learns to skip.
class GrantNudges {
  final _askedOnce = <String>{};
  final _named = <String>{};

  /// The note for a call whose work is in [folder], or null where there is
  /// nothing to say. [unsandboxed] is a call that asked to leave the sandbox,
  /// which says so the second time in one folder — once is the one-off the
  /// argument is for; otherwise the sandbox refused the call's writes there.
  String? note(String folder, {required bool unsandboxed}) {
    if (unsandboxed && _askedOnce.add(folder)) return null;
    if (!_named.add(folder)) return null;
    final grant =
        "call `$addDirectoryName` with $folder once: one approval covers "
        "every later write in it, and the commands after it run sandboxed "
        "without asking.";
    return unsandboxed
        ? "Note: this is another command asking to leave the sandbox for work "
              "in $folder, which is outside the folders commands may write "
              "to. If what it writes is in that folder, $grant"
        : "Note: the sandbox refused this command's writes in $folder, which "
              "is outside the folders commands may write to. If the work goes "
              "on in that folder, $grant";
  }
}

/// The folder a grant would be asked for, from where the call says its work
/// is: the first of [candidates] that is a directory outside the workspaces
/// and [granted], widened to the repository it sits in — the nearest
/// directory above it holding a `.git`, short of [home] — since a build's
/// writes land across the whole tree. Null where none is, or where the
/// folder is one `add_directory` refuses (`refuseFolder`): not a directory,
/// the root, [home] or anything holding it, the app's own data ([dataDir]),
/// or anything holding the workspaces.
String? grantFolder(
  Iterable<String> candidates, {
  required String workspace,
  required String projectWorkspace,
  required List<String> granted,
  String? home,
  String? dataDir,
}) {
  // The refusals `add_directory` answers with, so the note never names a
  // folder the tool would then refuse.
  bool grantable(String dir) =>
      refuseFolder(
        dir,
        dataDir: dataDir,
        home: home,
        workspaces: [workspace, projectWorkspace],
      ) ==
      null;
  for (final candidate in candidates) {
    final dir = p.normalize(candidate);
    if (!p.isAbsolute(dir)) continue;
    if (!outsideWorkspaces(
      dir,
      workspace,
      projectWorkspace,
      granted: granted,
    )) {
      continue;
    }
    final repo = repositoryRootOf(dir, stopAt: home);
    if (repo != null && grantable(repo)) return repo;
    if (grantable(dir)) return dir;
  }
  return null;
}

/// [path] if it is a directory, else the nearest directory above it that
/// exists: a refused write is often of a file that was never created.
String existingDirectoryOf(String path) {
  var at = p.normalize(path);
  while (!FileSystemEntity.isDirectorySync(at) && p.dirname(at) != at) {
    at = p.dirname(at);
  }
  return at;
}
