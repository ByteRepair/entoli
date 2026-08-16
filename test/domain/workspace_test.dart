import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:fs_shim/fs.dart" show FileSystemException;
import "package:fs_shim/fs_io.dart" show fileSystemIo;

import "package:agent_chat/core/config.dart";
import "package:agent_chat/domain/file_handoff.dart";
import "package:agent_chat/domain/workspace.dart";

import "../fakes.dart";
import "../harness.dart";

void main() {
  late AppConfig config;
  late String dir;

  setUp(() {
    config = tempConfig();
    dir = config.projectWorkspaceDir();
  });

  group("listing", () {
    test("folders come before files, each by name", () async {
      Directory("$dir/zeta").createSync();
      Directory("$dir/alpha").createSync();
      File("$dir/b.txt").writeAsStringSync("b");
      File("$dir/a.txt").writeAsStringSync("a");

      final entries = await listWorkspace(fileSystemIo, dir);

      expect(entries.map((e) => e.name), ["alpha", "zeta", "a.txt", "b.txt"]);
      expect(entries.map((e) => e.isDirectory), [true, true, false, false]);
    });

    test("names are sorted without regard to case", () async {
      for (final name in ["Beta.txt", "alpha.txt", "Charlie.txt"]) {
        File("$dir/$name").writeAsStringSync("x");
      }

      final entries = await listWorkspace(fileSystemIo, dir);

      expect(entries.map((e) => e.name), ["alpha.txt", "Beta.txt", "Charlie.txt"]);
    });

    test("a file carries its size and a folder does not", () async {
      File("$dir/a.txt").writeAsStringSync("hello");
      Directory("$dir/sub").createSync();

      final entries = await listWorkspace(fileSystemIo, dir);

      expect(entries.singleWhere((e) => e.name == "a.txt").size, 5);
      expect(entries.singleWhere((e) => e.name == "sub").size, 0);
    });

    // A workspace is created with the chat and may never be written to, so a
    // missing one is empty rather than a page that fails to draw.
    test("a folder that is not there is empty", () async {
      expect(await listWorkspace(fileSystemIo, "$dir/never-made"), isEmpty);
    });
  });

  group("writing what arrived", () {
    test("a path creates the folders it names", () async {
      await writeIncoming(fileSystemIo, dir, [incomingFile("notes/today/a.txt", "one")]);

      expect(File("$dir/notes/today/a.txt").readAsStringSync(), "one");
    });

    test("several files land together", () async {
      await writeIncoming(fileSystemIo, dir, [incomingFile("a.txt", "a"), incomingFile("b.txt", "b")]);

      expect(File("$dir/a.txt").readAsStringSync(), "a");
      expect(File("$dir/b.txt").readAsStringSync(), "b");
    });

    // The name was written by whatever app shared the file, which is why it is
    // sanitised on the way in rather than trusted.
    test("a path climbing out of the workspace is written inside it", () async {
      await writeIncoming(fileSystemIo, dir, [incomingFile("../../settings.json", "stolen")]);

      expect(File("$dir/settings.json").readAsStringSync(), "stolen");
      expect(File(fileSystemIo.path.join(dir, "..", "..", "settings.json")).existsSync(), isFalse);
    });

    test("an absolute path is written inside it too", () async {
      await writeIncoming(fileSystemIo, dir, [incomingFile("/etc/passwd", "nope")]);

      expect(File("$dir/etc/passwd").readAsStringSync(), "nope");
    });
  });

  /// What the platform staged is moved, not read: a share of twenty photos
  /// would otherwise be twenty photos of heap for as long as the user takes to
  /// pick a workspace.
  group("what the platform staged", () {
    late String staging;

    setUp(() {
      staging = "${config.dataDir}/staged";
      Directory(staging).createSync(recursive: true);
    });

    /// Staged flat and named by its basename, the way Android's cache holds
    /// one, then offered under the workspace path it asked for.
    IncomingStaged staged(String path, [String text = "hi"]) {
      final file = File("$staging/${fileSystemIo.path.basename(path)}")
        ..writeAsStringSync(text);
      return IncomingStaged(path, file.path);
    }

    test("is moved, not copied", () async {
      final file = staged("shared.txt", "from elsewhere");
      await writeIncoming(fileSystemIo, dir, [file]);

      expect(File("$dir/shared.txt").readAsStringSync(), "from elsewhere");
      expect(File(file.staged).existsSync(), isFalse);
    });

    // The folder has to exist before a rename can land in it, which a write
    // would have created on its own.
    test("keeps the folder its name asks for", () async {
      await writeIncoming(fileSystemIo, dir, [staged("notes/a.txt", "deep")]);

      expect(File("$dir/notes/a.txt").readAsStringSync(), "deep");
    });

    // `fs_shim` raises its own `FileSystemException` rather than `dart:io`'s,
    // which is what the move's fallback to a copy catches. Pinned because the
    // wrong type there would leave the fallback dead and look like nothing.
    test("a staged copy that is no longer there is reported, not skipped", () {
      expect(
        writeIncoming(fileSystemIo, dir, [IncomingStaged("gone.txt", "$staging/gone.txt")]),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group("making a folder", () {
    test("a name becomes one", () async {
      await createFolder(fileSystemIo, dir, "notes");

      expect(Directory("$dir/notes").existsSync(), isTrue);
    });

    test("one that is already there is left alone", () async {
      File("$dir/notes/a.txt")
        ..createSync(recursive: true)
        ..writeAsStringSync("a");

      await createFolder(fileSystemIo, dir, "notes");

      expect(File("$dir/notes/a.txt").readAsStringSync(), "a");
    });
  });

  group("deleting", () {
    test("a file goes and its neighbours stay", () async {
      File("$dir/a.txt").writeAsStringSync("a");
      File("$dir/b.txt").writeAsStringSync("b");

      await deleteEntries(fileSystemIo, ["$dir/a.txt"]);

      expect(File("$dir/a.txt").existsSync(), isFalse);
      expect(File("$dir/b.txt").existsSync(), isTrue);
    });

    test("a folder goes with everything in it", () async {
      File("$dir/src/deep/main.dart").createSync(recursive: true);

      await deleteEntries(fileSystemIo, ["$dir/src"]);

      expect(Directory("$dir/src").existsSync(), isFalse);
    });

    // The listing under a selection is re-read, and the agent writes to the
    // same folder — so a path can be gone by the time this runs.
    test("one that is already gone is a deletion that happened", () async {
      File("$dir/a.txt").writeAsStringSync("a");

      await deleteEntries(fileSystemIo, ["$dir/never-was", "$dir/a.txt"]);

      expect(File("$dir/a.txt").existsSync(), isFalse);
    });
  });

  group("safeRelativePath", () {
    test("keeps a folder", () {
      expect(safeRelativePath(fileSystemIo, "notes/today/a.txt"), "notes/today/a.txt");
    });

    test("drops the segments that would climb", () {
      expect(safeRelativePath(fileSystemIo, "../a/../../b.txt"), "a/b.txt");
    });

    test("a path with nothing left in it is still a name", () {
      expect(safeRelativePath(fileSystemIo, "../.."), "file");
    });

    test("takes the separator a Windows share would use", () {
      expect(safeRelativePath(fileSystemIo, r"notes\today\a.txt"), "notes/today/a.txt");
    });
  });
}
