import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/data/local/tree_ops.dart";

/// The real tar, the real chmod and the real rm, the way
/// `file_rootfs_store_test.dart` unpacks with the machine's own tar: only a
/// real one proves a mode-0000 entry survives neither tool's notice.
void main() {
  late Directory scratch;

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp("tree_ops_");
  });

  tearDown(() async {
    // The fixtures hold mode-0000 and read-only entries Dart cannot delete,
    // so the teardown is the operation under test.
    await removeTree(scratch.path);
  });

  test("removeTree clears a tree Dart alone could not list", () async {
    final tree = p.join(scratch.path, "tree");
    await Directory(p.join(tree, "closed")).create(recursive: true);
    await Directory(p.join(tree, "readonly")).create(recursive: true);
    await Link(p.join(tree, "dangling")).create("nowhere");
    await Process.run("chmod", ["000", p.join(tree, "closed")]);
    await Process.run("chmod", ["555", p.join(tree, "readonly")]);

    final err = await removeTree(tree);

    expect(err, isNull);
    expect(Directory(tree).existsSync(), isFalse);
  });
}
