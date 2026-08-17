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

/// Resolve a workspace-relative path, handling the `project:` prefix. A path
/// starting with `project:` is joined onto [projectWorkspace]; anything else
/// is joined onto [workspace]. The path is sanitised by [safeRelativePath]
/// before joining, so `..` and leading separators cannot escape.
String resolveWorkspacePath(
  FileSystem fs,
  String path,
  String workspace,
  String projectWorkspace,
) {
  if (path.startsWith("project:")) {
    return fs.path.join(projectWorkspace, safeRelativePath(fs, path.substring(8)));
  }
  return fs.path.join(workspace, safeRelativePath(fs, path));
}

