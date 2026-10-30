import "dart:convert";
import "dart:io";

import "package:archive/archive.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/backup.dart";
import "package:agent_chat/data/local/tree_ops.dart";

import "../harness.dart";

void main() {
  late AppConfig config;
  late Directory out;
  var made = 0;

  setUp(() {
    config = tempConfig();
    out = tempDir("backup_out_");
  });

  /// A backup written the way Export writes one, outside the data directory.
  Future<String> written() async {
    final path = "${out.path}/backup-${made++}.zip";
    await writeBackup(config, path);
    return path;
  }

  Future<Backup> opened(String path) => openBackup(path);

  /// The launch's sweep is unawaited; wait out the tree it is deleting.
  Future<void> settleDeletes(String path) async {
    for (var i = 0; i < 100 && Directory(path).existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

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
      ZipDecoder().decodeBytes(File(await written()).readAsBytesSync());

  Future<Backup> roundTrip() async => opened(await written());

  test(
    "a file is a member at the path it has under the data directory",
    () async {
      write("projects/default/chats/abc/conv.jsonl", '{"type":"message"}\n');

      final member = (await archive()).findFile(
        "projects/default/chats/abc/conv.jsonl",
      );

      expect(utf8.decode(member!.readBytes()!), '{"type":"message"}\n');
    },
  );

  test("the manifest says what the file is", () async {
    final manifest = jsonDecode(
      utf8.decode((await archive()).findFile(manifestName)!.readBytes()!),
    );

    expect(manifest["format"], backupFormat);
    expect(manifest["version"], backupVersion);
    expect(DateTime.tryParse(manifest["createdAt"] as String), isNotNull);
  });

  test("a half-written file is left out", () async {
    write("settings.json.writing", "torn");

    expect((await archive()).findFile("settings.json.writing"), isNull);
  });

  test("an empty folder is a member, since no file names it", () async {
    Directory(
      "${config.projectWorkspaceDir()}/empty",
    ).createSync(recursive: true);

    const path = "projects/default/workspace/empty";
    final member = (await archive()).files.firstWhere(
      (f) => f.name == path || f.name == "$path/",
    );

    expect(member.isDirectory, isTrue);
  });

  test("what is on disk comes back byte for byte", () async {
    write("settings.json", '{"appTheme":"dark"}');
    write(
      "projects/default/chats/abc/conv.jsonl",
      '{"type":"message"}\n{"type":"turnEnd"}\n',
    );
    writeBytes("projects/default/chats/abc/resources/pic.png", [
      0x89,
      0x50,
      0xff,
      0xfe,
    ]);
    Directory(config.workspaceDir("abc")).createSync(recursive: true);

    final backup = await roundTrip();
    Directory(config.dataDir).deleteSync(recursive: true);
    Directory(config.dataDir).createSync(recursive: true);
    await restoreBackup(config, backup);

    expect(File(config.settingsFile).readAsStringSync(), '{"appTheme":"dark"}');
    expect(
      File(config.convFile("abc")).readAsStringSync(),
      '{"type":"message"}\n{"type":"turnEnd"}\n',
    );
    expect(File("${config.resourcesDir("abc")}/pic.png").readAsBytesSync(), [
      0x89,
      0x50,
      0xff,
      0xfe,
    ]);
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

  test(
    "a restore that fails on the way leaves the data directory as it was",
    () async {
      write("projects/default/chats/kept/state.json", "{}");
      final backup = await roundTrip();
      write("projects/default/chats/later/state.json", "{}");

      // The file goes between the confirm and the restore reading it.
      File(backup.path).deleteSync();

      await expectLater(restoreBackup(config, backup), throwsA(anything));

      expect(Directory(config.chatDir("later")).existsSync(), isTrue);
      expect(Directory(restoringDirOf(config.dataDir)).existsSync(), isFalse);
    },
  );

  test(
    "a launch after a restore killed mid-swap finds the old directory",
    () async {
      write("projects/default/chats/kept/state.json", "{}");
      final dataDir = config.dataDir;
      Directory(dataDir).renameSync(replacedDirOf(dataDir));

      await recoverRestore(dataDir);
      final loaded = await AppConfig.load(dataDir);

      expect(Directory(loaded.chatDir("kept")).existsSync(), isTrue);
      expect(Directory(replacedDirOf(dataDir)).existsSync(), isFalse);
    },
  );

  test("the directory a restore replaced goes at the next launch", () async {
    final backup = await roundTrip();

    await restoreBackup(config, backup);
    expect(Directory(replacedDirOf(config.dataDir)).existsSync(), isTrue);

    await recoverRestore(config.dataDir);
    await settleDeletes(replacedDirOf(config.dataDir));

    expect(Directory(replacedDirOf(config.dataDir)).existsSync(), isFalse);
  });

  test("a restore that fails unpacking takes its staging with it", () async {
    write("projects/default/chats/kept/state.json", "{}");
    // "a" a file and "a/b" beneath it: the second cannot be written.
    final archive = Archive()
      ..add(
        ArchiveFile.string(
          manifestName,
          jsonEncode({"format": backupFormat, "version": backupVersion}),
        ),
      )
      ..add(ArchiveFile.string("a", "file"))
      ..add(ArchiveFile.string("a/b", "under a file"));
    final path = "${out.path}/clash.zip";
    File(path).writeAsBytesSync(ZipEncoder().encodeBytes(archive));

    await expectLater(
      restoreBackup(config, await opened(path)),
      throwsA(anything),
    );

    expect(Directory(config.chatDir("kept")).existsSync(), isTrue);
    expect(Directory(restoringDirOf(config.dataDir)).existsSync(), isFalse);
  });

  test(
    "the linked instruction files are this machine's: left out, and kept",
    () async {
      write("instruction_files.json", '{"files":["/home/me/CLAUDE.md"]}');

      final backup = await roundTrip();
      expect(backup.members, isNot(contains("instruction_files.json")));

      await restoreBackup(config, backup);

      expect(
        File(config.linkedInstructionsFile).readAsStringSync(),
        contains("CLAUDE.md"),
      );
    },
  );

  test(
    "the directories the app needs are there whatever the backup held",
    () async {
      final backup = await roundTrip();

      await restoreBackup(config, backup);

      expect(Directory(config.chatsDir()).existsSync(), isTrue);
      expect(Directory(config.projectWorkspaceDir()).existsSync(), isTrue);
      // A backup carries no `sync/` at all, so a restore is the one path that
      // deletes it and unpacks nothing over it.
      expect(Directory(config.syncDir).existsSync(), isTrue);
    },
  );

  test(
    "sync/ and a project's rootfs/ are left out, same-named workspace folders are not",
    () async {
      write(
        "sync/secrets.json",
        jsonEncode({
          "provider-keys": base64Encode(utf8.encode('{"a":"sk-secret"}')),
        }),
      );
      // A mode-0000 stub, as proot leaves it on the host: the walker cannot list it.
      final rootfs = Directory(
        "${config.projectDir(project: "byte-repair")}/rootfs/alpine/opt/skills-bundled",
      );
      rootfs.createSync(recursive: true);
      Process.runSync("chmod", ["0000", rootfs.path]);
      addTearDown(() => Process.runSync("chmod", ["-R", "u+rwX", rootfs.path]));
      write("projects/default/workspace/sync/notes.txt", "mine");
      write("projects/default/workspace/rootfs/notes.txt", "mine");

      final zip = await archive();

      for (final member in zip.files) {
        if (member.isDirectory) continue;
        expect(
          String.fromCharCodes(member.readBytes()!),
          isNot(contains("sk-secret")),
          reason: member.name,
        );
      }
      expect(zip.files.where((f) => f.name.startsWith("sync/")), isEmpty);
      expect(
        zip.files.where(
          (f) => f.name.startsWith("projects/byte-repair/rootfs"),
        ),
        isEmpty,
      );
      expect(
        zip.findFile("projects/default/workspace/sync/notes.txt"),
        isNotNull,
      );
      expect(
        zip.findFile("projects/default/workspace/rootfs/notes.txt"),
        isNotNull,
      );
    },
  );

  test(
    "a restore clears a rootfs with mode-0000 stubs via deleteTree",
    () async {
      final rootfs = Directory(
        "${config.projectDir(project: "byte-repair")}/rootfs/alpine/opt/skills",
      );
      rootfs.createSync(recursive: true);
      File("${rootfs.path}/inside.txt").writeAsStringSync("guest file");
      Process.runSync("chmod", ["0000", rootfs.path]);
      addTearDown(() => Process.runSync("chmod", ["-R", "u+rwX", rootfs.path]));

      final backup = await roundTrip();
      Future<void> deleteTree(String path) async {
        final err = await removeTree(path);
        if (err != null) throw Exception("could not delete $path: $err");
      }

      await restoreBackup(config, backup, deleteTree: deleteTree);

      expect(rootfs.existsSync(), isFalse);
    },
  );

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
    write(
      "projects/default/chats/a/conv.jsonl",
      '{"type":"append","text":"hello"}\n' * 200,
    );

    expect(
      File(await written()).lengthSync(),
      lessThan(File(config.convFile("a")).lengthSync()),
    );
  });

  // The restore reads every member before the data directory is touched, so
  // a backup saved into a workspace is still there to read.
  test("a backup kept inside the data directory still restores", () async {
    write("projects/default/chats/a/state.json", "{}");
    final inside = "${config.projectWorkspaceDir()}/backup.zip";
    await File(await written()).copy(inside);

    await restoreBackup(config, await opened(inside));

    expect(
      File(
        "${config.dataDir}/projects/default/chats/a/state.json",
      ).existsSync(),
      isTrue,
    );
  });

  group("what it refuses", () {
    String fileOf(List<int> bytes) {
      final path = "${out.path}/made-${made++}.zip";
      File(path).writeAsBytesSync(bytes);
      return path;
    }

    String zipOf(Object? manifest) {
      final archive = Archive()..add(ArchiveFile.string("settings.json", "{}"));
      if (manifest != null) {
        archive.add(ArchiveFile.string(manifestName, jsonEncode(manifest)));
      }
      return fileOf(ZipEncoder().encodeBytes(archive));
    }

    test("something that is not a backup", () async {
      final refused = throwsA(isA<BackupFormatException>());
      await expectLater(openBackup(fileOf("not a zip".codeUnits)), refused);
      // A zip, but none of ours: no manifest.
      await expectLater(openBackup(zipOf(null)), refused);
      // Ours, but another format's manifest.
      await expectLater(
        openBackup(zipOf({"format": "something-else", "version": 1})),
        refused,
      );
      // A format and version this build speaks of but cannot read.
      await expectLater(
        openBackup(
          zipOf({"format": backupFormat, "version": backupVersion + 1}),
        ),
        refused,
      );
    });

    // A zip is a file someone can build by hand, so a member's name is treated
    // the way a shared file's path is.
    test("a member that would climb out of the data directory", () async {
      final archive = Archive()
        ..add(
          ArchiveFile.string(
            manifestName,
            jsonEncode({"format": backupFormat, "version": backupVersion}),
          ),
        )
        ..add(ArchiveFile.string("../../escaped.json", "no"));

      await restoreBackup(
        config,
        await opened(fileOf(ZipEncoder().encodeBytes(archive))),
      );

      expect(File("${config.dataDir}/escaped.json").existsSync(), isTrue);
      expect(
        File("${config.dataDir}/../../escaped.json").existsSync(),
        isFalse,
      );
    });
  });

  test("the filename carries the day and the time", () {
    expect(
      backupFilename(DateTime(2026, 8, 18, 9, 5)),
      "entoli-backup-2026-08-18-0905.zip",
    );
  });
}
