import "dart:io";

import "package:archive/archive.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;
import "package:agent_chat/data/zip.dart";
import "package:file/local.dart";
import "package:entoli_chat/data/zip.dart";

import "../harness.dart";

void main() {
  late String dir;

  setUp(() => dir = tempConfig().projectWorkspaceDir());

  Future<Archive> unzip(List<String> paths) async {
    final out = "${tempDir().path}/out.zip";
    await zipTo(out, paths);
    return ZipDecoder().decodeBytes(File(out).readAsBytesSync());
  }

  test("a file is named without the folder it came out of", () async {
    File("$dir/a.txt").writeAsStringSync("one");

    final archive = await unzip(["$dir/a.txt"]);

    expect(archive.files.map((f) => f.name), ["a.txt"]);
    expect(String.fromCharCodes(archive.findFile("a.txt")!.content), "one");
  });

  // The point of naming entries relative to the folder's own parent: unzipping
  // gives the folder back rather than spilling its contents.
  test("a folder keeps its shape, all the way down", () async {
    Directory("$dir/notes/today").createSync(recursive: true);
    File("$dir/notes/today/a.txt").writeAsStringSync("deep");
    File("$dir/notes/b.txt").writeAsStringSync("shallow");

    final archive = await unzip(["$dir/notes"]);

    expect(
      archive.files.map((f) => f.name).where((n) => n.endsWith(".txt")).toSet(),
      {"notes/today/a.txt", "notes/b.txt"},
    );
  });

  test("an empty folder is still in the archive", () async {
    Directory("$dir/nothing").createSync();

    final archive = await unzip(["$dir/nothing"]);

    expect(archive.files, isNotEmpty);
  });

  test("zipNameFor: one folder names itself, several their parent", () {
    expect(zipNameFor(["$dir/notes"]), "notes.zip");
    expect(zipNameFor(["$dir/a.txt", "$dir/sub"]), "workspace.zip");
  });

  test("a selection of several goes in as several", () async {
    File("$dir/a.txt").writeAsStringSync("a");
    Directory("$dir/sub").createSync();
    File("$dir/sub/b.txt").writeAsStringSync("b");

    final archive = await unzip(["$dir/a.txt", "$dir/sub"]);

    expect(
      archive.files.map((f) => f.name).where((n) => n.endsWith(".txt")).toSet(),
      {"a.txt", "sub/b.txt"},
    );
  });

  test("a link is followed, unless the walk is told not to", () async {
    final outside = tempDir().path;
    File("$outside/target.txt").writeAsStringSync("linked");
    Directory("$dir/tree").createSync();
    Link("$dir/tree/file.txt").createSync("$outside/target.txt");
    Link("$dir/tree/folder").createSync(outside);
    Link("$dir/tree/broken").createSync("$outside/missing");

    final archive = await unzip(["$dir/tree"]);
    expect(
      String.fromCharCodes(archive.findFile("tree/file.txt")!.content),
      "linked",
    );
    expect(archive.findFile("tree/folder/target.txt"), isNotNull);
    expect(archive.findFile("tree/broken"), isNull);

    final unfollowed = [
      await for (final e in walkTree(const LocalFileSystem(), [
        "$dir/tree",
      ], followLinks: false))
        e.name,
    ];
    expect(unfollowed, ["tree"]);
  });

  test(
    "a link back up its own tree ends, and a second way in does not",
    () async {
      final shared = tempDir().path;
      File("$shared/s.txt").writeAsStringSync("s");
      Directory("$dir/tree/sub").createSync(recursive: true);
      File("$dir/tree/sub/a.txt").writeAsStringSync("a");
      Link("$dir/tree/sub/up").createSync("$dir/tree");
      Link("$dir/tree/one").createSync(shared);
      Link("$dir/tree/two").createSync(shared);
      Link("$shared/self").createSync(shared);

      final archive = await unzip(["$dir/tree"]);

      expect(
        archive.files
            .map((f) => f.name)
            .where((n) => n.endsWith(".txt"))
            .toSet(),
        {"tree/sub/a.txt", "tree/one/s.txt", "tree/two/s.txt"},
      );
    },
  );

  test("unfollowed, a link handed in as a path is no member either", () async {
    final outside = tempDir().path;
    File("$outside/s.txt").writeAsStringSync("s");
    Link("$dir/folder").createSync(outside);
    Link("$dir/file.txt").createSync("$outside/s.txt");

    final names = [
      await for (final e in walkTree(const LocalFileSystem(), [
        "$dir/folder",
        "$dir/file.txt",
      ], followLinks: false))
        e.name,
    ];

    expect(names, isEmpty);
  });

  test("a link into a skipped folder is skipped where it lands", () async {
    Directory("$dir/tree/secret").createSync(recursive: true);
    File("$dir/tree/secret/key").writeAsStringSync("k");
    Directory("$dir/tree/work").createSync();
    Link("$dir/tree/work/keys").createSync("$dir/tree/secret");

    final names = [
      await for (final e in walkTree(
        const LocalFileSystem(),
        ["$dir/tree"],
        base: "$dir/tree",
        skipDir: (path) => p.equals(path, "$dir/tree/secret"),
      ))
        e.name,
    ];

    expect(names, ["work"]);
  });
}
