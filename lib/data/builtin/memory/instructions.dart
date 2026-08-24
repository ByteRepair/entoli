import "package:fs_shim/fs.dart";

import "../../../core/log.dart";

/// AGENTS.md files in the workspaces, read for a turn and rendered into its
/// second system message — this app's answer to Claude Code's CLAUDE.md
/// memory. Two roots only: the project workspace every chat shares, and the
/// chat workspace inside it. Nothing above the project workspace is ever
/// read; the walk from the chat workspace stops there.
const instructionFileName = "AGENTS.md";

/// A file bigger than this is skipped rather than sent. Claude Code's cap.
const maxInstructionBytes = 4 * 1024 * 1024;

/// How many `@` references an AGENTS.md chain may follow before the rest are
/// left as text.
const maxImportDepth = 5;

/// The whole block's budget, trimmed deepest first. Claude Code takes
/// max(40k, 5% of the model's context window); the window half waits on a
/// provider reporting one — issue #135 — so until then it is the floor alone.
const instructionBudgetChars = 40000;

enum InstructionKind {
  /// At the project workspace root, or between it and a chat's directory.
  project,

  /// In the chat workspace itself.
  chat,

  /// Reached through an `@path` reference in another instructions file.
  imported,

  /// Found above a file the agent read, mid-turn.
  directory,
}

class InstructionFile {
  const InstructionFile({
    required this.path,
    required this.kind,
    required this.content,
    this.depth = 0,
  });

  final String path;
  final InstructionKind kind;
  final String content;

  /// How many imports deep this file was reached at. The budget trims the
  /// deepest first: what was referenced twice removed matters less than what
  /// sat in the workspace root.
  final int depth;
}

/// Every AGENTS.md from the chat workspace up to the project workspace root,
/// outermost first, with `@path` references expanded depth-first after their
/// importer when [imports] is on.
Future<List<InstructionFile>> loadInstructions(
  FileSystem fs, {
  required String chatWorkspace,
  required String projectWorkspace,
  bool imports = false,
}) async {
  final dirs = <String>[];
  var dir = _norm(fs, chatWorkspace);
  final stop = _norm(fs, projectWorkspace);
  // A chat workspace is always inside its project's; the bound keeps a
  // mis-shaped pair from walking off up the tree regardless.
  while (_inside(dir, stop)) {
    dirs.add(dir);
    if (dir == stop) break;
    dir = _norm(fs, fs.path.dirname(dir));
  }

  final files = <InstructionFile>[];
  final loaded = <String>{};
  for (final dir in dirs.reversed) {
    final path = fs.path.join(dir, instructionFileName);
    final kind = dir == _norm(fs, chatWorkspace)
        ? InstructionKind.chat
        : InstructionKind.project;
    final before = files.length;
    await _readInto(fs, path, kind, 0, files, loaded);
    if (imports && files.length > before) {
      await _expandImports(
        fs,
        files[before],
        files,
        loaded,
        chatWorkspace: chatWorkspace,
        projectWorkspace: projectWorkspace,
      );
    }
  }
  return _withinBudget(files);
}

/// The AGENTS.md files above [filePath], nearest first, that have not been
/// loaded already — what reading a file in a subdirectory pulls into the
/// turn. Empty unless [filePath] sits inside one of the two workspaces.
Future<List<InstructionFile>> findNestedInstructions(
  FileSystem fs,
  String filePath, {
  required Set<String> alreadyLoaded,
  required String chatWorkspace,
  required String projectWorkspace,
}) async {
  final roots = [
    _norm(fs, chatWorkspace),
    _norm(fs, projectWorkspace),
  ];
  var dir = _norm(fs, fs.path.dirname(filePath));
  final found = <InstructionFile>[];
  while (roots.any((root) => _inside(dir, root))) {
    await _readInto(
      fs,
      fs.path.join(dir, instructionFileName),
      InstructionKind.directory,
      0,
      found,
      alreadyLoaded,
    );
    final parent = _norm(fs, fs.path.dirname(dir));
    if (parent == dir) break;
    dir = parent;
  }
  return found;
}

/// One block of prompt text carrying everything loaded, worded so the model
/// treats it as binding. Empty when nothing was loaded — the caller sends no
/// section then.
String renderInstructions(List<InstructionFile> files) {
  if (files.isEmpty) return "";
  const header = "Workspace instructions are shown below. Be sure to adhere "
      "to these instructions. IMPORTANT: These instructions OVERRIDE any "
      "default behavior and you MUST follow them exactly as written.";
  return [
    header,
    for (final file in files)
      "Contents of ${file.path} (${_kindPhrase(file.kind)}):\n\n"
          "${file.content.trim()}",
  ].join("\n\n");
}

