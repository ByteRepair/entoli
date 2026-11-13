import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/core/config.dart";
import "package:agent_chat/core/migrations.dart";

import "../harness.dart";

/// The engine, driven with chains of this file's own: what is *in* `migrations`
/// is the release's, and asserting on it here would be asserting on the
/// release. Its shape is the engine's, and that is checked below.
void main() {
  late AppConfig config;
  late List<String> ran;

  setUp(() {
    config = tempConfig();
    ran = [];
  });

  Migration step(String version, {bool fails = false}) =>
      Migration(version, (_) async {
        ran.add(version);
        if (fails) throw StateError("stopped in $version");
      });

  Future<String?> stamped() async {
    final file = File(migrationStamp(config.dataDir));
    return file.existsSync() ? file.readAsString() : null;
  }

  Future<void> stamp(String version) =>
      File(migrationStamp(config.dataDir)).writeAsString(version);

  test(
    "a directory this launch created is stamped at the end and left alone",
    () async {
      await runMigrations(
        config.dataDir,
        fresh: true,
        chain: [step("0.1.3"), step("1.0.0")],
      );

      expect(ran, isEmpty);
      expect(await stamped(), "1.0.0");
    },
  );

  test("the stamp is where the chain resumes", () async {
    // No stamp: older than every entry, so the whole chain runs.
    await runMigrations(
      config.dataDir,
      fresh: false,
      chain: [step("0.1.3"), step("0.2.0"), step("1.0.0")],
    );

    expect(ran, ["0.1.3", "0.2.0", "1.0.0"]);
    expect(await stamped(), "1.0.0");
    ran.clear();

    // A stamp mid-chain: only the entries after it run.
    await stamp("0.2.0");
    await runMigrations(
      config.dataDir,
      fresh: false,
      chain: [step("0.1.3"), step("0.2.0"), step("1.0.0")],
    );

    expect(ran, ["1.0.0"]);
    ran.clear();

    // A stamp from a build newer than this one is left where it is, and
    // nothing runs here.
    await runMigrations(config.dataDir, fresh: false, chain: [step("9.9.9")]);
    await stamp("2.0.0");
    await runMigrations(
      config.dataDir,
      fresh: false,
      chain: [step("0.1.3"), step("1.0.0")],
    );

    expect(ran, isEmpty);
    expect(await stamped(), "2.0.0");
  });

  test("one that dies halfway is picked up at the entry it died in", () async {
    await expectLater(
      runMigrations(
        config.dataDir,
        fresh: false,
        chain: [step("0.1.3"), step("0.2.0", fails: true)],
      ),
      throwsStateError,
    );
    expect(await stamped(), "0.1.3");
    ran.clear();

    await runMigrations(
      config.dataDir,
      fresh: false,
      chain: [step("0.1.3"), step("0.2.0"), step("1.0.0")],
    );

    expect(ran, ["0.2.0", "1.0.0"]);
  });

  // A release naming a version an earlier entry already used would truncate
  // the chain at the first of the two, and every entry after it would be
  // skipped without a word.
  test("no two entries in the real chain name the same release", () {
    final versions = [for (final migration in migrations) migration.version];

    expect(versions.toSet(), hasLength(versions.length));
  });

  group("relocateDataDir", () {
    late String from;
    late String to;

    setUp(() {
      final root = tempDir().path;
      from = p.join(root, "documents", "entoli");
      to = p.join(root, "group", "entoli");
      Directory(p.dirname(to)).createSync();
    });

    test("moves the directory, files and all", () {
      File(p.join(from, "settings.json"))
        ..createSync(recursive: true)
        ..writeAsStringSync("{}");

      expect(relocateDataDir(from: from, to: to), isTrue);

      expect(Directory(from).existsSync(), isFalse);
      expect(File(p.join(to, "settings.json")).readAsStringSync(), "{}");
    });

    test("leaves both alone where the new place already holds one", () {
      File(p.join(from, "old.json")).createSync(recursive: true);
      File(p.join(to, "new.json")).createSync(recursive: true);

      expect(relocateDataDir(from: from, to: to), isTrue);

      expect(File(p.join(from, "old.json")).existsSync(), isTrue);
      expect(Directory(to).listSync().map((e) => p.basename(e.path)), [
        "new.json",
      ]);
    });

    test("has nothing to do where there was none before", () {
      expect(relocateDataDir(from: from, to: to), isTrue);

      expect(Directory(to).existsSync(), isFalse);
    });

    test("says so where the rename fails, the old directory kept", () {
      File(p.join(from, "settings.json")).createSync(recursive: true);
      // No parent to rename into.
      final nowhere = p.join(p.dirname(to), "missing", "entoli");

      expect(relocateDataDir(from: from, to: nowhere), isFalse);

      expect(File(p.join(from, "settings.json")).existsSync(), isTrue);
    });
  });
}
