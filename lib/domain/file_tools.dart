import "package:fs_shim/fs.dart";

import "tool_arg.dart";
import "workspace.dart";

/// The tool names, named here rather than beside the schemas, for the same
/// reason `artifactToolName` is: the agent dispatches on these and the UI
/// draws tool labels from them, so one source for each.
const readToolName = "read";
const writeToolName = "write";
const editToolName = "edit";

/// What a `read` call's arguments hold. [path] is required; [offset] and
/// [limit] are optional 1-indexed line numbers.
class ReadArgs {
  const ReadArgs({required this.path, this.offset, this.limit});

  final String path;
  final int? offset;
  final int? limit;
}

/// What a `write` call's arguments hold. [path] is required; [content] is the
/// full file content — no append or merge.
class WriteArgs {
  const WriteArgs({required this.path, required this.content});

  final String path;
  final String content;
}

/// What an `edit` call's arguments hold. [oldString] must appear exactly once
/// unless [replaceAll] is true.
class EditArgs {
  const EditArgs({
    required this.path,
    required this.oldString,
    required this.newString,
    this.replaceAll = false,
  });

  final String path;
  final String oldString;
  final String newString;
  final bool replaceAll;
}

ReadArgs? readArgsFrom(String? json) {
  final m = decodeArgs(json);
  if (m == null) return null;
  final path = m["path"];
  if (path is! String || path.isEmpty) return null;
  final offset = m["offset"] is int ? m["offset"] as int : null;
  final limit = m["limit"] is int ? m["limit"] as int : null;
  return ReadArgs(path: path, offset: offset, limit: limit);
}

WriteArgs? writeArgsFrom(String? json) {
  final m = decodeArgs(json);
  if (m == null) return null;
  final path = m["path"];
  final content = m["content"];
  if (path is! String || path.isEmpty || content is! String) return null;
  return WriteArgs(path: path, content: content);
}

EditArgs? editArgsFrom(String? json) {
  final m = decodeArgs(json);
  if (m == null) return null;
  final path = m["path"];
  final oldString = m["old_string"];
  final newString = m["new_string"];
  if (path is! String || path.isEmpty || oldString is! String || newString is! String) {
    return null;
  }
  final replaceAll = m["replace_all"] is bool ? m["replace_all"] as bool : false;
  return EditArgs(
    path: path,
    oldString: oldString,
    newString: newString,
    replaceAll: replaceAll,
  );
}

/// Resolve a file tool's path. A path starting with `project:` is joined onto
/// [projectWorkspace]; anything else is joined onto [workspace]. A relative
/// path is sanitised by [safeRelativePath] before joining, so `..` and a
/// leading separator cannot escape. An absolute path is the machine naming a
/// place of its own: it is used as written, normalised.
///
/// [guestRoot] is where [projectWorkspace] appears inside a proot guest (e.g.
/// `/root`), or null on the machine itself. Paths starting with `~/` are
/// expanded to [projectWorkspace]; paths starting with [guestRoot] are
/// translated back to [projectWorkspace] so the host filesystem can find them.
String resolveWorkspacePath(
  FileSystem fs,
  String path,
  String workspace,
  String projectWorkspace, {
  String? guestRoot,
}) {
  final project = path.startsWith("project:");
  var rest = project ? path.substring("project:".length) : path;
  // Expand `~` to the project workspace, the way the shell does inside a guest
  // or on Android where HOME is the project workspace.
  if (rest.startsWith("~/")) {
    rest = fs.path.join(projectWorkspace, rest.substring(2));
  } else if (rest == "~") {
    rest = projectWorkspace;
  }
  // Translate a guest path back to the host's, so the file tools — which use
  // the host filesystem — can find what the model named inside the guest.
  if (guestRoot != null && rest.startsWith(guestRoot)) {
    final suffix = rest.substring(guestRoot.length);
    rest = suffix.isEmpty
        ? projectWorkspace
        : fs.path.join(projectWorkspace, suffix);
  }
  if (!fs.path.isAbsolute(rest)) {
    return fs.path.join(
        project ? projectWorkspace : workspace, safeRelativePath(fs, rest));
  }
  return fs.path.normalize(rest);
}

/// Whether [path] — one [resolveWorkspacePath] has already resolved — is one
/// the workspaces do not hold: an absolute path reaching past both of them,
/// the machine itself, and on the web the rest of the data store the app
/// lives in. An absolute path *into* a workspace is the model using the place
/// it was told, and is not outside. The file tools are gated on this: a path
/// the workspaces hold runs without asking, one they do not is offered to the
/// user first.
bool outsideWorkspaces(
  FileSystem fs,
  String path,
  String workspace,
  String projectWorkspace,
) =>
    !isUnder(fs, path, workspace) && !isUnder(fs, path, projectWorkspace);

