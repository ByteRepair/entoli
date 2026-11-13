import "dart:io";

import "package:path/path.dart" as p;

import "../../core/log.dart";
import "../../domain/shell.dart" show isTildePath, repositoryRootOf;
import "../../domain/shell_command_analysis.dart" show plainCommand;
import "local_shell.dart" show LocalShell;

/// The caches developer tools write to as a matter of course, under the
/// machine user's [home]: a package fetch, a build's derived data, a
/// compiler's own scratch. A sandboxed command that cannot write them fails
/// before it has done anything the sandbox exists to stop — `flutter test`
/// dies stamping its engine, `npm install` on its cache — and the only way
/// on was to leave the sandbox entirely, which grants far more than a cache.
/// Only those that exist are named: a grant to a directory nobody made is
/// one a tool would have to make outside the grant first anyway.
///
/// [path] is `PATH`, read for the SDKs that keep a cache inside their own
/// install (Flutter's `bin/cache`), and [environment] for the variables a
/// user moves a cache with.
List<String> toolchainCaches({
  required String? home,
  required String path,
  Map<String, String> environment = const {},
}) {
  final candidates = <String>[
    if (home != null) ...[
      p.join(home, ".cache"),
      p.join(home, "Library", "Caches"),
      p.join(home, "Library", "Developer", "Xcode", "DerivedData"),
      p.join(home, ".pub-cache"),
      p.join(home, ".dartServer"),
      p.join(home, ".dart-tool"),
      p.join(home, ".flutter"),
      p.join(home, ".flutter-devtools"),
      p.join(home, ".npm"),
      p.join(home, ".yarn"),
      p.join(home, ".pnpm-store"),
      p.join(home, ".bun", "install", "cache"),
      p.join(home, ".cargo", "registry"),
      p.join(home, ".cargo", "git"),
      p.join(home, ".rustup", "tmp"),
      p.join(home, ".gradle"),
      p.join(home, ".m2", "repository"),
      p.join(home, "go", "pkg", "mod"),
      p.join(home, ".cocoapods"),
    ],
    ?environment["PUB_CACHE"],
    ?environment["GOMODCACHE"],
    ?environment["npm_config_cache"],
    ?environment["CARGO_HOME"],
    ?_flutterCache(path),
  ];
  final seen = <String>{};
  return [
    for (final dir in candidates)
      if (Directory(dir).existsSync() && seen.add(p.normalize(dir)))
        p.normalize(dir),
  ];
}

/// The `bin/cache` of the Flutter SDK first on [path], resolved through the
/// symlink a package manager puts on `PATH` (Homebrew's `/opt/homebrew/bin`).
/// Flutter writes its engine stamp there on every run, `flutter test`
/// included.
String? _flutterCache(String path) {
  for (final dir in path.split(LocalShell.listSeparator())) {
    if (dir.isEmpty) continue;
    final link = File(
      p.join(dir, Platform.isWindows ? "flutter.bat" : "flutter"),
    );
    if (!link.existsSync()) continue;
    try {
      final real = link.resolveSymbolicLinksSync();
      final cache = p.join(p.dirname(real), "cache");
      return Directory(cache).existsSync() ? cache : null;
    } on FileSystemException {
      return null;
    }
  }
  return null;
}

/// The git directories of the repositories [dirs] stand in, those outside
/// [granted]: a checkout's own `.git`, and a worktree's repository, which
/// its commits land in. Only the metadata is granted, never the
/// repository's own files, so a sandboxed `git commit` lands where the
/// tree it commits stays read-only.
///
/// Read from the files git leaves — a worktree's `.git` file names its
/// gitdir, and that gitdir's `commondir` names the repository's — rather
/// than by running git per command.
List<String> repositoryGitDirs(Iterable<String> dirs, List<String> granted) {
  bool inGrant(String path) =>
      granted.any((g) => p.equals(g, path) || p.isWithin(g, path));
  final found = <String>{};
  for (final dir in dirs) {
    final at = repositoryRootOf(dir);
    if (at == null) continue;
    final gitDir = _gitDirOf(p.join(at, ".git"));
    if (gitDir != null && !inGrant(gitDir)) found.add(gitDir);
  }
  return found.toList();
}

