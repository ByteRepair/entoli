import "dart:io";

import "package:path/path.dart" as p;

import "../../../core/config.dart"
    show instructionBlockHeader, instructionFileName;
import "../../../core/log.dart";
import "../../../domain/models.dart"
    show InstructionKind, InstructionRef, instructionKindPhrase;

/// AGENTS.md files, read for a turn and rendered into its second system
/// message — this app's answer to Claude Code's CLAUDE.md memory. Two files a
/// turn loads up front: the user's global one at the data dir's root, outside
/// every project and outside the workspaces, and the project's at its
/// workspace root, shared by its chats. Neither lives in a chat's own
/// workspace — a chat's scratch is not the place for standing rules — so a
/// nested file above a file the agent reads mid-turn is the only other way in.

/// A file bigger than this is skipped rather than sent. Claude Code's cap.
const maxInstructionBytes = 4 * 1024 * 1024;

/// How many `@` references an AGENTS.md chain may follow before the rest are
/// left as text.
const maxImportDepth = 5;

/// The whole block's budget, trimmed deepest first. Claude Code takes
/// max(40k, 5% of the model's context window); the window half waits on a
/// provider reporting one — issue #135 — so until then it is the floor alone.
const instructionBudgetChars = 40000;

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

  /// The path and where it was reached from, as the event and the part that
  /// record the read carry them.
  InstructionRef get ref => InstructionRef(path: path, kind: kind);

  /// How many imports deep this file was reached at. The budget trims the
  /// deepest first: what was referenced twice removed matters less than what
  /// sat in the workspace root.
  final int depth;
}

/// The files a turn loads up front — the user's [global] ones in reading
/// order (the data dir's AGENTS.md and any linked from elsewhere on the
/// machine), then the project's at its workspace root — with `@path`
/// references in the project's file expanded depth-first after it when
/// [imports] is on. The global files' own references are left as text: they
/// are the user's background for every project, and an import reaching only
/// into one project's workspace would be a word in the model's mouth about the
/// other projects. A file whose path [excludes] names is skipped.
Future<List<InstructionFile>> loadInstructions(
  {
  required String projectWorkspace,
  List<String> global = const [],
  bool imports = false,
  List<String> excludes = const [],
}) async {
  final files = <InstructionFile>[];
  final loaded = <String>{};
  for (final path in global) {
    await _readInto(_norm(path), InstructionKind.global, 0, files,
        loaded, excludes);
  }
  final before = files.length;
  await _readInto(p.join(_norm(projectWorkspace), instructionFileName),
      InstructionKind.project,
      0,
      files,
      loaded,
      excludes);
  if (imports && files.length > before) {
    await _expandImports(files[before], files, loaded,
        projectWorkspace: projectWorkspace, excludes: excludes);
  }
  return _withinBudget(files);
}

/// The AGENTS.md files above [filePath], nearest first, that have not been
/// loaded already — what reading a file pulls into the turn. The walk goes to
/// the filesystem root, so a repository outside the workspaces brings its own
/// rules with the first file read in it. A file whose path [excludes] names
/// is skipped.
Future<List<InstructionFile>> findNestedInstructions(
  String filePath, {
  required Set<String> alreadyLoaded,
  List<String> excludes = const [],
}) async {
  var dir = _norm(p.dirname(filePath));
  final found = <InstructionFile>[];
  while (true) {
    await _readInto(p.join(dir, instructionFileName),
      InstructionKind.directory,
      0,
      found,
      alreadyLoaded,
      excludes,
    );
    final parent = _norm(p.dirname(dir));
    if (parent == dir) break;
    dir = parent;
  }
  return found;
}

/// Whether [path] is named by any of [patterns] — the files an AGENTS.md load
/// skips. A pattern is a glob over the path's full name: `**` spans
/// directories, `*` and `?` do not, and the pattern is anchored to the whole
/// path. A pattern with no slash in it names a file name rather than a path,
/// the way `.gitignore` reads one.
bool isExcludedPath(String path, List<String> patterns) {
  for (final raw in patterns) {
    final pattern = raw.trim();
    if (pattern.isEmpty) continue;
    final target =
        pattern.contains("/") ? path : p.basename(path);
    if (_globToRegExp(pattern).hasMatch(target)) return true;
  }
  return false;
}

