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

  group("toolchain homes", () {
    test("names the version managers' folders that exist", () {
      final home = p.join(tmp.path, "home");
      Directory(
        p.join(home, ".local", "share", "uv"),
      ).createSync(recursive: true);
      Directory(p.join(home, ".rustup")).createSync(recursive: true);

      expect(toolchainHomes(home: home), [
        p.join(home, ".local", "share", "uv"),
        p.join(home, ".rustup"),
      ]);
    });
  });

  group("a repository's git directory", () {
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

    test("a worktree's is its repository's", () {
      expect(
        repositoryGitDirs([p.join(workspace, "tree", "lib")], [workspace]),
        [p.join(repo, ".git")],
      );
    });

    test("a checkout outside the grant is granted its .git alone", () {
      expect(repositoryGitDirs([p.join(repo, "src")], [workspace]), [
        p.join(repo, ".git"),
      ]);
    });

    test("a checkout inside the grant needs nothing more", () {
      final checkout = p.join(workspace, "plain");
      Directory(p.join(checkout, ".git")).createSync(recursive: true);
      expect(repositoryGitDirs([checkout], [workspace]), isEmpty);
    });
  });

  group("where a command works", () {
    String resolve(String path) => path.replaceFirst("~", "/home/u");

    test("where it stands, each cd, and each git -C", () {
      expect(
        commandDirs(
          ["cd sub", "git -C ../other status", "git -C ~/repo log"],
          "/ws",
          resolve,
        ),
        ["/ws", "/ws/sub", "/ws/other", "/home/u/repo"],
      );
    });

    test("a segment that is not plain text names nothing", () {
      expect(commandDirs([r"cd $DIR"], "/ws", resolve), ["/ws"]);
    });
  });
}
