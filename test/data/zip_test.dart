import "dart:io";

import "package:archive/archive.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/zip.dart";

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
}
