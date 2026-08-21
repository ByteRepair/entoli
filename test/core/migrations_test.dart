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
      Migration(version, (_, _) async {
        ran.add(version);
        if (fails) throw StateError("stopped in $version");
      });

  Future<String?> stamped() async {
    final file = config.fs.file(config.versionFile);
    return await file.exists() ? file.readAsString() : null;
  }

  Future<void> stamp(String version) =>
      config.fs.file(config.versionFile).writeAsString(version);

  test("a directory this launch created is stamped at the end and left alone",
      () async {
    await runMigrations(config, fresh: true, chain: [step("0.1.3"), step("1.0.0")]);

    expect(ran, isEmpty);
    expect(await stamped(), "1.0.0");
  });

  test("a directory with no stamp is older than every entry there is", () async {
    await runMigrations(config,
        fresh: false, chain: [step("0.1.3"), step("0.2.0"), step("1.0.0")]);

    expect(ran, ["0.1.3", "0.2.0", "1.0.0"]);
    expect(await stamped(), "1.0.0");
  });

  test("only the entries after the one stamped run", () async {
    await stamp("0.2.0");

    await runMigrations(config,
        fresh: false, chain: [step("0.1.3"), step("0.2.0"), step("1.0.0")]);

    expect(ran, ["1.0.0"]);
  });

  test("a stamp from a build newer than this one is left where it is", () async {
    await stamp("2.0.0");

    await runMigrations(config, fresh: false, chain: [step("0.1.3"), step("1.0.0")]);

    expect(ran, isEmpty);
    expect(await stamped(), "2.0.0");
  });

  test("one that dies halfway is picked up at the entry it died in", () async {
    await expectLater(
      runMigrations(config,
          fresh: false, chain: [step("0.1.3"), step("0.2.0", fails: true)]),
      throwsStateError,
    );
    expect(await stamped(), "0.1.3");
    ran.clear();

    await runMigrations(config,
        fresh: false, chain: [step("0.1.3"), step("0.2.0"), step("1.0.0")]);

    expect(ran, ["0.2.0", "1.0.0"]);
  });

  test("a chain with nothing in it stamps nothing", () async {
    await runMigrations(config, fresh: true, chain: const []);

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
