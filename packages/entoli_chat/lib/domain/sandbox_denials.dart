// Which writes the sandbox refused a command, read off the kernel's own error.
//
// Neither enforcer reports a denial to anyone. Seatbelt logs none for a
// `sandbox-exec` profile nested under another sandbox, and a `log show` over
// the run's window costs a second or two on every failing command, so it is
// no signal to wait on. Landlock answers EACCES with nothing logged at all,
// and its helper has exec'd the command before any write happens. What both
// leave behind is the errno, printed by whatever made the call: Seatbelt's
// EPERM ("Operation not permitted") and Landlock's EACCES ("Permission
// denied"), naming the path. A path outside every write the sandbox granted
// is a write the sandbox refused. That is the OS's error being read, not the
// model's words, which is why it can stand where a guess from text cannot.
// See "Approvals" in `lib/data/builtin/AGENTS.md`.

import "package:path/path.dart" as p;

import "shell.dart" show CommandSandbox, pathInside, realPath;

/// The errno texts a sandbox's refused write prints: Seatbelt's EPERM and
/// Landlock's EACCES.
final _denied = RegExp(r"Operation not permitted|Permission denied");

/// A quoted string on the line: the shapes GNU tools, git, Python and Dart
/// put a path in.
final _quoted = RegExp("['\"‘`]([^'\"‘’`\n]+)['\"’`]");

/// How many denials a result names, a build failing on every file in a
/// directory being one fact rather than a thousand.
const _most = 5;

/// The paths [output] says were refused a write that [sandbox] did not
/// grant, in the order printed, at most a handful. Relative paths are read
/// from [cwd], `~` from the sandbox's home. [readOnly] is left out, its
/// denials being the app's own file modes rather than the sandbox, and so is
/// `/dev`: a device is no folder to grant, and the helpers each open their
/// own few. Empty where nothing printed one — the common case, answered
/// before anything is resolved.
List<String> sandboxDenials(
  String output,
  CommandSandbox sandbox, {
  required String cwd,
  List<String> readOnly = const [],
}) {
  if (!_denied.hasMatch(output)) return const [];
  final grants = [...sandbox.writes, ...readOnly, "/dev"];
  late final resolved = [for (final g in grants) realPath(g)];
  bool granted(String path) {
    if (grants.any((g) => pathInside(path, g))) return true;
    final real = realPath(path);
    return resolved.any((g) => pathInside(real, g));
  }

  final found = <String>[];
  for (final line in output.split("\n")) {
    final error = _denied.firstMatch(line);
    if (error == null) continue;
    for (final named in _pathsOn(line, error.start)) {
      final path = _absolute(named, cwd, sandbox.home);
      if (path == null || found.contains(path) || granted(path)) continue;
      found.add(path);
      if (found.length == _most) return found;
    }
  }
  return found;
}

/// What [line] names as the path its error at [at] is about: the quoted
/// strings on it, or, with none, the field just before the error —
/// `touch: /x/y: Operation not permitted`.
Iterable<String> _pathsOn(String line, int at) {
  final quoted = [for (final m in _quoted.allMatches(line)) m.group(1)!];
  if (quoted.isNotEmpty) return quoted;
  final before = line.substring(0, at).trimRight();
  if (!before.endsWith(":")) return const [];
  final fields = before.substring(0, before.length - 1).split(": ");
  return [fields.last.trim()];
}

/// [named] as an absolute path, or null where it is not one. A name with no
/// slash is left out: `ps: Operation not permitted` and `execvp() of 'ps'`
/// name a program, not a write, and a bare file name is what that looks like.
/// Not `resolveWorkspacePath`: a command's relative path is from where it
/// stood, `..` included, not a file-tool path under the workspace.
String? _absolute(String named, String cwd, String? home) {
  if (!named.contains("/") || named.contains(RegExp(r"[\x00-\x1f]"))) {
    return null;
  }
  if (named == "~" || named.startsWith("~/")) {
    return home == null ? null : p.normalize(home + named.substring(1));
  }
  return p.normalize(p.isAbsolute(named) ? named : p.join(cwd, named));
}
