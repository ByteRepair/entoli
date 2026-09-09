import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:archive/archive.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/backup.dart";
import "package:agent_chat/data/local/tree_ops.dart";

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
    write("projects/default/chats/abc/conv.jsonl", '{"type":"message"}\n');

    final member =
        (await archive()).findFile("projects/default/chats/abc/conv.jsonl");

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
    Directory("${config.projectWorkspaceDir()}/empty").createSync(recursive: true);

    const path = "projects/default/workspace/empty";
    final member = (await archive())
        .files
        .firstWhere((f) => f.name == path || f.name == "$path/");

    expect(member.isDirectory, isTrue);
  });

  test("what is on disk comes back byte for byte", () async {
    write("settings.json", '{"appTheme":"dark"}');
    write("projects/default/chats/abc/conv.jsonl",
        '{"type":"message"}\n{"type":"turnEnd"}\n');
    writeBytes(
        "projects/default/chats/abc/resources/pic.png", [0x89, 0x50, 0xff, 0xfe]);
    Directory(config.workspaceDir("abc")).createSync(recursive: true);

    final backup = await roundTrip();
    Directory(config.dataDir).deleteSync(recursive: true);
    Directory(config.dataDir).createSync(recursive: true);
    await restoreBackup(config, backup);

    expect(File(config.settingsFile).readAsStringSync(), '{"appTheme":"dark"}');
    expect(File(config.convFile("abc")).readAsStringSync(),
        '{"type":"message"}\n{"type":"turnEnd"}\n');
    expect(File("${config.resourcesDir("abc")}/pic.png").readAsBytesSync(),
        [0x89, 0x50, 0xff, 0xfe]);
    expect(Directory(config.workspaceDir("abc")).existsSync(), isTrue);
  });

  test("the manifest is not restored as a file of its own", () async {
    await restoreBackup(config, await roundTrip());

    expect(File("${config.dataDir}/$manifestName").existsSync(), isFalse);
  });

  test("a restore replaces rather than merges", () async {
    write("projects/default/chats/kept/state.json", "{}");
    final backup = await roundTrip();
    write("projects/default/chats/later/state.json", "{}");

    await restoreBackup(config, backup);

    expect(Directory(config.chatDir("kept")).existsSync(), isTrue);
    expect(Directory(config.chatDir("later")).existsSync(), isFalse);
  });

  test("the directories the app needs are there whatever the backup held",
      () async {
    final backup = await roundTrip();

    await restoreBackup(config, backup);

    expect(Directory(config.chatsDir()).existsSync(), isTrue);
    expect(Directory(config.projectWorkspaceDir()).existsSync(), isTrue);
    // A backup carries no `sync/` at all, so a restore is the one path that
    // deletes it and unpacks nothing over it.
    expect(Directory(config.syncDir).existsSync(), isTrue);
  });

  test("a rootfs directory is left out of the backup", () async {
    // A per-project rootfs is a re-fetchable Linux tree that lives under the
    // data dir, and the one a built-in with rootfs isolation puts there holds
    // proot's mode-0000 bind stubs — see `tree_ops.dart`. The walker cannot
    // list those, so `rootfs/` is skipped the way `sync/` is.
    final rootfs = Directory(
        "${config.projectDir(project: "byte-repair")}/rootfs/alpine/opt/skills-bundled");
    rootfs.createSync(recursive: true);
    // The stub: a mode-0000 directory, as proot leaves it on the host.
    Process.runSync("chmod", ["0000", rootfs.path]);
    addTearDown(() => Process.runSync("chmod", ["-R", "u+rwX", rootfs.path]));

    final a = await archive();

    // No member names anything under the rootfs.
    expect(a.files.where((f) => f.name.contains("rootfs/")), isEmpty);
  });

  test("a restore clears a rootfs with mode-0000 stubs via deleteTree", () async {
    // The latent half of the same bug: a restore wipes the data dir first, and
    // a plain `Directory.delete(recursive: true)` dies on a mode-0000 stub the
    // way the walker did. `deleteTree` is the io side's `removeTree`, which
    // `chmod`s past them.
    final rootfs = Directory(
        "${config.projectDir(project: "byte-repair")}/rootfs/alpine/opt/skills");
    rootfs.createSync(recursive: true);
    File("${rootfs.path}/inside.txt").writeAsStringSync("guest file");
    Process.runSync("chmod", ["0000", rootfs.path]);
    addTearDown(() => Process.runSync("chmod", ["-R", "u+rwX", rootfs.path]));

    final backup = await roundTrip();
    Future<void> deleteTree(String path) async {
      final err = await removeTree(path);
      if (err != null) throw Exception("could not delete $path: $err");
    }

    // Without `deleteTree` this throws on the stub; with it, `removeTree`
    // `chmod`s past it and the restore completes.
    await restoreBackup(config, backup, deleteTree: deleteTree);

    expect(rootfs.existsSync(), isFalse);
  });

  test("chats are counted from the state.json each one has", () async {
    write("projects/default/chats/a/state.json", "{}");
    write("projects/work/chats/b/state.json", "{}");
    write("projects/default/chats/a/conv.jsonl", "{}");
    // One the agent wrote, which is why the count matches the layout rather
    // than the name.
    write("projects/default/workspace/chats/a/state.json", "{}");

    expect((await roundTrip()).chats, 2);
  });

  // The point of the zip over one JSON document holding every file: a
  // conversation is text, and text deflates.
  test("a conversation is smaller in the backup than it is on disk", () async {
    write("projects/default/chats/a/conv.jsonl",
        '{"type":"append","text":"hello"}\n' * 200);

    expect((await writeBackup(config)).length,
        lessThan(File(config.convFile("a")).lengthSync()));
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

  test("no key material rides in the archive", () async {
    // A provider key lives only in the secret store, and the store's
    // directory is the one a backup skips — so a backup can be shared
    // without carrying credentials.
    write("sync/secrets.json",
        jsonEncode({"provider-keys": base64Encode(utf8.encode('{"a":"sk-secret"}'))}));

    final zip = ZipDecoder().decodeBytes(await writeBackup(config));

    // Every member decoded, the same idiom the tests above use: a key never
    // rides in the archive, under any name.
    for (final member in zip.files) {
      if (member.isDirectory) continue;
      expect(String.fromCharCodes(member.readBytes()!),
          isNot(contains("sk-secret")), reason: member.name);
    }
    expect(zip.findFile("sync/secrets.json"), isNull);
  });
}
