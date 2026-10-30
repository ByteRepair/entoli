import "dart:async";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/core/read_only_dirs.dart";
import "package:agent_chat/data/local/file_modes.dart";

void main() {
  test("one manager per path, whatever spelling", () {
    final dirs = ReadOnlyDirs(
      (paths, {required writable, executable = false}) async {},
    );
    expect(identical(dirs.of("/a/b"), dirs.of("/a/./b/")), isTrue);
  });

  test(
    "a path's writes run one at a time, each unlocked and relocked",
    () async {
      final log = <String>[];
      final dirs = ReadOnlyDirs((
        paths, {
        required writable,
        executable = false,
      }) async {
        log.add(writable ? "unlock" : "lock");
      });
      final first = Completer<void>();
      final a = dirs.of("/d").write(() async {
        log.add("a");
        await first.future;
      });
      final b = dirs.of("/d").write(() async => log.add("b"));
      await Future<void>.delayed(Duration.zero);
      first.complete();
      await Future.wait([a, b]);
      expect(log, ["unlock", "a", "lock", "unlock", "b", "lock"]);
    },
  );

  test("a write that throws still relocks, and the next still runs", () async {
    final log = <String>[];
    final dirs = ReadOnlyDirs((
      paths, {
      required writable,
      executable = false,
    }) async {
      log.add(writable ? "unlock" : "lock");
    });
    await expectLater(
      dirs.of("/d").write(() async => throw StateError("no")),
      throwsStateError,
    );
    await dirs.of("/d").write(() async => log.add("next"));
    expect(log, ["unlock", "lock", "unlock", "next", "lock"]);
  });

  group("on disk", () {
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync("read-only-dirs");
      addTearDown(() async {
        await setTreeWritable([dir.path], writable: true);
        dir.deleteSync(recursive: true);
      });
    });

    test("locked, nothing can be written, added or removed", () async {
      final file = File(p.join(dir.path, "a.pdf"))..writeAsStringSync("x");
      await ReadOnlyDirs(setTreeWritable).of(dir.path).lock();

      expect(
        () => file.writeAsStringSync("y"),
        throwsA(isA<FileSystemException>()),
      );
      expect(() => file.deleteSync(), throwsA(isA<FileSystemException>()));
      expect(
        () => File(p.join(dir.path, "b")).writeAsStringSync("z"),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        file.statSync().modeString(),
        "r--r--r--",
        reason: "an attachment gets no execute bit",
      );
    }, skip: Platform.isWindows ? "modes are POSIX" : null);

    test("the manager's own write goes through and is locked after", () async {
      final dirs = ReadOnlyDirs(setTreeWritable);
      await dirs.of(dir.path).lock();
      await dirs
          .of(dir.path)
          .write(() => File(p.join(dir.path, "new.png")).writeAsString("x"));

      final made = File(p.join(dir.path, "new.png"));
      expect(made.readAsStringSync(), "x");
      expect(
        () => made.writeAsStringSync("y"),
        throwsA(isA<FileSystemException>()),
      );
    }, skip: Platform.isWindows ? "modes are POSIX" : null);

    test("a link is not followed out of the tree", () async {
      final outside = Directory.systemTemp.createTempSync("outside");
      addTearDown(() => outside.deleteSync(recursive: true));
      final target = File(p.join(outside.path, "t"))..writeAsStringSync("x");
      Link(p.join(dir.path, "l")).createSync(target.path);

      await setTreeWritable([dir.path], writable: false);

      expect(target.statSync().modeString(), "rw-r--r--");
    }, skip: Platform.isWindows ? "modes are POSIX" : null);
  });
}