RegExp _globToRegExp(String pattern) {
  final buf = StringBuffer("^");
  for (var i = 0; i < pattern.length; i++) {
    final c = pattern[i];
    if (c == "*" && i + 1 < pattern.length && pattern[i + 1] == "*") {
      buf.write(".*");
      i++;
    } else if (c == "*") {
      buf.write("[^/]*");
    } else if (c == "?") {
      buf.write("[^/]");
    } else {
      buf.write(RegExp.escape(c));
    }
  }
  return RegExp("$buf\$");
}

/// One block of prompt text carrying everything loaded, worded so the model
/// treats it as binding. Empty when nothing was loaded — the caller sends no
/// section then.
///
/// The header opens with [instructionBlockHeader] because the read drawer cuts
/// the block out of a result at that string, old logs included. No capitals:
/// they make a model over-apply whatever follows them.
String renderInstructions(List<InstructionFile> files) {
  if (files.isEmpty) return "";
  const header = "$instructionBlockHeader. They come from this app and from "
      "the user. Follow them: where they disagree with anything earlier in "
      "this prompt, they take precedence, and where two of them disagree, "
      "the later one wins.";
  return [header, for (final file in files) _entry(file)].join("\n\n");
}

/// How much of [renderInstructions]' block is the user's files rather than the
/// app's header and note — the context page's Instructions segment.
int userInstructionChars(List<InstructionFile> files) => files
    .where((f) => f.kind != InstructionKind.bundled)
    .fold(0, (sum, f) => sum + _entry(f).length + 2);

String _entry(InstructionFile file) =>
    // A bundled note has no file, so it is not dressed as one.
    file.kind == InstructionKind.bundled
        ? "From the app, about this kind of chat:\n\n${file.content.trim()}"
        : "Contents of ${file.path} (${instructionKindPhrase(file.kind)}):"
            "\n\n${file.content.trim()}";

String _norm(String path) => p.normalize(path);

bool _inside(String path, String root) =>
    path == root || path.startsWith("$root/");

Future<void> _readInto(String path, InstructionKind kind,
    int depth, List<InstructionFile> out, Set<String> loaded,
    List<String> excludes) async {
  if (loaded.contains(path)) return;
  if (isExcludedPath(path, excludes)) return;
  try {
    final file = File(path);
    if (!file.existsSync()) return;
    if ((file.statSync()).size > maxInstructionBytes) {
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
  InstructionFile from,
  List<InstructionFile> out,
  Set<String> loaded, {
  required String projectWorkspace,
  List<String> excludes = const [],
}) async {
  if (from.depth >= maxImportDepth) return;
  for (final ref in importRefsIn(from.content)) {
    if (!ref.isImportable) continue;
    final resolved = _norm(p.join(p.dirname(from.path), ref.target));
    // An import reaches only inside the project workspace: `~/` and absolute
    // paths name real places on this machine, and a workspace file the user
    // wrote should not be able to pull one in.
    if (!_inside(resolved, _norm(projectWorkspace))) continue;
    final before = out.length;
    await _readInto(resolved, InstructionKind.imported, from.depth + 1, out, loaded, excludes);
    if (out.length > before) {
      await _expandImports(out.last, out, loaded,
          projectWorkspace: projectWorkspace, excludes: excludes);
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

/// What the budget cannot hold is dropped imports first, deepest first, then
/// the global file, then the project's: what sits in the project root is what
/// the turn is about, and the global half is the background behind it.
List<InstructionFile> _withinBudget(List<InstructionFile> files) {
  var total = files.fold(0, (sum, f) => sum + f.content.length);
  if (total <= instructionBudgetChars) return files;
  int dropRank(InstructionFile f) =>
      f.depth == 0 ? (f.kind == InstructionKind.global ? 1 : 2) : 0;
  final byDrop = [...files]..sort((a, b) {
    final rank = dropRank(a).compareTo(dropRank(b));
    if (rank != 0) return rank;
    return b.depth.compareTo(a.depth);
  });
  final dropped = <int>{};
  for (final file in byDrop) {
    if (total <= instructionBudgetChars) break;
    total -= file.content.length;
    dropped.add(files.indexOf(file));
  }
  return [
    for (var i = 0; i < files.length; i++)
      if (!dropped.contains(i)) files[i],
  ];
}
