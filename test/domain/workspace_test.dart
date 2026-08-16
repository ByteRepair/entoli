import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;

import "package:agent_chat/domain/workspace.dart";

import "../fakes.dart";
import "../harness.dart";

void main() {
  late String dir;

  setUp(() => dir = tempConfig().projectWorkspaceDir());

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
