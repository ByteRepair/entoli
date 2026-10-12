import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:fs_shim/fs.dart" show FileSystem;
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:path/path.dart" as p;

import "package:agent_chat/domain/command_grants.dart";
import "package:agent_chat/domain/safe_command.dart";

FileSystem get fs => fileSystemIo;

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync("agent-grants-test");
    addTearDown(() => root.deleteSync(recursive: true));
  });

  /// A minimal repository at [path]: a `.git` directory with the children a
  /// checkout carries, so the enumeration has something honest to answer
  /// with.
  String makeRepo(String path, {bool hooks = true}) {
    Directory(p.join(path, ".git", "objects")).createSync(recursive: true);
    Directory(p.join(path, ".git", "refs")).createSync(recursive: true);
    File(
      p.join(path, ".git", "HEAD"),
    ).writeAsStringSync("ref: refs/heads/master\n");
    File(p.join(path, ".git", "index")).writeAsStringSync("");
    File(p.join(path, ".git", "config")).writeAsStringSync("[core]\n");
    if (hooks) {
      Directory(p.join(path, ".git", "hooks")).createSync();
    }
    return path;
  }

  Future<CommandGrants> assess(String command, {String? cwd}) async {
    final segments = command.split("&&").map((s) => s.trim()).toList();
    return commandGrantsFor(
      CommandGrantsInput(
        fs: fs,
        start: cwd ?? root.path,
        home: root.path,
        segments: segments,
      ),
    );
  }

  /// Whether every segment has a deterministic cover: provably
  /// non-modifying, or carried by a grant. What the gate's tier loop says,
  /// said here so the tests read the answer and not the machinery.
  bool covered(CommandGrants grants) {
    for (var i = 0; i < grants.profiles.length; i++) {
      final covered = grants.profiles[i].reach == SegmentReach.nonModifying ||
          grants.gitGrants.containsKey(i);
      if (!covered) return false;
    }
    return grants.profiles.isNotEmpty;
  }

  test(
    "a git mutation in a repo is vouched with its .git beside the grant",
    () async {
      final repo = makeRepo(p.join(root.path, "repo"));
      final grants = await assess("git commit -m x", cwd: repo);
      expect(grants.gitGrants, hasLength(1));
      final grant = grants.gitGrants.values.single;
      expect(grant.gitDir, p.join(repo, ".git"));
      // The children are the grant; the config and hooks are not.
      expect(grant.paths, contains(p.join(repo, ".git", "objects")));
      expect(grant.paths, contains(p.join(repo, ".git", "index")));
      expect(grant.paths.map(p.basename), isNot(contains("config")));
      expect(grant.paths.map(p.basename), isNot(contains("hooks")));
      expect(covered(grants), isTrue);
    },
  );

  test("vouch runs from a subdirectory by walking up", () async {
    final repo = makeRepo(p.join(root.path, "repo"));
    final inRepo = p.join(repo, "lib");
    Directory(inRepo).createSync();
    final grants = await assess("git add .", cwd: inRepo);
    expect(grants.gitGrants.values.single.gitDir, p.join(repo, ".git"));
  });

  test("no repo above, no vouch — the banner path decides", () async {
    final grants = await assess("git commit -m x");
    expect(grants.gitGrants, isEmpty);
  });

  test(
    "the destructive and redirecting subcommands are never vouched",
    () async {
      for (final command in [
        "git push origin master",
        "git reset --hard HEAD",
        "git clean -fd",
        "git checkout master",
        "git config user.email a@b",
        "git -c core.fsmonitor=x commit -m x",
        "git tag v1.0",
        "git branch feature",
      ]) {
        final grants = await assess(
          command,
          cwd: makeRepo(p.join(root.path, "repo")),
        );
        expect(grants.gitGrants, isEmpty, reason: command);
        expect(covered(grants), isFalse, reason: command);
      }
    },
  );

  test(
    "a linked worktree is vouched against the main repository's .git",
    () async {
      final main = makeRepo(p.join(root.path, "main"));
      final wt = p.join(root.path, "wt");
      Directory(wt).createSync();
      // The pointer file a `git worktree add` leaves, as git writes it.
      File(p.join(wt, ".git")).writeAsStringSync(
        "gitdir: ${p.join(main, ".git", "worktrees", "wt")}\n",
      );
      final grants = await assess("git commit -m x", cwd: wt);
      final grant = grants.gitGrants.values.single;
      expect(grant.gitDir, p.join(main, ".git"));
      expect(grant.paths, contains(p.join(main, ".git", "refs")));
      expect(covered(grants), isTrue);
    },
  );

  test(
    "a `cd` the tracker can follow moves the repo a vouch answers for",
    () async {
      makeRepo(p.join(root.path, "repo"));
      Directory(p.join(root.path, "repo", "lib")).createSync();
      final grants = await assess(
        "cd ${p.join(root.path, 'repo', 'lib')} && git commit -m x",
      );
      expect(grants.gitGrants, hasLength(1));
      expect(covered(grants), isTrue);
    },
  );

  test("a `cd` the tracker cannot name loses the vouch", () async {
    // The repo sits where the shell starts, so a tracker that wrongly kept
    // going through an unnameable `cd` would vouch a grant for it.
    final repo = makeRepo(p.join(root.path, "repo"));
    for (final command in [
      "cd \$WHEREVER && git commit -m x",
      "cd /not/a/place && git commit -m x",
      "cd - && git commit -m x",
      "popd && git commit -m x",
    ]) {
      final grants = await assess(command, cwd: repo);
      expect(grants.gitGrants, isEmpty, reason: command);
      expect(covered(grants), isFalse, reason: command);
    }
  });

  test(
    "read-only segments need no grant; a compound covers each of them",
    () async {
      final repo = makeRepo(p.join(root.path, "repo"));
      final grants = await assess("git status && git commit -m x", cwd: repo);
      expect(
        grants.gitGrants,
        hasLength(1),
        reason: "only the mutating segment is vouched",
      );
      expect(covered(grants), isTrue);
    },
  );
}