String? _gitDirOf(String dotGit) {
  switch (FileSystemEntity.typeSync(dotGit, followLinks: false)) {
    case FileSystemEntityType.directory:
      return dotGit;
    case FileSystemEntityType.file:
      try {
        final line = File(
          dotGit,
        ).readAsLinesSync().firstWhere((l) => l.startsWith("gitdir:"));
        final gitdir = p.normalize(
          p.join(p.dirname(dotGit), line.substring("gitdir:".length).trim()),
        );
        final common = File(p.join(gitdir, "commondir"));
        return common.existsSync()
            ? p.normalize(p.join(gitdir, common.readAsStringSync().trim()))
            : gitdir;
      } on Object {
        return null;
      }
    default:
      return null;
  }
}

/// Where a command works: [standing], each `cd` it makes, and each
/// `git -C` it names, read off [segments]' plain words and resolved against
/// the directory the command stands in at that point. [resolve] reads `~`.
List<String> commandDirs(
  List<String>? segments,
  String standing,
  String Function(String path) resolve,
) {
  var at = standing;
  String full(String path) => isTildePath(path)
      ? resolve(path)
      : p.normalize(p.isAbsolute(path) ? path : p.join(at, path));
  final dirs = [standing];
  for (final segment in segments ?? const <String>[]) {
    final words = plainCommand(segment)?.words;
    if (words == null || words.isEmpty) continue;
    if (words.length == 2 && words[0] == "cd") {
      at = full(words[1]);
      dirs.add(at);
    } else if (words[0] == "git") {
      for (var i = 1; i < words.length - 1; i++) {
        if (words[i] == "-C") dirs.add(full(words[i + 1]));
      }
    }
  }
  return dirs;
}

/// Where toolchains keep what they download under the machine user's
/// [home], those that exist: uv's interpreters and tool environments, and
/// rustup's toolchains. A `uv run --python 3.12` fetches its interpreter
/// here, and denied it, the run left the sandbox for a download. Nothing on
/// `PATH` is here — `~/.cargo/bin`, nvm's or pyenv's shims — since a
/// program swapped there would be run later, unsandboxed, by the user.
List<String> toolchainHomes({required String? home}) {
  if (home == null) return const [];
  return [
    for (final dir in const [
      [".local", "share", "uv"],
      [".rustup"],
    ])
      if (Directory(p.joinAll([home, ...dir])).existsSync())
        p.joinAll([home, ...dir]),
  ];
}

/// The machine's own temp folders, which every confined command may write:
/// `/private/tmp` and the per-user folder `getconf DARWIN_USER_TEMP_DIR`
/// names on macOS, `/tmp` and `/var/tmp` where they exist on Linux, and
/// nothing on a platform whose sandbox Entoli does not enforce. `TMPDIR`
/// still names the chat's own tmp, but the tools a build reaches for most do
/// not ask it: macOS's `mktemp` prefers the per-user folder to `TMPDIR`, as
/// its manual says, and the system's bash 3.2 writes a here document to
/// `/var/tmp` or `/tmp` and else the working directory, never to `TMPDIR`.
/// Denied, each failed wherever a command stood outside the workspace.
///
/// Found once per process — the folders are the user's and do not move —
/// and held as a future, so the first commands of parallel sub-agents share
/// one `getconf` rather than racing to spawn their own.
Future<List<String>> systemTemps() => _systemTemps ??= _findSystemTemps();

Future<List<String>>? _systemTemps;

Future<List<String>> _findSystemTemps() async {
  if (Platform.isMacOS) return ["/private/tmp", ?await _darwinUserTemp()];
  if (Platform.isLinux) {
    return [
      for (final dir in const ["/tmp", "/var/tmp"])
        if (Directory(dir).existsSync()) dir,
    ];
  }
  return const [];
}

/// The per-user temp folder, or null where `getconf` will not say — then
/// `/private/tmp` is granted alone.
Future<String?> _darwinUserTemp() async {
  Object reason;
  try {
    final result = await Process.run("/usr/bin/getconf", [
      "DARWIN_USER_TEMP_DIR",
    ]);
    final out = "${result.stdout}".trim();
    if (result.exitCode == 0 && out.isNotEmpty) return out;
    reason = "getconf exited ${result.exitCode}";
  } on Exception catch (e) {
    reason = e;
  }
  logFailure("sandbox", "the per-user temp folder is not known", reason);
  return null;
}
