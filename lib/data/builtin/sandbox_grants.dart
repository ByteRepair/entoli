import "dart:io";

import "package:path/path.dart" as p;

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

/// Where a git worktree under [granted] keeps its objects and refs, where
/// that is outside every one of them: a worktree made in the chat's
/// workspace from a repository elsewhere writes its commits into that
/// repository's `.git`, so a sandboxed `git commit` in a worktree the chat
/// owns failed on a directory it was never meant to own. Only the repository
/// metadata is granted, never the repository's own files.
///
/// [dir] is where the commands stand. Read from the files git leaves — the
/// worktree's `.git` file names its gitdir, and that gitdir's `commondir`
/// names the repository's — rather than by running git per command.
String? worktreeGitDir(String dir, List<String> granted) {
  bool inGrant(String path) =>
      granted.any((g) => p.equals(g, path) || p.isWithin(g, path));
  var at = p.normalize(dir);
  while (true) {
    final dotGit = p.join(at, ".git");
    final type = FileSystemEntity.typeSync(dotGit, followLinks: false);
    if (type == FileSystemEntityType.directory) return null;
    if (type == FileSystemEntityType.file) {
      if (!inGrant(at)) return null;
      try {
        final line = File(
          dotGit,
        ).readAsLinesSync().firstWhere((l) => l.startsWith("gitdir:"));
        final gitdir = p.normalize(
          p.join(at, line.substring("gitdir:".length).trim()),
        );
        final common = File(p.join(gitdir, "commondir"));
        final root = common.existsSync()
            ? p.normalize(p.join(gitdir, common.readAsStringSync().trim()))
            : gitdir;
        return inGrant(root) ? null : root;
      } on Object {
        return null;
      }
    }
    final parent = p.dirname(at);
    if (parent == at) return null;
    at = parent;
  }
}
