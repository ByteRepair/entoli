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

  /// The shape that broke the real thing: an Alpine-ish tree with proot's
  /// mode-0000 bind stubs in it, and beside them a symlink, an execute bit
  /// and a read-only directory — what a rootfs is made of.
  Future<String> seededRootfs() async {
    final base = p.join(scratch.path, "base");
    for (final dir in const ["bin", "etc", "opt/skills", "opt/skills-bundled"]) {
      await Directory(p.join(base, dir)).create(recursive: true);
    }
    await File(p.join(base, "bin", "busybox")).writeAsString("#!/bin/sh\n");
    await Process.run("chmod", ["755", p.join(base, "bin", "busybox")]);
    await Link(p.join(base, "bin", "sh")).create("busybox");
    final ro = p.join(base, "etc", "dir");
    await Directory(ro).create();
    await Process.run("chmod", ["555", ro]);
    await Process.run("chmod", ["000", p.join(base, "opt", "skills")]);
    await Process.run("chmod", ["000", p.join(base, "opt", "skills-bundled")]);
    final resolv = p.join(base, "etc", "resolv.conf");
    await File(resolv).writeAsString("");
    await Process.run("chmod", ["000", resolv]);
    return base;
  }

  test("copyTree leaves the bind stubs behind and keeps what a rootfs is",
      () async {
    final base = await seededRootfs();
    final target = p.join(scratch.path, "target");

    final err = await copyTree(base, target);

    expect(err, isNull);
    // The stubs are excluded: nothing at those paths is reachable in the
    // guest, because the binds shadow them.
    expect(FileSystemEntity.typeSync(p.join(target, "opt", "skills")),
        FileSystemEntityType.notFound);
    expect(FileSystemEntity.typeSync(p.join(target, "opt", "skills-bundled")),
        FileSystemEntityType.notFound);
    expect(FileSystemEntity.typeSync(p.join(target, "etc", "resolv.conf")),
        FileSystemEntityType.notFound);
    // The symlink stays a link, the execute bit survives the trip, and a
    // read-only directory arrives read-only.
    expect(Link(p.join(target, "bin", "sh")).existsSync(), isTrue);
    final busybox = File(p.join(target, "bin", "busybox")).statSync();
    expect(busybox.mode & 0x49, 0x49);
    final dir = Directory(p.join(target, "etc", "dir")).statSync();
    expect(dir.mode & 0x92, 0);
  });

  test("copyTree starts over whatever an earlier attempt left", () async {
    final base = await seededRootfs();
    final target = p.join(scratch.path, "target");
    // A poisoned leftover: a partial copy carrying a stub of its own and a
    // stale marker.
    await Directory(p.join(target, "opt", "skills")).create(recursive: true);
    await Process.run("chmod", ["000", p.join(target, "opt", "skills")]);
    await File(p.join(target, ".complete")).writeAsString("stale");

    final err = await copyTree(base, target);

    expect(err, isNull);
    expect(File(p.join(target, ".complete")).existsSync(), isFalse);
    expect(File(p.join(target, "bin", "busybox")).existsSync(), isTrue);
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