String _kindPhrase(InstructionKind kind) => switch (kind) {
      InstructionKind.project => "project workspace instructions",
      InstructionKind.chat => "chat workspace instructions",
      InstructionKind.imported => "instructions imported by another file",
      InstructionKind.directory => "instructions for this directory",
    };

String _norm(FileSystem fs, String path) => fs.path.normalize(path);

bool _inside(String path, String root) =>
    path == root || path.startsWith("$root/");

Future<void> _readInto(FileSystem fs, String path, InstructionKind kind,
    int depth, List<InstructionFile> out, Set<String> loaded) async {
  if (loaded.contains(path)) return;
  try {
    final file = fs.file(path);
    if (!await file.exists()) return;
    if ((await file.stat()).size > maxInstructionBytes) {
      logFailure("memory", "skipping $path: over $maxInstructionBytes bytes");
      return;
    }
    final content = await file.readAsString();
    if (content.trim().isEmpty) return;
    loaded.add(path);
    out.add(InstructionFile(path: path, kind: kind, content: content, depth: depth));
  } catch (error) {
    logFailure("memory", "could not read $path", error);
  }
}

Future<void> _expandImports(
  FileSystem fs,
  InstructionFile from,
  List<InstructionFile> out,
  Set<String> loaded, {
  required String chatWorkspace,
  required String projectWorkspace,
}) async {
  if (from.depth >= maxImportDepth) return;
  for (final ref in importRefsIn(from.content)) {
    if (!ref.isImportable) continue;
    final resolved = _norm(fs, fs.path.join(fs.path.dirname(from.path), ref.target));
    // An import reaches only inside the two workspaces: `~/` and absolute
    // paths name real places on this machine, and a workspace file the user
    // wrote should not be able to pull one in.
    if (!_inside(resolved, _norm(fs, chatWorkspace)) &&
        !_inside(resolved, _norm(fs, projectWorkspace))) {
      continue;
    }
    final before = out.length;
    await _readInto(
        fs, resolved, InstructionKind.imported, from.depth + 1, out, loaded);
    if (out.length > before) {
      await _expandImports(
        fs,
        out.last,
        out,
        loaded,
        chatWorkspace: chatWorkspace,
        projectWorkspace: projectWorkspace,
      );
    }
  }
}

/// What `@path/to/file` references a body of instructions makes, judged the
/// way Claude Code judges them: not inside code blocks or spans, comments
/// stripped, and only shapes that look like paths at all.
List<ImportRef> importRefsIn(String content) {
  final prose = _stripInlineCode(_stripFences(_stripComments(content)));
  return [
    for (final match in RegExp(r"(?:^|\s)@((?:[^\s\\]|\\ )+)").allMatches(prose))
      ImportRef(match.group(1)!),
  ];
}

/// A reference beyond its path text: whether it names a file at all. A
/// `#fragment` suffix is dropped and `\ ` unescapes, as upstream does; a
/// heading anchor or a social mention fails the shape test and stays prose.
class ImportRef {
  ImportRef(String raw) : target = _clean(raw) {
    isImportable = target.isNotEmpty &&
        !target.startsWith("@") &&
        !target.startsWith(RegExp(r"[#%^&*()]")) &&
        (target.startsWith("./") ||
            target.startsWith("~/") ||
            (target.startsWith("/") && target != "/") ||
            (!target.startsWith("/") &&
                target.startsWith(RegExp(r"[a-zA-Z0-9._-]"))));
  }

  final String target;
  late final bool isImportable;

  static String _clean(String raw) {
    var value = raw;
    final hash = value.indexOf("#");
    if (hash != -1) value = value.substring(0, hash);
    return value.replaceAll("\\ ", " ");
  }
}

String _stripComments(String text) =>
    text.replaceAll(RegExp("<!--[\\s\\S]*?-->"), "");

/// Fenced blocks and inline spans, so example code in an instructions file is
/// not read as references. Not a markdown parser — the shapes that matter are
/// all this needs to skip.
String _stripFences(String text) => text
    .replaceAll(RegExp("```[\\s\\S]*?```"), "")
    .replaceAll(RegExp("~~~[\\s\\S]*?~~~"), "");

String _stripInlineCode(String text) =>
    text.replaceAllMapped(RegExp("`[^`\n]*`"), (_) => "");

/// Deepest first, then latest-loaded among equals: the walk's own files sit
/// at depth 0 and survive longest.
List<InstructionFile> _withinBudget(List<InstructionFile> files) {
  var total = files.fold(0, (sum, f) => sum + f.content.length);
  if (total <= instructionBudgetChars) return files;
  final byDepth = [...files]..sort((a, b) => b.depth.compareTo(a.depth));
  final dropped = <int>{};
  for (final file in byDepth) {
    if (total <= instructionBudgetChars) break;
    total -= file.content.length;
    dropped.add(files.indexOf(file));
  }
  return [
    for (var i = 0; i < files.length; i++)
      if (!dropped.contains(i)) files[i],
  ];
}
