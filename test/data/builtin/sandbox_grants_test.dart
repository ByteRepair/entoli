import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/data/builtin/sandbox_grants.dart";

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory(
      Directory.systemTemp
          .createTempSync("agent_chat_grants_")
          .resolveSymbolicLinksSync(),
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group("toolchain caches", () {
    test("names the caches under home that exist, and only those", () {
      final home = p.join(tmp.path, "home");
      Directory(p.join(home, ".pub-cache")).createSync(recursive: true);
      Directory(p.join(home, ".gradle")).createSync(recursive: true);

      final dirs = toolchainCaches(home: home, path: "");

      expect(dirs, [p.join(home, ".pub-cache"), p.join(home, ".gradle")]);
    });

    test("a cache moved by its variable is the one named", () {
      final pub = Directory(p.join(tmp.path, "pub"))..createSync();

      final dirs = toolchainCaches(
        home: null,
        path: "",
        environment: {"PUB_CACHE": pub.path},
      );

      expect(dirs, [pub.path]);
    });

    test("Flutter's own bin/cache, through the link on PATH", () {
      // Homebrew's shape: `bin/flutter` on PATH links into the SDK, whose
      // `bin/cache` is where every run stamps its engine.
      final sdk = Directory(p.join(tmp.path, "sdk", "flutter", "bin"))
        ..createSync(recursive: true);
      File(p.join(sdk.path, "flutter")).writeAsStringSync("");
      Directory(p.join(sdk.path, "cache")).createSync();
      final onPath = Directory(p.join(tmp.path, "brew", "bin"))
        ..createSync(recursive: true);
      Link(
        p.join(onPath.path, "flutter"),
      ).createSync(p.join(sdk.path, "flutter"));

      final dirs = toolchainCaches(home: null, path: onPath.path);

      expect(dirs, [p.join(sdk.path, "cache")]);
    }, skip: Platform.isWindows ? "a link on PATH is the POSIX shape" : null);
  });

  group("a worktree's repository", () {
    late String workspace;
    late String repo;

    setUp(() {
      workspace = p.join(tmp.path, "workspace");
      repo = p.join(tmp.path, "repo");
      final gitdir = p.join(repo, ".git", "worktrees", "tree");
      Directory(gitdir).createSync(recursive: true);
      File(p.join(gitdir, "commondir")).writeAsStringSync("../..\n");
      final tree = Directory(p.join(workspace, "tree", "lib"))
        ..createSync(recursive: true);
      File(
        p.join(tree.parent.path, ".git"),
      ).writeAsStringSync("gitdir: $gitdir\n");
    });

    test("is granted where the worktree is the chat's", () {
      expect(
        worktreeGitDir(p.join(workspace, "tree", "lib"), [workspace]),
        p.join(repo, ".git"),
      );
    });

    test("is not, where the worktree is outside the grant", () {
      expect(
        worktreeGitDir(p.join(workspace, "tree", "lib"), [
          p.join(tmp.path, "other"),
        ]),
        isNull,
      );
    });

    test("an ordinary checkout grants nothing beyond itself", () {
      final checkout = p.join(workspace, "plain");
      Directory(p.join(checkout, ".git")).createSync(recursive: true);
      expect(worktreeGitDir(checkout, [workspace]), isNull);
    });
  });
}
