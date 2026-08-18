import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:archive/archive.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/backup.dart";

import "../harness.dart";

void main() {
  late AppConfig config;

  setUp(() => config = tempConfig());

  void write(String relative, String text) {
    final file = File("${config.dataDir}/$relative");
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  void writeBytes(String relative, List<int> bytes) {
    final file = File("${config.dataDir}/$relative");
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
  }

  Future<Archive> archive() async =>
      ZipDecoder().decodeBytes(await writeBackup(config));

  Future<Backup> roundTrip() async => parseBackup(await writeBackup(config));

  test("a file is a member at the path it has under the data directory",
      () async {
    write("chats/abc/conv.jsonl", '{"type":"message"}\n');

    final member = (await archive()).findFile("chats/abc/conv.jsonl");

    expect(utf8.decode(member!.readBytes()!), '{"type":"message"}\n');
  });

  test("the manifest says what the file is", () async {
    final manifest = jsonDecode(
        utf8.decode((await archive()).findFile(manifestName)!.readBytes()!));

    expect(manifest["format"], backupFormat);
    expect(manifest["version"], backupVersion);
    expect(DateTime.tryParse(manifest["createdAt"] as String), isNotNull);
  });

  test("a half-written file is left out", () async {
    write("settings.json.writing", "torn");

    expect((await archive()).findFile("settings.json.writing"), isNull);
  });

  test("an empty folder is a member, since no file names it", () async {
    Directory("${config.dataDir}/workspace/empty").createSync(recursive: true);

    final member = (await archive()).files.firstWhere(
        (f) => f.name == "workspace/empty" || f.name == "workspace/empty/");

    expect(member.isDirectory, isTrue);
  });

  test("what is on disk comes back byte for byte", () async {
    write("settings.json", '{"appTheme":"dark"}');
    write("chats/abc/conv.jsonl", '{"type":"message"}\n{"type":"turnEnd"}\n');
    writeBytes("chats/abc/resources/pic.png", [0x89, 0x50, 0xff, 0xfe]);
    Directory("${config.dataDir}/chats/abc/workspace").createSync(recursive: true);

    final backup = await roundTrip();
    Directory(config.dataDir).deleteSync(recursive: true);
    Directory(config.dataDir).createSync(recursive: true);
    await restoreBackup(config, backup);

    expect(File("${config.dataDir}/settings.json").readAsStringSync(),
        '{"appTheme":"dark"}');
    expect(File("${config.dataDir}/chats/abc/conv.jsonl").readAsStringSync(),
        '{"type":"message"}\n{"type":"turnEnd"}\n');
    expect(File("${config.dataDir}/chats/abc/resources/pic.png").readAsBytesSync(),
        [0x89, 0x50, 0xff, 0xfe]);
    expect(Directory("${config.dataDir}/chats/abc/workspace").existsSync(), isTrue);
  });

  test("the manifest is not restored as a file of its own", () async {
    await restoreBackup(config, await roundTrip());

    expect(File("${config.dataDir}/$manifestName").existsSync(), isFalse);
  });

  test("a restore replaces rather than merges", () async {
    write("chats/kept/state.json", "{}");
    final backup = await roundTrip();
    write("chats/later/state.json", "{}");

    await restoreBackup(config, backup);

    expect(Directory("${config.dataDir}/chats/kept").existsSync(), isTrue);
    expect(Directory("${config.dataDir}/chats/later").existsSync(), isFalse);
  });

  test("the directories the app needs are there whatever the backup held",
      () async {
    final backup = await roundTrip();

    await restoreBackup(config, backup);

    expect(Directory(config.chatsDir()).existsSync(), isTrue);
    expect(Directory(config.projectWorkspaceDir()).existsSync(), isTrue);
  });

  test("chats are counted from the state.json each one has", () async {
    write("chats/a/state.json", "{}");
    write("projects/work/chats/b/state.json", "{}");
    write("chats/a/conv.jsonl", "{}");

    expect((await roundTrip()).chats, 2);
  });

  // The point of the zip over one JSON document holding every file: a
  // conversation is text, and text deflates.
  test("a conversation is smaller in the backup than it is on disk", () async {
    write("chats/a/conv.jsonl", '{"type":"append","text":"hello"}\n' * 200);

    expect((await writeBackup(config)).length,
        lessThan(File("${config.dataDir}/chats/a/conv.jsonl").lengthSync()));
  });

  group("what it refuses", () {
    Uint8List zipOf(Object? manifest) {
      final archive = Archive()..add(ArchiveFile.string("settings.json", "{}"));
      if (manifest != null) {
        archive.add(ArchiveFile.string(manifestName, jsonEncode(manifest)));
      }
      return ZipEncoder().encodeBytes(archive);
    }

    test("something that is not a zip", () {
      expect(
        () => parseBackup(Uint8List.fromList("not a zip".codeUnits)),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test("a zip with no manifest in it", () {
      expect(() => parseBackup(zipOf(null)), throwsA(isA<BackupFormatException>()));
    });

    test("a manifest that names another format", () {
      expect(
        () => parseBackup(zipOf({"format": "something-else", "version": 1})),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test("one from a newer Entoli", () {
      expect(
        () => parseBackup(zipOf({"format": backupFormat, "version": backupVersion + 1})),
        throwsA(isA<BackupFormatException>()),
      );
    });

    // A zip is a file someone can build by hand, so a member's name is treated
    // the way a shared file's path is.
    test("a member that would climb out of the data directory", () async {
      final archive = Archive()
        ..add(ArchiveFile.string(
            manifestName, jsonEncode({"format": backupFormat, "version": backupVersion})))
        ..add(ArchiveFile.string("../../escaped.json", "no"));

      await restoreBackup(config, parseBackup(ZipEncoder().encodeBytes(archive)));

      expect(File("${config.dataDir}/escaped.json").existsSync(), isTrue);
      expect(File("${config.dataDir}/../../escaped.json").existsSync(), isFalse);
    });
  });

  test("the filename carries the day and the time", () {
    expect(backupFilename(DateTime(2026, 8, 18, 9, 5)),
        "entoli-backup-2026-08-18-0905.zip");
  });
}
