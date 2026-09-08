import "package:flutter_test/flutter_test.dart";
import "package:agent_chat/core/config.dart";
import "package:agent_chat/domain/documents.dart";

import "../harness.dart";

void main() {
  late AppConfig config;

  setUp(() => config = tempConfig());

  String settingsPath(AppConfig config) =>
      config.fs.path.join(config.dataDir, "settings.json");

  test("a write lands under the path it was asked for", () async {
    final documents = config.documents;
    final path = settingsPath(config);
    await documents.write(path, '{"a":1}');

    expect(documents.read(path), '{"a":1}');
    expect(await config.fs.file(path).readAsString(), '{"a":1}');
  });

  test("two concurrent writes both land, the last one last", () async {
    final documents = config.documents;
    final path = settingsPath(config);
    // The race the fixed temp name had: two writers through one sibling temp
    // name, the first rename taking it and the second's failing ENOENT.
    await Future.wait([
      documents.write(path, '{"n":1}'),
      documents.write(path, '{"n":2}'),
    ]);

    expect(await config.fs.file(path).readAsString(), '{"n":2}');
    expect(documents.read(path), '{"n":2}');
  });

  test("no temp sibling is left behind", () async {
    final documents = config.documents;
    final path = settingsPath(config);
    await Future.wait([
      documents.write(path, '{"n":1}'),
      documents.write(path, '{"n":2}'),
    ]);
    await documents.write(path, '{"n":3}');

    final litter = (await config.fs.directory(config.dataDir).list().toList())
        .where((entity) => entity.path.contains(writingSuffix));
    expect(litter, isEmpty);
  });

  test("two overlapping writeThroughRenames do not take each other's temp",
      () async {
    final path = settingsPath(config);
    await Future.wait([
      writeThroughRename(config.fs, path, "first"),
      writeThroughRename(config.fs, path, "second"),
    ]);

    expect(
        await config.fs.file(path).readAsString(), anyOf("first", "second"));
  });

  test("a failed write behind a successful one is not left queued", () async {
    final documents = config.documents;
    final path = settingsPath(config);
    await documents.write(path, '{"a":1}');

    // The parent directory gone: the rename fails, the queue drains, and a
    // later write after the directory is back is not stuck behind the
    // failure's entry.
    final parent = config.fs.path.dirname(path);
    await config.fs.directory(parent).rename("$parent.away");
    // A write to a directory that is not there fails at the temp's create,
    // under both the old fixed name and the unique one.
    try {
      await documents.write(path, '{"a":2}');
      fail("the write should have failed");
    } catch (_) {}
    await config.fs.directory("$parent.away").rename(parent);
    await documents.write(path, '{"a":3}');

    expect(await config.fs.file(path).readAsString(), '{"a":3}');
  });
}