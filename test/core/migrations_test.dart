import "dart:io";

import "package:flutter_test/flutter_test.dart";

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

  test("a directory this launch created is stamped at the end and left alone",
      () async {
    await runMigrations(config.dataDir, fresh: true, chain: [step("0.1.3"), step("1.0.0")]);

    expect(ran, isEmpty);
    expect(await stamped(), "1.0.0");
  });

  test("the stamp is where the chain resumes", () async {
    // No stamp: older than every entry, so the whole chain runs.
    await runMigrations(config.dataDir,
        fresh: false, chain: [step("0.1.3"), step("0.2.0"), step("1.0.0")]);

    expect(ran, ["0.1.3", "0.2.0", "1.0.0"]);
    expect(await stamped(), "1.0.0");
    ran.clear();

    // A stamp mid-chain: only the entries after it run.
    await stamp("0.2.0");
    await runMigrations(config.dataDir,
        fresh: false, chain: [step("0.1.3"), step("0.2.0"), step("1.0.0")]);

    expect(ran, ["1.0.0"]);
    ran.clear();

    // A stamp from a build newer than this one is left where it is, and
    // nothing runs here.
    await runMigrations(config.dataDir, fresh: false, chain: [step("9.9.9")]);
    await stamp("2.0.0");
    await runMigrations(config.dataDir, fresh: false, chain: [step("0.1.3"), step("1.0.0")]);

    expect(ran, isEmpty);
    expect(await stamped(), "2.0.0");
  });

  test("one that dies halfway is picked up at the entry it died in", () async {
    await expectLater(
      runMigrations(config.dataDir,
          fresh: false, chain: [step("0.1.3"), step("0.2.0", fails: true)]),
      throwsStateError,
    );
    expect(await stamped(), "0.1.3");
    ran.clear();

    await runMigrations(config.dataDir,
        fresh: false, chain: [step("0.1.3"), step("0.2.0"), step("1.0.0")]);

    expect(ran, ["0.2.0", "1.0.0"]);
  });

  test("a chain with nothing in it stamps nothing", () async {
    await runMigrations(config.dataDir, fresh: true, chain: const []);

    expect(await stamped(), isNull);
  });

  // A release naming a version an earlier entry already used would truncate
  // the chain at the first of the two, and every entry after it would be
  // skipped without a word.
  test("no two entries in the real chain name the same release", () {
    final versions = [for (final migration in migrations) migration.version];

    expect(versions.toSet(), hasLength(versions.length));
  });
}
